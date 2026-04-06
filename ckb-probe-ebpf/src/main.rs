#![no_std]
#![no_main]

use aya_ebpf::{
    helpers::{bpf_get_current_pid_tgid, bpf_ktime_get_ns},
    macros::{kprobe, kretprobe, map, tracepoint, uprobe, uretprobe},
    maps::{HashMap, PerfEventArray},
    programs::{ProbeContext, RetProbeContext, TracePointContext},
};
use ckb_probe_common::{RocksDbFunc, SyscallEvent, TcpEvent, UprobeLatencyEvent};

// ============================================================
// Maps
// ============================================================

/// uprobe entry timestamp: key = tid, value = (timestamp_ns, func_id)
#[map]
static UPROBE_START: HashMap<u32, (u64, u32)> = HashMap::with_max_entries(10240, 0);

/// uprobe latency event output
#[map]
static UPROBE_EVENTS: PerfEventArray<UprobeLatencyEvent> = PerfEventArray::new(0);

/// kprobe entry timestamp: key = tid
#[map]
static TCP_START: HashMap<u32, u64> = HashMap::with_max_entries(10240, 0);

/// TCP event output
#[map]
static TCP_EVENTS: PerfEventArray<TcpEvent> = PerfEventArray::new(0);

/// syscall event output
#[map]
static SYSCALL_EVENTS: PerfEventArray<SyscallEvent> = PerfEventArray::new(0);

/// Target PID filter (written by userspace)
#[map]
static TARGET_PID: HashMap<u32, u8> = HashMap::with_max_entries(8, 0);

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

// ============================================================
// Validation 1 & 2: RocksDB uprobe latency (multi-function)
// ============================================================

#[inline(always)]
fn uprobe_entry(func_id: u32) {
    if !is_target_pid() {
        return;
    }
    let (_, tid) = current_pid_tid();
    let ts = unsafe { bpf_ktime_get_ns() };
    let _ = UPROBE_START.insert(&tid, &(ts, func_id), 0);
}

#[inline(always)]
fn uprobe_return(ctx: &RetProbeContext) {
    let (pid, tid) = current_pid_tid();
    if let Some(&(start_ts, func_id)) = unsafe { UPROBE_START.get(&tid) } {
        let now = unsafe { bpf_ktime_get_ns() };
        let latency_ns = now.saturating_sub(start_ts);

        let event = UprobeLatencyEvent {
            pid,
            tid,
            func_id,
            latency_ns,
            ts: now,
        };
        UPROBE_EVENTS.output(ctx, &event, 0);
        let _ = UPROBE_START.remove(&tid);
    }
}

// --- rocksdb_get_pinned_cf ---
#[uprobe]
pub fn rocksdb_get_pinned_cf_entry(_ctx: ProbeContext) -> u32 {
    uprobe_entry(RocksDbFunc::GetPinnedCf as u32);
    0
}

#[uretprobe]
pub fn rocksdb_get_pinned_cf_return(ctx: RetProbeContext) -> u32 {
    uprobe_return(&ctx);
    0
}

// --- rocksdb_put ---
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

// --- rocksdb_write ---
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

// --- rocksdb_delete ---
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

// --- rocksdb_create_iterator_cf ---
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

// --- rocksdb_multi_get_cf ---
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
// Validation 3: TCP kprobe
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
    if let Some(&start_ts) = unsafe { TCP_START.get(&tid) } {
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
            direction: 0, // send
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
    if let Some(&start_ts) = unsafe { TCP_START.get(&tid) } {
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
            direction: 1, // recv
            _pad: [0; 3],
            ts: unsafe { bpf_ktime_get_ns() },
        };
        TCP_EVENTS.output(&ctx, &event, 0);
        let _ = TCP_START.remove(&tid);
    }
    0
}

// ============================================================
// Validation 4: sys_enter tracepoint
// ============================================================

#[tracepoint]
pub fn sys_enter_handler(ctx: TracePointContext) -> u32 {
    if !is_target_pid() {
        return 0;
    }

    // tracepoint/syscalls/sys_enter format:
    // field: long id;   offset:8;  size:8;
    let syscall_nr: u64 = unsafe { ctx.read_at(8).unwrap_or(0) };

    // Only interested syscalls: read=0, write=1, open=2, close=3,
    // sendto=44, recvfrom=45, sendmsg=46, recvmsg=47, epoll_wait=232
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
