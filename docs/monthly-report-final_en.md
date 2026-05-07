# ckb-probe Final Report (Week 5-8)

> Author: Clair
> Period: 2026-04-13 ~ 2026-05-07
> Project: ckb-probe -- eBPF-based deep observability tool for CKB full nodes
> Repository: https://github.com/clairjoestar/ckb-probe
> License: MIT OR Apache-2.0
> Scope: CKB testnet only

---

## 1. Project Overview

ckb-probe uses eBPF (uprobe / kprobe / tracepoint) to deliver application-semantic, real-time performance insights for CKB full nodes -- without modifying CKB source code or restarting the node.

This is the second and final monthly community sharing report, covering Week 5-8. The first monthly report (midterm) covered Week 2-4.

---

## 2. Milestone Status

| Milestone | Planned | Actual | Status |
|-----------|---------|--------|--------|
| M1: eBPF feasibility validation | Week 3 | Week 3 | ✅ On schedule |
| M2: `rocksdb` subcommand + EWMA | Week 5 | Week 4 | ✅ 1 week early |
| M3: Full release with all deliverables | Week 8 | Week 8 | ✅ On schedule |

**All three milestones achieved.**

---

## 3. Week 5-8 Progress

### Week 5 (Apr 13-19): Performance Optimization + Docker

| Deliverable | Details |
|-------------|---------|
| Memory optimization | RSS 87.9 MB → 21.9 MB (RingBuf replacing PerfEventArray) |
| Docker environment | Two-stage Dockerfile + 6 demo scripts + env-check.sh |
| S-4 process restart recovery | Auto-detect CKB exit + poll new PID + reattach |
| P-1~P-4 performance tests | ALL PASS |
| CI pipeline | build + lint + script check + weekly CKB compat |

### Week 6 (Apr 20-26): 48h Stability Test + Case Studies

| Deliverable | Details |
|-------------|---------|
| S-1~S-4 stability tests | ALL PASS (48h continuous, RSS +0.00 MB, 1s reconnect) |
| Case 1: IBD write pattern | 22 min, 109.7 GET QPS, 6 ITER_NEW anomalies |
| Case 2: Compaction storm | GET latency 35x spike, 6,112 slow ops, 0 loss |

### Week 7 (Apr 27 - May 3): JSON Optimization + Demo Documentation

| Deliverable | Details |
|-------------|---------|
| JSON --histogram fusion | `--json --histogram` combined output includes log2 latency distribution |
| Demo walkthrough doc | 5-step demo flow + real terminal output + Docker guide |
| Clippy fixes | `manual_checked_ops` warning resolved |

### Week 8 (May 4-7): Documentation + Release

| Deliverable | Details |
|-------------|---------|
| Bilingual docs | All 6 doc pairs updated to match latest code |
| Demo walkthrough EN | English version of demo-walkthrough |
| v0.1.0 release prep | tag + release notes |
| Final report | All deliverables organized |

---

## 4. Performance Test Results

Dual fresh-IBD comparison test (Docker container, CKB testnet):

| Metric | Result | Budget | Status |
|--------|--------|--------|--------|
| P-1 CPU overhead | +1.29% (2h aggregate) | ≤ 3% | ✅ PASS |
| P-2 RSS | 22.89 MB (stable, no growth) | ≤ 50 MB | ✅ PASS |
| P-3 Event loss | 0 / 20,034,457 = 0.0000% | < 0.1% | ✅ PASS |
| P-4 Sync degradation | -0.86% (2h aggregate) | < 1% | ✅ PASS |

**All four performance metrics PASS.**

---

## 5. Stability Test Results

48-hour continuous run (CKB testnet, 16,693 time-series samples):

| Metric | Result | Details |
|--------|--------|---------|
| S-1 No crash | **PASS** | 48h zero panic/SIGSEGV |
| S-2 Memory stable | **PASS** | RSS growth 0.00 MB (budget 5 MB) |
| S-3 No BPF errors | **PASS** | 48h zero BPF subsystem errors |
| S-4 Restart recovery | **PASS** | 1-second reconnect after CKB restart |

### Resource Usage

| Metric | Min | Max | Mean | P99 |
|--------|-----|-----|------|-----|
| Probe CPU% | 0.00 | 0.38 | 0.09 | 0.29 |
| Probe RSS | 21.4 MB | 21.4 MB | 21.4 MB | 21.4 MB |

---

## 6. Case Studies

### Case 1: IBD Write Pattern Analysis

| Item | Value |
|------|-------|
| Duration | 22 minutes |
| Blocks synced | 197 |
| GET avg QPS | 109.7 |
| Anomaly events | 6 (ITER_NEW P99 trigger, compaction contention) |

ckb-probe captured the complete IBD catch-up-to-steady-state transition. GET was the dominant operation; write load was light.

### Case 2: Compaction Storm Capture

| Item | Value |
|------|-------|
| Duration | 30 minutes |
| GET latency spike | Normal ~200us → avg 6,988us (**35x**) |
| Total slow ops | 6,112 (threshold >1,000us) |
| BPF event loss | 0 / 6,112 = 0.0000% |

Compaction storm injected via aggressive RocksDB parameters. ckb-probe captured all slow operations with zero loss.

---

## 7. Technical Highlights

### 7.1 Memory Optimization: 87.9 MB → 21.9 MB

| Optimization | Before | After |
|-------------|--------|-------|
| SLOW_EVENTS channel | PerfEventArray (24 per-CPU ring buffers) | RingBuf (shared 256KB) |
| Perf buffer size | 1024 pages/CPU (4MB) | 16 pages/CPU (64KB) |
| HashMap max_entries | 10240 | 1024 |

### 7.2 Process Restart Recovery (S-4)

```
Monitoring PID 3310428 → CKB stopped
⚠ Target process (PID 3310428) exited. Waiting for CKB to restart...
✅ CKB restarted (new PID 673651). Reattaching probes...
```

Background thread checks `/proc/{pid}` every second. On CKB exit, scans for the same binary in a new process, reloads BPF programs, and reattaches all uprobes.

### 7.3 Docker Reproducible Environment

- Two-stage Dockerfile: build stage + runtime stage
- 6 demo scripts: demo-check / demo-table / demo-histogram / demo-slow / demo-normal / demo-stress
- env-check.sh: 6-point host prerequisite check
- Single command to run any demo

### 7.4 JSON --histogram Fusion Output

```json
{
  "operations": {
    "GET": {
      "qps": 845,
      "avg_us": 24.97,
      "p50_us": 24.58,
      "p99_us": 98.30,
      "bytes_per_sec": 101976,
      "histogram": [
        { "ge_us": 4.1, "count": 1528 },
        { "ge_us": 16.38, "count": 727 }
      ]
    }
  }
}
```

---

## 8. Code Statistics

| Metric | Value |
|--------|-------|
| Rust code | ~4,187 lines |
| Commits | 31 |
| Subcommands | 3 (check / symbols / rocksdb) |
| BPF programs | uprobe / uretprobe / kprobe / tracepoint |
| Output modes | 4 (table / histogram / slow / JSON) |
| Documentation | 6 bilingual doc pairs |
| License | MIT OR Apache-2.0 |

---

## 9. Deliverables Checklist

| Category | Deliverable |
|----------|-------------|
| Core tool | `ckb-probe` CLI (check / symbols / rocksdb) |
| eBPF programs | uprobe + uretprobe + kprobe + tracepoint |
| Anomaly detection | EWMA baseline + 3-way trigger + 4 safety properties |
| Docker | Dockerfile + 6 demo scripts + env-check.sh |
| Performance validation | P-1~P-4 ALL PASS |
| Stability validation | S-1~S-4 ALL PASS (48h) |
| Case studies | IBD write pattern + compaction storm capture |
| CI | build + lint + script check + CKB compat check |
| Documentation | 6 bilingual doc pairs + demo walkthrough |

---

## 10. What's Next

ckb-probe v0.1.0 covers comprehensive RocksDB-layer observability. Future versions plan to expand into additional dimensions:

| Direction | Description |
|-----------|-------------|
| P2P network subcommand | kprobe-based CKB P2P message latency and throughput tracing |
| Syscall subcommand | tracepoint-based syscall distribution and latency collection |
| TUI dashboard | Interactive terminal UI built on ratatui |
| Prometheus exporter | Standard metrics endpoint for Grafana integration |

---

## Acknowledgments

Thanks to the CKB community and the Nervos grant program for their support. ckb-probe aims to provide production-grade deep observability for CKB testnet node operators, helping them quickly identify performance bottlenecks and anomalous patterns.

Try it out and share your feedback: https://github.com/clairjoestar/ckb-probe

---

*Related documents: [Stability Report](https://github.com/clairjoestar/ckb-probe/blob/v0.1.0/docs/STABILITY-REPORT.md) · [Case Study Report](https://github.com/clairjoestar/ckb-probe/blob/v0.1.0/docs/CASE-STUDY-REPORT_zh.md) · [Demo Walkthrough](https://github.com/clairjoestar/ckb-probe/blob/v0.1.0/docs/demo-walkthrough_en.md) · [Final Report](https://github.com/clairjoestar/ckb-probe/blob/v0.1.0/docs/final-report_en.md)*
