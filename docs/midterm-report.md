# ckb-probe Midterm Report (Week 2–4)

> Milestone 2 completed ahead of schedule. EWMA anomaly detection (originally Week 5) delivered in Week 4.

## 1. Milestone Status

| Milestone | Target | Status |
|-----------|--------|--------|
| Milestone 1 (Week 3) | eBPF feasibility verified, `check` + `symbols` delivered | ✅ Achieved |
| Milestone 2 (Week 5→4) | `ckb-probe rocksdb` usable on testnet with anomaly detection | ✅ Achieved early |

## 2. Week 2: Binary Symbol Reconnaissance

**Deliverable:** `ckb-probe symbols` subcommand (876 lines)

Scanned CKB v0.205.0 official release and self-compiled binaries. Key findings:

| Dimension | Official Release | Self-compiled |
|-----------|-----------------|---------------|
| File size | 51.6 MB | 903.2 MB |
| `.symtab` symbols | 78,847 | 152,937 |
| Function symbols | 53,522 | 87,004 (+62.6%) |
| RocksDB C API symbols | 151 | 155 |
| RocksDB linkage | Static | Static |

**Three-tier classification system:**
- **Tier 1** (RocksDB C API, `extern "C"`) — 15/20 found, stable across versions, ideal uprobe targets
- **Tier 2** (Rust cross-crate public) — 8/21 found, hash suffix varies per build
- **Tier 3** (inlined/LTO-eliminated) — unavailable in release builds

**Tier 2 noise filtering:** `is_direct_match()` filters compiler-generated symbols (drop glue, GenFuture, Box wrappers) by tracking `<>` nesting depth and applying prefix blacklists.

## 3. Week 3: eBPF Feasibility Validation

**Deliverable:** `ckb-probe check` subcommand + eBPF kernel programs

Four validation targets all passed:

| Validation | Result |
|------------|--------|
| RocksDB uprobe/uretprobe latency measurement | ✅ 4 entry/return pairs attached |
| Multi-function uprobe (19 Tier 1 symbols) | ✅ 15/19 confirmed attachable |
| TCP kprobe (tcp_sendmsg/recvmsg) | ✅ 4/4 attached, real-time byte capture |
| sys_enter tracepoint | ✅ syscall distribution captured |

**`ckb-probe check` features:**
- 8-point environment verification (kernel, BTF, BPF, permissions, uprobe, CKB process, symbols)
- Full eBPF probe validation when `--binary` and `--pid` provided
- 3-second live event collection with per-probe-type counts

**Milestone 1 achieved.**

## 4. Week 4: RocksDB Deep Tracing + EWMA Anomaly Detection

**Deliverable:** `ckb-probe rocksdb` subcommand (1,156 lines) — core monitoring module

### 4.1 Five Operations Tracked

| Op | RocksDB Function | CKB Call Path | Bytes/s Source |
|----|-----------------|---------------|----------------|
| GET | `rocksdb_get_pinned_cf` | Block/header/cell lookup | uretprobe reads PinnableSlice `size_` at offset 8 |
| PUT | `rocksdb_transaction_put_cf` | Single write in transaction | entry probe reads `vlen` from `ctx.arg(5)` |
| WRITE | `rocksdb_write` | Atomic WriteBatch commit | — (ABI-dependent, skipped) |
| ITER_NEW | `rocksdb_create_iterator_cf` | Range-scan entry point | — (no payload) |
| TXN_COMMIT | `rocksdb_transaction_commit` | Transaction commit | per-tid `PUT_PENDING_BYTES` accumulator |

**Bytes/s validation:** PUT and TXN_COMMIT show identical 3.2 KB/s — exactly expected since "all PUTs within a transaction are settled at commit time." This is a strong end-to-end correctness signal.

### 4.2 BPF Map Architecture

| Map | Type | Capacity | Purpose |
|-----|------|----------|---------|
| `TARGET_PID` | HashMap | 8 | PID filter |
| `UPROBE_START` | HashMap | 1024 | tid → (timestamp, func_id, size) |
| `OP_STATS` | PerCpuArray | 9 | Per-op count/total_ns/bytes aggregation |
| `LATENCY_HIST` | PerCpuArray | 576 | log2-bucket histogram (9 ops × 64 buckets) |
| `SLOW_EVENTS` | PerfEventArray | — | Above-threshold events |
| `SLOW_THRESHOLD` | Array | 1 | Configurable threshold (ns) |
| `PUT_PENDING_BYTES` | HashMap | 1024 | Per-tid PUT byte accumulator |

**Design choice — PerCpuArray over HashMap:** Avoids cross-CPU lock contention. Each CPU writes to its own slot independently; userspace merges per-CPU values on read.

### 4.3 Four Output Modes

**Default table** — Real-time QPS / Avg / P50 / P99 / Bytes/s, 1s refresh, CKB version auto-detected in header.

**`--histogram`** — log2-bucket latency distribution per operation. Revealed GET's bimodal latency pattern:
- Peak 1: ~16-65μs (Block Cache hit)
- Peak 2: ~2-8ms (Cache miss → disk SST lookup)

This bimodal structure is invisible in aggregate averages — histogram mode exists to capture tail latency shapes.

**`--slow --threshold N`** — Individual operations exceeding threshold, via PerfEventArray (zero overhead when no events exceed threshold). Shows timestamp, operation, latency, payload size. Size column reveals whether slowness is from data volume or I/O bottleneck.

**`--json`** — Machine-readable JSONL output with `operations{}`, `anomalies[]`, `timestamp`, `pid`. Pipe to jq / Prometheus / ELK.

### 4.4 EWMA Anomaly Detection (originally Week 5, delivered early)

**Parameters:**
- α = 0.05 (slow adaptation, stable baseline)
- Warmup: 300s (no alerts during baseline collection)
- Three trigger paths: avg > 5× baseline | P99 > 3× baseline | P99 > absolute cap
- Per-op absolute P99 caps: GET 50ms, PUT 10ms, WRITE 50ms, ITER_NEW 5ms, TXN_COMMIT 100ms

**Four safety properties:**
1. No false positives during cold start (300s warmup)
2. No false positives from transient jitter (50μs absolute floor + baseline not updated during anomaly)
3. No missed detections for sustained degradation (absolute P99 caps)
4. Low-QPS operations not silenced (5-second sliding window fallback)

**Status bar in default table:**
```
  Status: ⏳ Warming up — Collecting baseline (174s remaining).
  Status: ✅ Normal — All latencies within baseline.
  ⚠️  ANOMALY DETECTED [13:42:08]
    → GET [P99+CAP]  avg 1842.3μs (base 312.4μs, ×5.9)
    → Probable cause: Compaction storm (WRITE P99 = 4.7ms)
```

**Milestone 2 achieved (1 week ahead of schedule).**

## 5. Core Data Structures

```rust
// Kernel-side, per-CPU aggregation
struct OpStats {
    count: u64,       // operation count
    total_ns: u64,    // latency sum (nanoseconds)
    bytes_total: u64, // payload bytes sum
}

// Kernel→userspace, per-event
struct SlowEvent {
    func_id: u32,      // which RocksDB operation
    latency_ns: u64,   // measured latency
    size: u64,          // payload bytes (0 if not tracked)
    ts: u64,            // bpf_ktime_get_ns timestamp
}
```

## 6. Verified on Real CKB Testnet

All features tested on CKB v0.204.0 testnet node (24-core Linux 6.8):
- Four output modes producing real data
- EWMA anomaly detection triggering on natural compaction events
- Bytes/s consistency validated (PUT = TXN_COMMIT throughput)
- BPF verifier passing all programs without modification

## 7. Remaining Work (Week 5–8)

| Task | Description |
|------|-------------|
| Performance optimization | perf buffer sizing, BPF map capacity tuning |
| S-4 process restart recovery | Auto-reconnect when CKB restarts |
| Docker reproducible environment | Dockerfile + demo scripts + env-check |
| P-1~P-4 performance testing | CPU / RSS / event loss / sync degradation |
| 48h stability testing (S-1~S-4) | Long-run validation |
| CLI refinement | clap help text, error codes |
| Final report + v0.1.0 release | Documentation, packaging |

---

*Detailed reports: [Week 2 Symbol Analysis](report-week2-symbol-analysis.md) · [Week 3 eBPF Validation](report-week3-ebpf-validation.md)*
