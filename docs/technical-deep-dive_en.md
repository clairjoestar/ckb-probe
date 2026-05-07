# ckb-probe Technical Deep Dive

> This document is aimed at developers, providing a detailed explanation of ckb-probe's architectural design, core algorithms, data flows, and implementation details of each module.

---

## 1. Project Overview

ckb-probe is an eBPF-based deep observability tool for CKB full nodes. It uses three types of BPF programs -- uprobe, kprobe, and tracepoint -- to perform application-semantic real-time performance tracing on a running CKB node **without modifying CKB source code**.

### 1.1 Technology Stack

| Layer | Technology | Description |
|-------|-----------|-------------|
| Kernel-space BPF programs | Rust + aya-ebpf 0.1 | `#![no_std]`, compiled to `bpfel-unknown-none` target |
| User-space control program | Rust + aya 0.13 + tokio | Async event consumption + periodic Map polling |
| ELF symbol resolution | goblin 0.9 + rustc-demangle | Pure Rust implementation, no binutils required |
| CLI framework | clap 4 (derive) | Subcommands: check / symbols / rocksdb |
| Serialization | serde + serde_json | JSON report output |
| Build system | cargo workspace + xtask | eBPF dual-target build management |

### 1.2 Project Structure

```
ckb-probe/                          ~4,187 lines of Rust code
├── Cargo.toml                      workspace root config
├── .cargo/config.toml              cargo xtask alias
│
├── ckb-probe-common/               Shared type library (567 lines)
│   ├── Cargo.toml                  feature gate: user(std) / no_std(ebpf)
│   └── src/lib.rs                  eBPF event structs + symbol registry
│
├── ckb-probe-ebpf/                 eBPF kernel-space program (458 lines)
│   ├── Cargo.toml                  target = bpfel-unknown-none
│   └── src/main.rs                 uprobe/kprobe/tracepoint BPF programs
│
├── ckb-probe/                      User-space CLI (3,115 lines)
│   ├── Cargo.toml
│   └── src/
│       ├── main.rs                 tokio async entry point (28 lines)
│       ├── cli.rs                  clap CLI definition (188 lines)
│       └── commands/
│           ├── mod.rs              Module declarations (3 lines)
│           ├── check.rs            Environment detection + eBPF validation (776 lines)
│           ├── symbols.rs          ELF symbol analysis engine (860 lines)
│           └── rocksdb.rs          RocksDB live monitoring (1,260 lines)
│
└── xtask/                          Build helper (47 lines)
    └── src/main.rs                 cargo xtask build-ebpf / build
```

### 1.3 Key Design Decisions

**Why the Aya framework?**

Aya enables pure Rust full-stack eBPF development -- both kernel-space and user-space code use the same language. Event types are shared directly through the `ckb-probe-common` crate, eliminating serialization overhead and type inconsistency risks at the C/Rust boundary. No need to install clang/llvm/libelf.

**Why is the RocksDB C API the preferred probe target?**

CKB compiles RocksDB from source via the `librocksdb-sys` crate and statically links it. RocksDB's C API functions (e.g., `rocksdb_get_pinned_cf`) are declared with `extern "C"`, making them immune to Rust name mangling and LTO inlining, with symbol names that remain stable across all CKB versions -- an ideal target for uprobes.

---

## 2. ckb-probe-common: Shared Type Library

### 2.1 Conditional Compilation Architecture

```rust
#![cfg_attr(not(feature = "user"), no_std)]
```

`ckb-probe-common` serves two compilation targets:

| Target | Feature | std | Available Types |
|--------|---------|-----|----------------|
| eBPF kernel-space (`bpfel-unknown-none`) | None (default-features = false) | `no_std` | Event structs + enums + constants |
| User-space (`x86_64-unknown-linux-gnu`) | `user` | std | Above + serde serialization + aya::Pod + symbol registry |

This design ensures that kernel-space and user-space share **exactly the same memory layout**, eliminating the risk of manual FFI definitions.

### 2.2 eBPF Shared Event Structs

All structs are annotated with `#[repr(C)]` to ensure deterministic memory layout:

```rust
/// uprobe latency event -- 28 bytes
#[repr(C)]
#[derive(Clone, Copy)]
pub struct UprobeLatencyEvent {
    pub pid: u32,         // Process ID
    pub tid: u32,         // Thread ID (for entry/return pairing)
    pub func_id: u32,     // RocksDbFunc enum value, distinguishes operations
    pub latency_ns: u64,  // Function execution duration (nanoseconds)
    pub ts: u64,          // Kernel monotonic clock timestamp
}
```

`func_id` uses the `RocksDbFunc` enum encoding, supporting 8 RocksDB operations:

```rust
#[repr(u32)]
pub enum RocksDbFunc {
    GetPinnedCf = 1,       // CKB primary read path
    Put = 2,               // Generic write
    Delete = 3,            // Delete
    Write = 4,             // WriteBatch atomic commit
    NewIteratorCf = 5,     // Create iterator
    MultiGetCf = 6,        // Batch read
    TransactionPutCf = 7,  // CKB primary write path (transactional write)
    TransactionCommit = 8, // Transaction commit
}
```

### 2.3 Monitoring Aggregation Types

```rust
/// Aggregated statistics in PerCpuArray, each CPU maintains an independent copy
#[repr(C)]
#[derive(Clone, Copy, Default)]
pub struct OpStats {
    pub count: u64,       // Call count
    pub total_ns: u64,    // Cumulative latency (nanoseconds)
    pub min_ns: u64,      // Minimum latency
    pub max_ns: u64,      // Maximum latency
    pub bytes_total: u64, // Cumulative payload bytes (0 if not tracked)
}

// User-space needs aya::Pod trait to read from PerCpuArray
#[cfg(feature = "user")]
unsafe impl aya::Pod for OpStats {}
```

`aya::Pod` is an unsafe marker trait declaring that the type can be safely deserialized from raw bytes. The `#[repr(C)]` layout of `OpStats` guarantees this.

### 2.4 Tiered Symbol Registry

`ProbeTargets` provides 53 pre-registered probe targets:

- **Tier 1** (20): RocksDB C API symbols, declared `extern "C"`, stable across versions
- **Tier 2** (21): Rust cross-crate public functions, mangled names include hash suffixes
- **Tier 3** (12): Crate-internal functions, typically eliminated by inlining in release builds

The registry's primary use: the `symbols` subcommand iterates through the registry, compares against actual symbols in the ELF `.symtab`, and generates a coverage report.

---

## 3. ckb-probe-ebpf: Kernel-Space BPF Programs

### 3.1 Compilation and Building

The eBPF program is compiled to the `bpfel-unknown-none` target (BPF little-endian byte order), using Rust nightly's `-Z build-std=core` to cross-compile the core library:

```bash
cargo +nightly build --target=bpfel-unknown-none -Z build-std=core --release
```

`xtask/src/main.rs` wraps this process:

```rust
fn build_ebpf() {
    let status = Command::new("cargo")
        .current_dir(std::env::current_dir().unwrap().join("ckb-probe-ebpf"))
        .args(["+nightly", "build", "--target=bpfel-unknown-none",
               "-Z", "build-std=core", "--release"])
        .status()
        .expect("failed to build eBPF program");
    assert!(status.success(), "eBPF build failed");
}
```

The build artifact is a BPF ELF file located at `ckb-probe-ebpf/target/bpfel-unknown-none/release/ckb-probe-ebpf`. The user-space program loads it into the kernel at runtime via `aya::Ebpf::load()`.

Key configuration in `Cargo.toml`:

```toml
[profile.release]
lto = true      # Link-time optimization, reduces BPF program size
panic = "abort"  # no_std environment cannot unwind

[profile.dev]
opt-level = 2    # Enable optimization even in dev builds, otherwise verifier may reject
```

### 3.2 BPF Map Architecture

BPF Maps are the data exchange channel between kernel-space and user-space programs. ckb-probe uses 11 Maps:

#### Configuration and Filtering

| Map | Type | Capacity | Data Flow | Purpose |
|-----|------|----------|-----------|---------|
| `TARGET_PID` | HashMap<u32, u8> | 8 | User-space -> Kernel-space | PID filter whitelist |
| `SLOW_THRESHOLD` | Array<u64> | 1 | User-space -> Kernel-space | Slow operation threshold (nanoseconds) |

#### Latency Measurement (entry/return pairing)

| Map | Type | Capacity | Data Flow | Purpose |
|-----|------|----------|-----------|---------|
| `UPROBE_START` | HashMap<u32, (u64, u32, u64)> | 1024 | Kernel-space internal | tid -> (timestamp, func_id, size) |
| `UPROBE_EVENTS` | PerfEventArray<UprobeLatencyEvent> | -- | Kernel-space -> User-space | Per-event latency output (for check) |

#### Aggregated Statistics (kernel-space computes, user-space reads)

| Map | Type | Capacity | Data Flow | Purpose |
|-----|------|----------|-----------|---------|
| `OP_STATS` | PerCpuArray<OpStats> | 9 | Kernel-space write / User-space read | Per-operation statistics aggregation |
| `LATENCY_HIST` | PerCpuArray<u64> | 576 | Kernel-space write / User-space read | log2 latency histogram |
| `SLOW_EVENTS` | RingBuf | 256KB | Kernel-space -> User-space | Above-threshold slow operation events (batch consumption, no per-event wakeup) |

#### Network and System Calls

| Map | Type | Capacity | Data Flow | Purpose |
|-----|------|----------|-----------|---------|
| `TCP_START` | HashMap<u32, u64> | 1024 | Kernel-space internal | kprobe entry timestamp |
| `TCP_EVENTS` | PerfEventArray<TcpEvent> | -- | Kernel-space -> User-space | TCP send/receive events |
| `SYSCALL_EVENTS` | PerfEventArray<SyscallEvent> | -- | Kernel-space -> User-space | syscall events |

**Why PerCpuArray instead of HashMap?**

PerCpuArray maintains independent data copies for each CPU, so the BPF program needs no atomic operations or locks when updating. The user-space merges values from all CPUs when reading. This avoids race conditions when multiple CPUs concurrently write to the same Map entry.

### 3.3 PID Filtering Mechanism

Every BPF program entry first checks whether the current process is the target CKB process:

```rust
#[inline(always)]
fn is_target_pid() -> bool {
    let pid = (bpf_get_current_pid_tgid() >> 32) as u32;
    unsafe { TARGET_PID.get(&pid).is_some() }
}
```

`bpf_get_current_pid_tgid()` returns a 64-bit value: the upper 32 bits are the tgid (i.e., PID), and the lower 32 bits are the tid (i.e., thread ID). A HashMap lookup determines whether the process is on the whitelist -- non-matching processes return immediately with an overhead of approximately 50ns.

### 3.4 uprobe Latency Measurement: Entry/Return Pairing

This is the core algorithm of the entire project. Each RocksDB function requires a pair of BPF programs:

**Entry (triggered at function entry):**

```rust
#[inline(always)]
fn uprobe_entry(func_id: u32) {
    if !is_target_pid() { return; }
    let (_, tid) = current_pid_tid();
    let ts = unsafe { bpf_ktime_get_ns() };          // Nanosecond monotonic clock
    let _ = UPROBE_START.insert(&tid, &(ts, func_id), 0);  // Store with tid as key
}
```

**Return (triggered at function return):**

```rust
#[inline(always)]
fn uprobe_return(ctx: &RetProbeContext) {
    let (pid, tid) = current_pid_tid();
    if let Some(&(start_ts, func_id)) = unsafe { UPROBE_START.get(&tid) } {
        let now = unsafe { bpf_ktime_get_ns() };
        let latency_ns = now.saturating_sub(start_ts);

        // 1) Per-event output (for check command's live collection)
        UPROBE_EVENTS.output(ctx, &event, 0);

        // 2) Aggregate to OP_STATS (PerCpuArray, no contention)
        if let Some(stats) = OP_STATS.get_ptr_mut(func_id) {
            (*stats).count += 1;
            (*stats).total_ns += latency_ns;
            // min/max update...
        }

        // 3) Update latency histogram
        let bucket = log2_u64(latency_ns);
        let hist_idx = func_id * HIST_BUCKETS + bucket;
        if let Some(count) = LATENCY_HIST.get_ptr_mut(hist_idx) {
            *count += 1;
        }

        // 4) Above threshold -> send slow operation event
        if let Some(threshold) = SLOW_THRESHOLD.get(0) {
            if *threshold > 0 && latency_ns > *threshold {
                SLOW_EVENTS.output(ctx, &slow, 0);
            }
        }

        let _ = UPROBE_START.remove(&tid);  // Clean up to prevent Map leaks
    }
}
```

**Why use tid as the key?** The same RocksDB function can be executed concurrently in different CKB threads. tid is unique per thread, ensuring that each call correctly pairs its own entry and return.

**Data Flow Diagram:**

```
CKB Thread A                         CKB Thread B
    |                                    |
    +- call rocksdb_get_pinned_cf()      +- call rocksdb_write()
    |  +- uprobe fires                   |  +- uprobe fires
    |  |  UPROBE_START[tidA] = (ts, 1)   |  |  UPROBE_START[tidB] = (ts, 4)
    |  |  ... function executes ...      |  |  ... function executes ...
    |  +- uretprobe fires               |  +- uretprobe fires
    |     latency = now - ts             |     latency = now - ts
    |     OP_STATS[1].count++            |     OP_STATS[4].count++
    |     LATENCY_HIST[1*64+bucket]++    |     LATENCY_HIST[4*64+bucket]++
    |     delete UPROBE_START[tidA]      |     delete UPROBE_START[tidB]
```

### 3.5 Verifier-safe log2 Implementation

The BPF verifier prohibits any code that could loop infinitely. The standard `while (v >>= 1) r++` loop would be rejected. ckb-probe uses a fully unrolled log2 via binary search:

```rust
#[inline(always)]
fn log2_u64(v: u64) -> u32 {
    if v == 0 { return 0; }
    let mut r = 0u32;
    let mut v = v;
    if v >= 1u64 << 32 { v >>= 32; r += 32; }  // Check upper 32 bits
    if v >= 1u64 << 16 { v >>= 16; r += 16; }  // Check upper 16 bits
    if v >= 1u64 << 8  { v >>= 8;  r += 8;  }  // Check upper 8 bits
    if v >= 1u64 << 4  { v >>= 4;  r += 4;  }  // Check upper 4 bits
    if v >= 1u64 << 2  { v >>= 2;  r += 2;  }  // Check upper 2 bits
    if v >= 1u64 << 1  { r += 1; }              // Last bit
    r
}
```

6 comparisons and shifts, compiling to ~18 BPF instructions. The verifier can statically prove termination. Output range is 0-63, corresponding exactly to 64 histogram buckets.

**Histogram bucket meaning:** Bucket i covers the latency range [2^i, 2^(i+1)) nanoseconds. For example:
- Bucket 10 = [1024, 2048) ns ~ 1-2 us
- Bucket 20 = [1048576, 2097152) ns ~ 1-2 ms
- Bucket 30 = [1073741824, 2147483648) ns ~ 1-2 s

### 3.6 BPF Program Inventory

| Program Name | Type | Attach Target | func_id |
|-------------|------|--------------|---------|
| `rocksdb_get_pinned_cf_entry/return` | uprobe/uretprobe | `rocksdb_get_pinned_cf` | 1 |
| `rocksdb_put_entry/return` | uprobe/uretprobe | `rocksdb_put` | 2 |
| `rocksdb_delete_entry/return` | uprobe/uretprobe | `rocksdb_delete` | 3 |
| `rocksdb_write_entry/return` | uprobe/uretprobe | `rocksdb_write` | 4 |
| `rocksdb_create_iterator_cf_entry/return` | uprobe/uretprobe | `rocksdb_create_iterator_cf` | 5 |
| `rocksdb_multi_get_cf_entry/return` | uprobe/uretprobe | `rocksdb_multi_get_cf` | 6 |
| `rocksdb_transaction_put_cf_entry/return` | uprobe/uretprobe | `rocksdb_transaction_put_cf` | 7 |
| `rocksdb_transaction_commit_entry/return` | uprobe/uretprobe | `rocksdb_transaction_commit` | 8 |
| `tcp_sendmsg_entry/return` | kprobe/kretprobe | `tcp_sendmsg` | -- |
| `tcp_recvmsg_entry/return` | kprobe/kretprobe | `tcp_recvmsg` | -- |
| `sys_enter_handler` | tracepoint | `raw_syscalls/sys_enter` | -- |

A total of 8 uprobe pairs (16 BPF programs) + 2 kprobe pairs (4) + 1 tracepoint = **21 BPF programs**.

### 3.7 Syscall Filtering

The tracepoint attaches to `raw_syscalls/sys_enter` and only captures 9 categories of system calls relevant to CKB:

```rust
let syscall_nr: u64 = unsafe { ctx.read_at(8).unwrap_or(0) };
match syscall_nr {
    0 | 1 | 2 | 3 | 44 | 45 | 46 | 47 | 232 => {}  // Syscalls of interest
    _ => return 0,  // Discard all others
}
```

`ctx.read_at(8)` reads the syscall number from offset 8 of the tracepoint context. This offset comes from the kernel's tracepoint format (`/sys/kernel/debug/tracing/events/raw_syscalls/sys_enter/format`).

---

## 4. ckb-probe symbols: ELF Symbol Analysis Engine

### 4.1 Analysis Pipeline

The 9-step analysis pipeline in `build_report()` within `commands/symbols.rs`:

```
ELF binary -> goblin parse -> metadata extraction -> dynamic deps -> RocksDB linkage detection
                                                                          |
         JSON/terminal output <- report summary <- Tier 3 trace <- Tier 2 match <- Tier 1 match <- demangled lookup table
```

| Step | Operation | Output |
|------|-----------|--------|
| 1 | Read ELF class, architecture | `ElfOverview` |
| 2 | Count `.symtab` / `.dynsym` symbols, detect DWARF and strip status | strip_status |
| 3 | Enumerate dynamic dependencies (`DT_NEEDED`) | `dynamic_deps` |
| 4 | RocksDB linkage type detection | `RocksdbLinkage` |
| 5 | Build demangled lookup table | `HashMap<String, Vec<ResolvedSym>>` |
| 6 | Tier 1 exact match | `tier1: Vec<SymbolInfo>` |
| 7 | Tier 2 substring match (with noise filtering) | `tier2: Vec<SymbolInfo>` |
| 8 | Tier 3 trace missing | `tier3_missing` |
| 9 | Summary + recommendations | `ReportSummary` |

### 4.2 RocksDB Linkage Type Determination

```rust
let rocksdb_linkage = if rocksdb_in_dynlibs || rocksdb_in_dynsym {
    RocksdbLinkage::Dynamic    // DT_NEEDED or .dynsym contains rocksdb
} else if total_rocksdb_c_symbols > 0 {
    RocksdbLinkage::Static     // .symtab has rocksdb_* functions but not in dynamic table
} else {
    RocksdbLinkage::Unknown    // No rocksdb symbols at all
};
```

CKB's detection result is always **Static**: `.symtab` contains 155 `rocksdb_*` function symbols, but `DT_NEEDED` does not include `librocksdb.so`.

### 4.3 Tier 2 Noise Filtering: `is_direct_match()`

Rust binaries contain large numbers of compiler-generated generic instantiations (drop glue, Future poll, Box wrappers) that embed the target function path within `<>` generic parameters:

```
core::ptr::drop_in_place<tokio::..::Cell<NetworkService::start<Handle>>>
```

A simple `contains()` substring match would produce many false positives. `is_direct_match()` solves this through **angle bracket depth tracking**:

```rust
fn is_direct_match(demangled: &str, target_path: &str) -> bool {
    // 1. Prefix blocklist: exclude core::ptr::drop_in_place<, GenFuture<, etc.
    // 2. Traverse the string, maintaining <> nesting depth
    // 3. Only accept matches at depth 0 (top-level scope)
    // 4. Closure suffixes ::{{closure}} are still considered valid matches
}
```

---

## 5. ckb-probe check: Environment Detection + eBPF Validation

### 5.1 8 Environment Checks

| # | Check Item | Implementation | Pass Criteria |
|---|-----------|---------------|---------------|
| 1 | Kernel version | `nix::sys::utsname::uname()` parse major.minor | >= 5.8 |
| 2 | BPF config | Parse `/boot/config-$(uname -r)` | CONFIG_BPF=y + BPF_SYSCALL=y + BPF_JIT=y |
| 3 | BTF support | Check file existence | `/sys/kernel/btf/vmlinux` exists |
| 4 | Permissions | `geteuid()` + check `CapEff` bit 39 | root or CAP_BPF |
| 5 | bpf() syscall | `libc::syscall(SYS_bpf, 0, null, 0)` | errno != ENOSYS(38) |
| 6 | uprobe support | Check tracefs path | `uprobe_events` file exists |
| 7 | CKB process | `pgrep -x ckb` | Running process found |
| 8 | CKB symbols | `nm` check 3 key symbols | At least 1 rocksdb_* exists |

### 5.2 eBPF Probe Validation Flow

When both `--binary` and `--pid` are provided, actual attach testing is performed:

1. Load BPF ELF into kernel (`aya::Ebpf::load()`)
2. Write to `TARGET_PID` Map
3. Execute `attach()` on 6 uprobe pairs one by one, recording success/failure
4. Check whether 19 Tier 1 symbols exist in the ELF via `goblin`
5. Attach 4 kprobes (tcp_sendmsg/recvmsg entry/return)
6. Attach 1 tracepoint (raw_syscalls/sys_enter)
7. Output validation results

### 5.3 Live Event Collection

After validation completes, it automatically enters a 3-second event collection mode:

```rust
async fn collect_live_events(bpf: &mut aya::Ebpf, probe_type: &str) -> Result<()> {
    let cpus = online_cpus()?;

    // Create AsyncPerfEventArray for each event type (uprobe/tcp/syscall)
    // Open a ring buffer for each CPU
    // Start tokio tasks to asynchronously read events
    // Wait 3 seconds then abort all tasks
    // Print event count summary
}
```

`AsyncPerfEventArray` is based on tokio's `epoll` event loop, waking the read task when new data is available in the ring buffer. Each CPU has an independent ring buffer to avoid cross-CPU lock contention.

---

## 6. ckb-probe rocksdb: RocksDB Live Monitoring

### 6.1 5 Core Monitored Operations

| Operation | ELF Symbol | func_id | Role in CKB |
|-----------|-----------|---------|-------------|
| GET | `rocksdb_get_pinned_cf` | 1 | Primary read path (zero-copy pinned read) |
| PUT | `rocksdb_transaction_put_cf` | 7 | Primary write path (transactional write) |
| WRITE | `rocksdb_write` | 4 | WriteBatch atomic commit |
| ITER_NEW | `rocksdb_create_iterator_cf` | 5 | Create iterator |
| TXN_COMMIT | `rocksdb_transaction_commit` | 8 | Transaction commit |

### 6.2 RocksDbCollector Data Flow

```
Kernel-space BPF                     User-space Collector
+-------------------+                 +-------------------------------+
| uprobe_return:     |                 | Poll every N seconds:         |
|   OP_STATS[fid]    | --(per-CPU)-->  |   read OP_STATS -> merge      |
|   LATENCY_HIST     | --(per-CPU)-->  |   read LATENCY_HIST -> merge  |
|   SLOW_EVENTS      | --(perf buf)-->|   async consume -> print      |
+-------------------+                 |                               |
                                      | Compute:                      |
                                      |   QPS = delta_count / interval|
                                      |   Avg = delta_total_ns /      |
                                      |         delta_count           |
                                      |   P50/P99 = histogram walk    |
                                      +-------------------------------+
```

### 6.3 PerCpuArray Merge Algorithm

When reading from PerCpuArray in user-space, aya returns `PerCpuValues<T>` -- an array containing one value per CPU. Merge logic:

```rust
fn read_all_snapshots(bpf: &mut aya::Ebpf) -> Result<Vec<OpSnapshot>> {
    let op_stats: PerCpuArray<_, OpStats> =
        PerCpuArray::try_from(bpf.map("OP_STATS").unwrap())?;

    for func_id in 0..MAX_FUNC_ID {
        if let Ok(per_cpu) = op_stats.get(&func_id, 0) {
            let s = &mut snapshots[func_id as usize];
            for v in per_cpu.iter() {      // Iterate over all CPUs' values
                s.count += v.count;         // Sum
                s.total_ns += v.total_ns;   // Sum
                // min: take the minimum across all CPUs
                if v.min_ns != 0 && (s.min_ns == 0 || v.min_ns < s.min_ns) {
                    s.min_ns = v.min_ns;
                }
                // max: take the maximum across all CPUs
                if v.max_ns > s.max_ns {
                    s.max_ns = v.max_ns;
                }
            }
        }
    }
    // Similarly merge LATENCY_HIST...
}
```

### 6.4 Percentile Approximation Algorithm

Approximating P50/P99 from a log2 histogram:

```rust
fn percentile_from_hist(hist: &[u64; 64], pct: f64) -> u64 {
    let total: u64 = hist.iter().sum();
    let target = (total as f64 * pct / 100.0).ceil() as u64;
    let mut acc = 0u64;
    for (i, &count) in hist.iter().enumerate() {
        acc += count;
        if acc >= target {
            // Bucket i covers [2^i, 2^(i+1)), return midpoint
            let lo = 1u64 << i;
            let hi = 1u64 << (i + 1);
            return (lo + hi) / 2;
        }
    }
    0
}
```

This gives an **approximate value**, with precision limited by the granularity of log2 buckets (each bucket covers a 2x range). However, for monitoring scenarios, distinguishing "P99 is 5ms vs 10ms" is sufficient.

### 6.5 Delta Computation

`OP_STATS` and `LATENCY_HIST` are **cumulative values** (the BPF kernel side continuously increments), so user-space needs to perform delta computation to obtain the current period's QPS and latency:

```rust
let delta_count = cur[id].count.saturating_sub(prev[id].count);  // New calls this period
let delta_ns = cur[id].total_ns.saturating_sub(prev[id].total_ns);  // New latency this period

let qps = delta_count / interval;
let avg_us = delta_ns as f64 / delta_count as f64 / 1000.0;

// Histogram also needs delta
for i in 0..64 {
    delta_hist[i] = cur[id].hist[i].saturating_sub(prev[id].hist[i]);
}
```

### 6.6 Four Output Modes

| Mode | Trigger | Output Content |
|------|---------|---------------|
| Default | `ckb-probe rocksdb --binary ... --pid ...` | Live-refreshing stats table (QPS/Avg/P50/P99/Status) |
| Histogram | `--histogram` | Stats table + ASCII latency distribution bar chart |
| Slow operations | `--slow --threshold <us>` | Above-threshold operation live log stream |
| JSON | `--json` | Machine-readable JSON output |

### 6.7 Graceful Shutdown

```rust
let running = Arc::new(AtomicBool::new(true));
let r = running.clone();
tokio::spawn(async move {
    let _ = tokio::signal::ctrl_c().await;
    r.store(false, Ordering::SeqCst);  // Ctrl+C flips the flag
});
```

The main loop and event consumption tasks all check the `running` flag. When Ctrl+C is triggered, all tasks exit in an orderly fashion, and BPF programs are automatically unloaded when `aya::Ebpf` is dropped, leaving no residual probes in the kernel.

---

## 7. Build System

### 7.1 Workspace Layout

```toml
[workspace]
members = ["ckb-probe", "ckb-probe-common", "xtask"]
exclude = ["ckb-probe-ebpf"]  # eBPF builds independently, requires nightly + special target
resolver = "2"
```

`ckb-probe-ebpf` is excluded because it requires `cargo +nightly` and the `bpfel-unknown-none` target, while the other workspace members use stable Rust.

### 7.2 xtask Pattern

`xtask` is a Rust community convention -- using a Rust program to manage the build process:

```bash
cargo xtask build-ebpf   # Build eBPF only
cargo xtask build         # Build eBPF + user-space
```

The alias in `.cargo/config.toml` makes `cargo xtask` equivalent to `cargo run --package xtask --`.

### 7.3 Dual Compilation of ckb-probe-common

`ckb-probe-common` is compiled twice:

1. **For eBPF**: `default-features = false`, enables `no_std`, compiles only structs and enums
2. **For user-space**: `default-features = true` (`user` feature), enables `std` + `serde` + `aya::Pod`

This is controlled through `Cargo.toml` features:

```toml
[features]
default = ["user"]
user = ["serde", "aya"]    # Dependencies only needed in std environment
```

And conditional compilation in source code:

```rust
#![cfg_attr(not(feature = "user"), no_std)]          // eBPF: no_std
#[cfg(feature = "user")] use serde::{Serialize, ...}; // User-space only
#[cfg(feature = "user")] unsafe impl aya::Pod for OpStats {} // User-space only
```

---

## 8. Data Validation

Actual test data from a CKB v0.204.0 node:

### 8.1 check Validation Results

```
Environment checks: 8/8 passed
eBPF validation: 27/33 passed (6 failures are expected missing symbols)
Live collection (3 seconds): 2116 uprobe + 793 syscall events
```

### 8.2 rocksdb Monitoring Data

```
GET       : ~1500 QPS, avg ~700us, P50 ~25us, P99 ~12ms
PUT       :   ~50 QPS, avg ~8us,   P50 ~6us,  P99 ~25us
WRITE     :   ~40 QPS, avg ~45us,  P50 ~49us, P99 ~98us
ITER_NEW  :   ~55 QPS, avg ~17us,  P50 ~12us, P99 ~49us
TXN_COMMIT:   ~15 QPS, avg ~100us, P50 ~98us, P99 ~197us
```

The large discrepancy between GET operation's high P99 (~12ms) and low P50 (~25us) indicates the presence of occasional slow queries -- likely related to RocksDB compaction or block cache misses, which is exactly the kind of issue ckb-probe is designed to help diagnose.

---

*Document written by the ckb-probe development team, based on ckb-probe v0.1.0 source code.*
