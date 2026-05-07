# ckb-probe Code Architecture

> Three crates work together: `ckb-probe-common` defines shared types, `ckb-probe-ebpf` runs in kernel space, `ckb-probe` (userspace) orchestrates everything.

## 1. Crate Relationship

```
┌─────────────────────────────────────────────────────────────────┐
│                         User Space                              │
│                                                                 │
│  ckb-probe/src/commands/rocksdb.rs                              │
│  ┌──────────────────────────────────────────────────────────┐   │
│  │ 1. Load eBPF ELF binary                                  │   │
│  │ 2. Set TARGET_PID + SLOW_THRESHOLD in maps               │   │
│  │ 3. Attach uprobe/uretprobe to CKB binary symbols         │   │
│  │ 4. Poll OP_STATS / LATENCY_HIST every N seconds          │   │
│  │ 5. Read RingBuf for slow events (slow mode)              │   │
│  │ 6. Compute QPS / Avg / P50 / P99 / Bytes/s / anomalies  │   │
│  │ 7. Render table / histogram / slow / JSON                │   │
│  └──────────────────────────────────────────────────────────┘   │
│         │ uses types from              │ reads maps from        │
│         ▼                              ▼                        │
│  ckb-probe-common/src/lib.rs    ckb-probe-ebpf/src/main.rs     │
│  ┌────────────────────┐         (compiled to BPF ELF,          │
│  │ OpStats             │          loaded into kernel)           │
│  │ SlowEvent           │                                        │
│  │ RocksDbFunc enum    │                                        │
│  │ MAX_FUNC_ID = 9     │                                        │
│  │ HIST_BUCKETS = 64   │                                        │
│  └────────────────────┘                                         │
│         ▲ uses types from                                       │
├─────────┼───────────────────────────────────────────────────────┤
│         │              Kernel Space                              │
│                                                                 │
│  ckb-probe-ebpf/src/main.rs                                    │
│  ┌──────────────────────────────────────────────────────────┐   │
│  │ BPF programs (triggered by kernel on each RocksDB call): │   │
│  │                                                          │   │
│  │ uprobe_entry:                                            │   │
│  │   if pid != TARGET_PID → return                          │   │
│  │   UPROBE_START[tid] = (timestamp, func_id, size)         │   │
│  │                                                          │   │
│  │ uretprobe_return:                                        │   │
│  │   (start_ts, func_id, size) = UPROBE_START[tid]          │   │
│  │   latency = now - start_ts                               │   │
│  │   OP_STATS[func_id].count++                              │   │
│  │   OP_STATS[func_id].total_ns += latency                  │   │
│  │   LATENCY_HIST[func_id * 64 + log2(latency)]++          │   │
│  │   if latency > SLOW_THRESHOLD → RingBuf.output(event)   │   │
│  │   delete UPROBE_START[tid]                               │   │
│  └──────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────┘
```

## 2. ckb-probe-common (Shared Types)

`#![no_std]` compatible — used by both kernel and userspace.

### Core Data Structures

```rust
// Per-operation aggregated stats (in PerCpuArray, one per func_id)
struct OpStats {
    count: u64,       // how many times this op was called
    total_ns: u64,    // sum of all latencies
    min_ns: u64,
    max_ns: u64,
    bytes_total: u64, // sum of payload bytes (0 if not tracked)
}

// Individual slow event (sent via RingBuf when latency > threshold)
struct SlowEvent {
    pid: u32,
    tid: u32,
    func_id: u32,     // which RocksDB operation (see RocksDbFunc enum)
    latency_ns: u64,
    size: u64,         // payload bytes
    ts: u64,           // bpf_ktime_get_ns timestamp
}

// Maps func_id numbers to operation names
enum RocksDbFunc {
    GetPinnedCf = 1,       // GET
    Put = 2,
    Delete = 3,
    Write = 4,             // WRITE
    NewIteratorCf = 5,     // ITER_NEW
    MultiGetCf = 6,
    TransactionPutCf = 7,  // PUT
    TransactionCommit = 8, // TXN_COMMIT
}

const MAX_FUNC_ID: u32 = 9;   // array size for OP_STATS
const HIST_BUCKETS: u32 = 64;  // log2 buckets covering 1ns to 2^63 ns
```

### Userspace-only types (`#[cfg(feature = "user")]`)

- `SymbolTier` / `SymbolCategory` — for `ckb-probe symbols` classification
- `SymbolReport` / `SymbolInfo` — symbol analysis output
- `ProbeTargets` — static registry of 20 Tier 1 + 21 Tier 2 + 12 Tier 3 targets

## 3. ckb-probe-ebpf (Kernel Space)

### BPF Maps

| Map | Type | Size | Direction | Purpose |
|-----|------|------|-----------|---------|
| `TARGET_PID` | HashMap | 8 | User→Kernel | Only trace this PID |
| `UPROBE_START` | HashMap | 1024 | Kernel internal | tid → (timestamp, func_id, size) for entry/return pairing |
| `OP_STATS` | PerCpuArray | 9 | Kernel→User (poll) | Per-op aggregated count/total_ns/bytes |
| `LATENCY_HIST` | PerCpuArray | 576 | Kernel→User (poll) | log2 histogram (9 ops × 64 buckets) |
| `SLOW_EVENTS` | RingBuf | 256KB | Kernel→User (batch) | Above-threshold slow events |
| `SLOW_THRESHOLD` | Array | 1 | User→Kernel | Threshold in nanoseconds |
| `PUT_PENDING_BYTES` | HashMap | 1024 | Kernel internal | Per-tid byte accumulator for TXN_COMMIT |

### Entry/Return Pairing Logic

Every monitored RocksDB function has a uprobe (entry) and uretprobe (return):

```
CKB calls rocksdb_get_pinned_cf(db, cf, key, klen, &errptr)
    │
    ▼ kernel triggers uprobe
    uprobe_entry(func_id=1):
        if pid != TARGET_PID → skip
        UPROBE_START[tid] = (bpf_ktime_get_ns(), 1, 0)
    │
    │ ... function executes inside CKB ...
    │
    ▼ kernel triggers uretprobe
    uprobe_return(ctx):
        (start_ts, func_id, entry_size) = UPROBE_START[tid]
        latency = now - start_ts
        value_size = bpf_probe_read_user(ctx.ret() + 8)  // PinnableSlice.size_

        // Write to 3 maps simultaneously:
        OP_STATS[1].count++; OP_STATS[1].total_ns += latency; OP_STATS[1].bytes_total += value_size
        LATENCY_HIST[1*64 + log2(latency)]++
        if latency > SLOW_THRESHOLD[0] → SLOW_EVENTS.output(SlowEvent{...})

        delete UPROBE_START[tid]
```

### Per-Operation Specialization

Each operation pair has custom entry/return logic for extracting bytes:

| Op | Entry | Return |
|----|-------|--------|
| GET | `uprobe_entry(1)` — no args needed | `ctx.ret()` → PinnableSlice ptr → read `size_` at offset 8 |
| PUT | `ctx.arg(5)` reads `vlen` + accumulates into `PUT_PENDING_BYTES[tid]` | Standard return |
| WRITE | `uprobe_entry(4)` — no bytes (WriteBatch internal) | Standard return |
| ITER_NEW | `uprobe_entry(5)` — no bytes | Standard return |
| TXN_COMMIT | Snapshots `PUT_PENDING_BYTES[tid]` then clears it | Standard return |

## 4. ckb-probe (Userspace) — rocksdb.rs

### Startup Flow

```rust
pub async fn run(args: RocksdbArgs) -> Result<()> {
    // 1. Load BPF ELF
    let data = std::fs::read("ckb-probe-ebpf/.../ckb-probe-ebpf")?;
    let mut bpf = aya::Ebpf::load(&data)?;

    // 2. Configure maps
    HashMap::try_from(bpf.map_mut("TARGET_PID"))?.insert(args.pid, 1, 0)?;
    Array::try_from(bpf.map_mut("SLOW_THRESHOLD"))?.set(0, threshold_ns, 0)?;

    // 3. Attach 5 uprobe pairs to CKB binary symbols
    for (entry_fn, ret_fn, symbol, ...) in MONITOR_PROBES {
        let uprobe = bpf.program_mut(entry_fn).try_into::<UProbe>()?;
        uprobe.load()?;
        uprobe.attach(Some(symbol), 0, &binary, None)?;  // ← kernel hooks symbol
        // ... same for uretprobe ...
    }

    // 4. Enter monitoring loop (table / histogram / slow / json)
    loop { ... }
}
```

### Data Collection Loop (Table / Histogram / JSON modes)

```
Every N seconds:
  1. Read OP_STATS PerCpuArray → merge per-CPU values → get current totals
  2. Read LATENCY_HIST PerCpuArray → merge per-CPU values → get current histogram
  3. Subtract previous snapshot → get this-interval delta
  4. Compute:
     - QPS = delta_count / interval
     - Avg = delta_total_ns / delta_count
     - P50/P99 = find bucket in delta histogram where cumulative count hits 50%/99%
     - Bytes/s = delta_bytes / interval
  5. Feed to EWMA anomaly detector
  6. Render output
```

### Slow Mode (RingBuf)

```
Single reader thread:
  AsyncFd wraps RingBuf file descriptor
  Every 100ms (or on data availability):
    while ring.next() has data:
      parse SlowEvent from raw bytes
      send to renderer via mpsc channel

Renderer:
  Maintains VecDeque of last 8 slow events
  Every N seconds, redraws table with latest events + total count + BPF loss counter
```

### EWMA Anomaly Detection

```
Per cycle, for each operation:
  if warming_up (< 300s):
    baseline[op] = EWMA update only, no alerts
  else:
    effective_base = max(baseline[op], 50μs)  // absolute floor
    if current_avg > 5× effective_base → alert (AVG trigger)
    if current_p99 > 3× p99_baseline   → alert (P99 trigger)
    if current_p99 > hard_cap[op]      → alert (CAP trigger)
    if any trigger fired:
      DON'T update baseline (prevents absorption)
    else:
      baseline[op] = 0.05 × current + 0.95 × baseline
```

### S-4 Process Restart Recovery

```
Background thread (1s interval):
  check /proc/{pid} exists
  if gone:
    set running = false → monitoring loop exits
    drop BPF resources

  poll /proc/*/exe for same binary
  if found new PID:
    reload BPF ELF from scratch
    re-insert TARGET_PID
    re-attach all uprobes
    resume monitoring loop
```

## 5. Data Flow Summary

```
CKB process                    Kernel                         ckb-probe userspace
─────────────                  ──────                         ───────────────────
rocksdb_get_pinned_cf() ──→ uprobe triggers BPF program
                              │
                              ├→ UPROBE_START[tid] = timestamp
                              │  (function executes...)
                              ├→ latency = now - timestamp
                              ├→ OP_STATS[1] += {count, ns, bytes}  ──→ poll every Ns → QPS/Avg/P50/P99
                              ├→ LATENCY_HIST[bucket]++              ──→ poll every Ns → histogram
                              └→ if slow: RingBuf.output(event)     ──→ batch read 100ms → slow table
```

All three output paths originate from the same uprobe/uretprobe execution. The only difference between modes is which map the userspace reads.
