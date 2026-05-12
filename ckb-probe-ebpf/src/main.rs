#![no_std]
#![no_main]

use aya_ebpf::{
    helpers::{bpf_get_current_pid_tgid, bpf_ktime_get_ns, bpf_probe_read_user},
    macros::{kprobe, kretprobe, map, tracepoint, uprobe, uretprobe},
    maps::{Array, HashMap, PerCpuArray, PerfEventArray, RingBuf},
    programs::{ProbeContext, RetProbeContext, TracePointContext},
};
use ckb_probe_common::{
    OpStats, RocksDbFunc, SlowEvent, SyscallEvent, TcpEvent, UprobeLatencyEvent,
    HIST_BUCKETS, MAX_FUNC_ID,
};

// ============================================================
// Maps — shared across check validation & rocksdb monitoring
// ============================================================

/// Target PID filter (written by userspace).
#[map]
static TARGET_PID: HashMap<u32, u8> = HashMap::with_max_entries(8, 0);

/// uprobe entry timestamp: key = tid, value = (timestamp_ns, func_id, size).
/// `size` is the operation payload in bytes when the entry probe can read it
/// from a function argument (0 = not tracked for this op).
#[map]
static UPROBE_START: HashMap<u32, (u64, u32, u64)> = HashMap::with_max_entries(1024, 0);

/// uprobe latency event output (used by `check` live event collection).
#[map]
static UPROBE_EVENTS: PerfEventArray<UprobeLatencyEvent> = PerfEventArray::new(0);

/// kprobe entry timestamp: key = tid.
#[map]
static TCP_START: HashMap<u32, u64> = HashMap::with_max_entries(1024, 0);

/// TCP event output.
#[map]
static TCP_EVENTS: PerfEventArray<TcpEvent> = PerfEventArray::new(0);

/// syscall event output.
#[map]
static SYSCALL_EVENTS: PerfEventArray<SyscallEvent> = PerfEventArray::new(0);

// ============================================================
// Maps — rocksdb monitoring (Week 4)
// ============================================================

/// Per-operation aggregated stats, indexed by func_id. PerCpuArray avoids
/// cross-CPU contention — userspace merges per-CPU values on read.
#[map]
static OP_STATS: PerCpuArray<OpStats> = PerCpuArray::with_max_entries(MAX_FUNC_ID, 0);

/// Latency histogram (log2 buckets). Index = func_id * HIST_BUCKETS + bucket.
/// Total entries = MAX_FUNC_ID * HIST_BUCKETS = 9 * 64 = 576.
#[map]
static LATENCY_HIST: PerCpuArray<u64> =
    PerCpuArray::with_max_entries(MAX_FUNC_ID * HIST_BUCKETS, 0);

/// Slow operation events — only emitted when latency > threshold.
/// RingBuf: single shared buffer, no per-event wakeup, batch consumption.
/// 256KB is sufficient for 10K+ events/sec (each ~40 bytes).
#[map]
static SLOW_EVENTS: RingBuf = RingBuf::with_byte_size(256 * 1024, 0);

/// Slow threshold in nanoseconds. Index 0 = threshold value.
#[map]
static SLOW_THRESHOLD: Array<u64> = Array::with_max_entries(1, 0);

/// Per-tid running total of bytes written via `rocksdb_transaction_put_cf`
/// since the last `rocksdb_transaction_commit` on the same thread.
/// At commit time we snapshot this value as the commit's "size", then reset.
/// Bounds: 1024 entries × 8B = ~8 KB; one entry per active worker thread.
#[map]
static PUT_PENDING_BYTES: HashMap<u32, u64> = HashMap::with_max_entries(1024, 0);

// ============================================================
// Helpers
// ============================================================

#[inline(always)]
fn is_target_pid() -> bool {
    let pid = (bpf_get_current_pid_tgid() >> 32) as u32;
    unsafe { TARGET_PID.get(&pid).is_some() }
}

#[inline(always)]
fn current_pid_tid() -> (u32, u32) {
    let id = bpf_get_current_pid_tgid();
    let pid = (id >> 32) as u32;
    let tid = id as u32;
    (pid, tid)
}

/// Verifier-safe log2 via binary search (fully unrolled, no loops).
#[inline(always)]
fn log2_u64(v: u64) -> u32 {
    if v == 0 {
        return 0;
    }
    let mut r = 0u32;
    let mut v = v;
    if v >= 1u64 << 32 { v >>= 32; r += 32; }
    if v >= 1u64 << 16 { v >>= 16; r += 16; }
    if v >= 1u64 << 8  { v >>= 8;  r += 8;  }
    if v >= 1u64 << 4  { v >>= 4;  r += 4;  }
    if v >= 1u64 << 2  { v >>= 2;  r += 2;  }
    if v >= 1u64 << 1  { r += 1; }
    r
}

// ============================================================
// uprobe entry / return (shared logic)
// ============================================================

#[inline(always)]
fn uprobe_entry(func_id: u32) {
    uprobe_entry_with_size(func_id, 0);
}

#[inline(always)]
fn uprobe_entry_with_size(func_id: u32, size: u64) {
    // PID filtering happens at uprobe attach time (kernel-level).
    // Avoid BPF-side hashmap lookup — broken under WSL2 JIT inlining.
    let (_, tid) = current_pid_tid();
    let ts = unsafe { bpf_ktime_get_ns() };
    let _ = UPROBE_START.insert(&tid, &(ts, func_id, size), 0);
}

#[inline(always)]
fn uprobe_return(ctx: &RetProbeContext) {
    uprobe_return_with_extra(ctx, 0);
}

/// `extra_bytes` lets a per-op return probe contribute size info that's only
/// available at return time (e.g. GET reading the returned PinnableSlice's
/// `size_` field). Total bytes recorded = entry size + extra_bytes.
#[inline(always)]
fn uprobe_return_with_extra(ctx: &RetProbeContext, extra_bytes: u64) {
    let (pid, tid) = current_pid_tid();
    if let Some(&(start_ts, func_id, entry_size)) = unsafe { UPROBE_START.get(&tid) } {
        let now = unsafe { bpf_ktime_get_ns() };
        let latency_ns = now.saturating_sub(start_ts);
        let total_size = entry_size + extra_bytes;

        // 1) Per-event output (for `check` live collection)
        let event = UprobeLatencyEvent {
            pid,
            tid,
            func_id,
            latency_ns,
            ts: now,
        };
        UPROBE_EVENTS.output(ctx, &event, 0);

        // 2) Aggregate into OP_STATS (per-CPU, no contention)
        if func_id < MAX_FUNC_ID {
            unsafe {
                if let Some(stats) = OP_STATS.get_ptr_mut(func_id) {
                    (*stats).count += 1;
                    (*stats).total_ns += latency_ns;
                    (*stats).bytes_total += total_size;
                    if (*stats).min_ns == 0 || latency_ns < (*stats).min_ns {
                        (*stats).min_ns = latency_ns;
                    }
                    if latency_ns > (*stats).max_ns {
                        (*stats).max_ns = latency_ns;
                    }
                }
            }
        }

        // 3) Update latency histogram (log2 bucket)
        let bucket = log2_u64(latency_ns);
        let hist_idx = func_id * HIST_BUCKETS + bucket;
        if hist_idx < MAX_FUNC_ID * HIST_BUCKETS {
            unsafe {
                if let Some(count) = LATENCY_HIST.get_ptr_mut(hist_idx) {
                    *count += 1;
                }
            }
        }

        // 4) Emit slow event if threshold exceeded
        if let Some(threshold) = SLOW_THRESHOLD.get(0) {
            if *threshold > 0 && latency_ns > *threshold {
                let slow = SlowEvent {
                    pid,
                    tid,
                    func_id,
                    latency_ns,
                    size: total_size,
                    ts: now,
                };
                let _ = SLOW_EVENTS.output(&slow, 0);
            }
        }

        let _ = UPROBE_START.remove(&tid);
    }
}

// ============================================================
// RocksDB uprobe pairs (existing — for check validation)
// ============================================================

// --- rocksdb_get_pinned_cf (func_id=1, CKB primary read) ---
//
// Returns: rocksdb_pinnableslice_t* (== PinnableSlice*).
// PinnableSlice extends Slice as its first base; Slice's layout is:
//   offset 0: const char* data_   (8B)
//   offset 8: size_t      size_   (8B)
// So a single 8-byte read at (ret + 8) gives us the value length.
//
// On not-found / error, the C wrapper returns NULL — we then record 0 bytes.
#[uprobe]
pub fn rocksdb_get_pinned_cf_entry(_ctx: ProbeContext) -> u32 {
    uprobe_entry(RocksDbFunc::GetPinnedCf as u32);
    0
}
#[uretprobe]
pub fn rocksdb_get_pinned_cf_return(ctx: RetProbeContext) -> u32 {
    let ret: usize = ctx.ret().unwrap_or(0);
    let value_size: u64 = if ret != 0 {
        unsafe { bpf_probe_read_user::<u64>((ret + 8) as *const u64).unwrap_or(0) }
    } else {
        0
    };
    uprobe_return_with_extra(&ctx, value_size);
    0
}

// --- rocksdb_put (func_id=2) ---
#[uprobe]
pub fn rocksdb_put_entry(_ctx: ProbeContext) -> u32 {
    uprobe_entry(RocksDbFunc::Put as u32);
    0
}
#[uretprobe]
pub fn rocksdb_put_return(ctx: RetProbeContext) -> u32 {
    uprobe_return(&ctx);
    0
}

// --- rocksdb_write (func_id=4, WriteBatch) ---
#[uprobe]
pub fn rocksdb_write_entry(_ctx: ProbeContext) -> u32 {
    uprobe_entry(RocksDbFunc::Write as u32);
    0
}
#[uretprobe]
pub fn rocksdb_write_return(ctx: RetProbeContext) -> u32 {
    uprobe_return(&ctx);
    0
}

// --- rocksdb_delete (func_id=3) ---
#[uprobe]
pub fn rocksdb_delete_entry(_ctx: ProbeContext) -> u32 {
    uprobe_entry(RocksDbFunc::Delete as u32);
    0
}
#[uretprobe]
pub fn rocksdb_delete_return(ctx: RetProbeContext) -> u32 {
    uprobe_return(&ctx);
    0
}

// --- rocksdb_create_iterator_cf (func_id=5) ---
#[uprobe]
pub fn rocksdb_create_iterator_cf_entry(_ctx: ProbeContext) -> u32 {
    uprobe_entry(RocksDbFunc::NewIteratorCf as u32);
    0
}
#[uretprobe]
pub fn rocksdb_create_iterator_cf_return(ctx: RetProbeContext) -> u32 {
    uprobe_return(&ctx);
    0
}

// --- rocksdb_multi_get_cf (func_id=6) ---
#[uprobe]
pub fn rocksdb_multi_get_cf_entry(_ctx: ProbeContext) -> u32 {
    uprobe_entry(RocksDbFunc::MultiGetCf as u32);
    0
}
#[uretprobe]
pub fn rocksdb_multi_get_cf_return(ctx: RetProbeContext) -> u32 {
    uprobe_return(&ctx);
    0
}

// ============================================================
// RocksDB uprobe pairs (new — Week 4 monitoring targets)
// ============================================================

// --- rocksdb_transaction_put_cf (func_id=7, CKB primary write) ---
//
// Signature:
//   void rocksdb_transaction_put_cf(
//       rocksdb_transaction_t* txn,        // arg 0
//       rocksdb_column_family_handle_t* cf,// arg 1
//       const char* key,                   // arg 2
//       size_t klen,                       // arg 3
//       const char* val,                   // arg 4
//       size_t vlen,                       // arg 5
//       char** errptr);
//
// We extract `vlen` (arg 5) at entry to drive the Bytes/s metric for PUT,
// and *also* accumulate it into PUT_PENDING_BYTES so TXN_COMMIT can later
// snapshot the total bytes written by the closing transaction.
#[uprobe]
pub fn rocksdb_transaction_put_cf_entry(ctx: ProbeContext) -> u32 {
    let vlen: usize = ctx.arg(5).unwrap_or(0);
    let (_, tid) = current_pid_tid();
    let prev = unsafe { PUT_PENDING_BYTES.get(&tid).copied().unwrap_or(0) };
    let _ = PUT_PENDING_BYTES.insert(&tid, &(prev + vlen as u64), 0);
    uprobe_entry_with_size(RocksDbFunc::TransactionPutCf as u32, vlen as u64);
    0
}
#[uretprobe]
pub fn rocksdb_transaction_put_cf_return(ctx: RetProbeContext) -> u32 {
    uprobe_return(&ctx);
    0
}

// --- rocksdb_transaction_commit (func_id=8) ---
//
// rocksdb_transaction_commit itself takes no payload, but a commit conceptually
// "writes" all the bytes that PUTs since the previous commit on this thread
// produced. We snapshot the per-tid PUT_PENDING_BYTES accumulator and clear it.
#[uprobe]
pub fn rocksdb_transaction_commit_entry(_ctx: ProbeContext) -> u32 {
    let mut commit_size: u64 = 0;
    let (_, tid) = current_pid_tid();
    unsafe {
        if let Some(&v) = PUT_PENDING_BYTES.get(&tid) {
            commit_size = v;
            let _ = PUT_PENDING_BYTES.remove(&tid);
        }
    }
    uprobe_entry_with_size(RocksDbFunc::TransactionCommit as u32, commit_size);
    0
}
#[uretprobe]
pub fn rocksdb_transaction_commit_return(ctx: RetProbeContext) -> u32 {
    uprobe_return(&ctx);
    0
}

// ============================================================
// TCP kprobe (unchanged)
// ============================================================

#[kprobe]
pub fn tcp_sendmsg_entry(_ctx: ProbeContext) -> u32 {
    if !is_target_pid() {
        return 0;
    }
    let (_, tid) = current_pid_tid();
    let ts = unsafe { bpf_ktime_get_ns() };
    let _ = TCP_START.insert(&tid, &ts, 0);
    0
}

#[kretprobe]
pub fn tcp_sendmsg_return(ctx: RetProbeContext) -> u32 {
    let (pid, tid) = current_pid_tid();
    if let Some(&_start_ts) = unsafe { TCP_START.get(&tid) } {
        let ret: i64 = ctx.ret().unwrap_or(0);
        let bytes = if ret > 0 { ret as u32 } else { 0 };
        let event = TcpEvent {
            pid,
            tid,
            sport: 0,
            dport: 0,
            saddr: 0,
            daddr: 0,
            bytes,
            direction: 0,
            _pad: [0; 3],
            ts: unsafe { bpf_ktime_get_ns() },
        };
        TCP_EVENTS.output(&ctx, &event, 0);
        let _ = TCP_START.remove(&tid);
    }
    0
}

#[kprobe]
pub fn tcp_recvmsg_entry(_ctx: ProbeContext) -> u32 {
    if !is_target_pid() {
        return 0;
    }
    let (_, tid) = current_pid_tid();
    let ts = unsafe { bpf_ktime_get_ns() };
    let _ = TCP_START.insert(&tid, &ts, 0);
    0
}

#[kretprobe]
pub fn tcp_recvmsg_return(ctx: RetProbeContext) -> u32 {
    let (pid, tid) = current_pid_tid();
    if let Some(&_start_ts) = unsafe { TCP_START.get(&tid) } {
        let ret: i64 = ctx.ret().unwrap_or(0);
        let bytes = if ret > 0 { ret as u32 } else { 0 };
        let event = TcpEvent {
            pid,
            tid,
            sport: 0,
            dport: 0,
            saddr: 0,
            daddr: 0,
            bytes,
            direction: 1,
            _pad: [0; 3],
            ts: unsafe { bpf_ktime_get_ns() },
        };
        TCP_EVENTS.output(&ctx, &event, 0);
        let _ = TCP_START.remove(&tid);
    }
    0
}

// ============================================================
// Syscall tracepoint (unchanged)
// ============================================================

#[tracepoint]
pub fn sys_enter_handler(ctx: TracePointContext) -> u32 {
    if !is_target_pid() {
        return 0;
    }
    let syscall_nr: u64 = unsafe { ctx.read_at(8).unwrap_or(0) };
    match syscall_nr {
        0 | 1 | 2 | 3 | 44 | 45 | 46 | 47 | 232 => {}
        _ => return 0,
    }
    let (pid, tid) = current_pid_tid();
    let event = SyscallEvent {
        pid,
        tid,
        syscall_nr,
        ts: unsafe { bpf_ktime_get_ns() },
    };
    SYSCALL_EVENTS.output(&ctx, &event, 0);
    0
}

#[panic_handler]
fn panic(_info: &core::panic::PanicInfo) -> ! {
    unsafe { core::hint::unreachable_unchecked() }
}
