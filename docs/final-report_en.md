# ckb-probe Final Report

> **Scope: CKB testnet only**
>
> Project period: 2026-03-23 ~ 2026-05-07 (8 weeks)
> Author: Clair
> Budget: 1,000 USD

---

## 1. Project Overview

ckb-probe is an eBPF-based deep observability tool for CKB full nodes. Using kernel-level probes (uprobe/kprobe/tracepoint), it captures CKB testnet node behavior across the RocksDB storage layer, network layer, and system calls in a zero-intrusion manner, providing latency distribution, anomaly detection, and slow-operation alerting for operations insight.

**Core features:**
- Zero code modification: attaches to running CKB nodes without recompilation
- Low overhead: CPU delta <1.3%, RSS stable at 22.89 MB
- Zero event loss: 0 lost out of 20,034,457 events in 48-hour test
- Auto-reconnect: probes resume within 1 second after CKB restart

**Tech stack:** Rust + Aya (eBPF framework) + libbpf + RocksDB C API uprobe

---

## 2. Deliverables Checklist

| # | Deliverable | Description | Status |
|---|-------------|-------------|--------|
| D-1 | **ckb-probe CLI v0.1.0** | 3 subcommands: check / symbols / rocksdb | ✅ Complete |
| D-2 | **ckb-probe-ebpf BPF programs** | 8 uprobe pairs + 2 kprobe pairs + 1 tracepoint = 21 BPF programs | ✅ Complete |
| D-3 | **Docker environment** | Two-stage Dockerfile, 6 demo scripts, perf/stability/case study scripts | ✅ Complete |
| D-4 | **48-hour stability test** | S-1\~S-4 all PASS | ✅ Complete |
| D-5 | **Performance tests** | P-1\~P-4 all PASS | ✅ Complete |
| D-6 | **Case studies** | IBD write pattern + compaction storm | ✅ Complete |
| D-7 | **Bilingual documentation** | 6 doc pairs (EN/ZH): architecture, demo, quickstart, getting-started, deep-dive, test-infra | ✅ Complete |
| D-8 | **CI/CD** | build + lint + script check + weekly CKB compatibility check | ✅ Complete |

### D-1 Subcommand Details

| Subcommand | Functionality |
|------------|---------------|
| `check` | 8-point environment check + eBPF probe validation + 3s live event collection |
| `symbols` | Three-tier ELF symbol classification (20 Tier 1 / 21 Tier 2 / 12 Tier 3) |
| `rocksdb` | 5 operations (GET/PUT/WRITE/ITER\_NEW/TXN\_COMMIT), 4 output modes (table/histogram/slow/JSON), EWMA anomaly detection, S-4 auto-reconnect |

---

## 3. Acceptance Criteria Results

### 3.1 Functional (F-1 ~ F-10)

| ID | Criterion | Result | Notes |
|----|-----------|--------|-------|
| F-1 | check reports kernel/BTF/BPF/permissions/CKB with hints | ✅ PASS | |
| F-2 | symbols generates Tier 1/2/3 report with RocksDB linkage detection | ✅ PASS | |
| F-3 | rocksdb outputs 1s interval table | ✅ PASS | |
| F-4 | 5 operations tracked | ✅ PASS | Deviation: ITER\_NEW/TXN\_COMMIT instead of DELETE/ITER\_SEEK (see §7) |
| F-5 | --slow --threshold captures above-threshold ops | ✅ PASS | |
| F-6 | --histogram shows log2 distribution | ✅ PASS | |
| F-7 | EWMA anomaly detection triggers | ✅ PASS | 300s warmup, verified in case-2 |
| F-8 | --json outputs valid JSON parseable by jq | ✅ PASS | |
| F-9 | SIGINT/SIGTERM graceful shutdown, BPF programs unloaded | ✅ PASS | |
| F-10 | CKB exit handled gracefully + auto-reconnect | ✅ PASS | S-4 verified |

### 3.2 Performance (P-1 ~ P-4)

| ID | Metric | Budget | Measured | Result |
|----|--------|--------|----------|--------|
| P-1 | CPU delta | ≤3% | +1.29% | ✅ PASS |
| P-2 | RSS memory | ≤50 MB | 22.89 MB | ✅ PASS |
| P-3 | Event loss rate | <0.1% | 0/20,034,457 = 0.0000% | ✅ PASS |
| P-4 | Sync degradation | <1% | -0.86% | ✅ PASS |

### 3.3 Stability (S-1 ~ S-4)

| ID | Metric | Budget | Measured | Result |
|----|--------|--------|----------|--------|
| S-1 | 48h no crash | 0 crash | 0 crash | ✅ PASS |
| S-2 | RSS growth | ≤5 MB | 0.00 MB | ✅ PASS |
| S-3 | BPF dmesg errors | 0 | 0 | ✅ PASS |
| S-4 | Reconnect after CKB restart | <5s | 1s | ✅ PASS |

---

## 4. Technical Highlights

### 4.1 Three-tier Symbol Classification

ELF symbols in the CKB binary are classified into three tiers to identify the most stable probe attachment points:

- **Tier 1** (RocksDB C API, `extern "C"`): stable across versions, ideal uprobe targets
- **Tier 2** (Rust cross-crate public functions): hash suffixes change per compilation, require fuzzy matching
- **Tier 3** (inlined / LTO-eliminated): unavailable in release builds

### 4.2 EWMA Anomaly Detection

Employs Exponentially Weighted Moving Average (EWMA) for real-time latency anomaly detection. After a 300-second warmup to establish a baseline, alerts trigger when a single operation's latency exceeds the EWMA mean + 3 standard deviations. Successfully captured anomalies in case-2 (compaction storm).

### 4.3 S-4 Auto-reconnect

When the CKB process exits, ckb-probe gracefully releases BPF resources and enters a watch mode. Upon detecting CKB restart, all probes are re-attached within 1 second with no manual intervention.

### 4.4 Zero Event Loss Architecture

Uses BPF ring buffer instead of perf buffer, combined with efficient userspace polling, achieving 0 loss over 48 hours / 20 million events.

### 4.5 21 BPF Programs Full Coverage

| Type | Count | Coverage |
|------|-------|----------|
| uprobe/uretprobe | 8 pairs (16) | RocksDB GET/PUT/WRITE/DELETE/ITER\_NEW/ITER\_SEEK/TXN\_BEGIN/TXN\_COMMIT |
| kprobe/kretprobe | 2 pairs (4) | tcp\_sendmsg / tcp\_recvmsg |
| tracepoint | 1 | sys\_enter (syscall distribution) |

---

## 5. Timeline

| Week | Dates | Work | Milestone |
|------|-------|------|-----------|
| Week 1 | 03-23 ~ 03-29 | CKB architecture research + Aya learning + dev environment | |
| Week 2 | 03-30 ~ 04-05 | Symbol reconnaissance -> `ckb-probe symbols` | Milestone 1 (partial) |
| Week 3 | 04-06 ~ 04-12 | eBPF feasibility validation -> `ckb-probe check` | Milestone 1 complete |
| Week 4 | 04-13 ~ 04-19 | RocksDB core probe + EWMA anomaly detection | Milestone 2 (early) |
| Week 5 | 04-20 ~ 04-26 | Performance optimization + Docker + S-4 + P-1\~P-4 tests | |
| Week 6 | 04-27 ~ 05-03 | 48h stability test + case studies | |
| Week 7 | 05-04 ~ 05-06 | JSON optimization + demo walkthrough documentation | |
| Week 8 | 05-07 | Documentation maintenance + v0.1.0 release + final report | Project end |

---

## 6. Code Statistics

| Module | Lines | Description |
|--------|-------|-------------|
| ckb-probe (userspace) | 3,115 | CLI main program, subcommands, output formatting |
| ckb-probe-common | 567 | Shared data structures between BPF and userspace |
| ckb-probe-ebpf | 458 | BPF kernel-space programs |
| xtask | 47 | Build helpers |
| **Total** | **~4,187 lines Rust** | |

---

## 7. Known Limitations & Future Plans

### 7.1 Known Limitations

| # | Limitation | Description |
|---|-----------|-------------|
| L-1 | P2P network subcommand missing | kprobe-based network monitoring is implemented in eBPF but no dedicated `ckb-probe net` subcommand yet |
| L-2 | Syscall subcommand missing | Tracepoint is implemented in eBPF but no dedicated `ckb-probe syscall` subcommand yet |
| L-3 | TUI dashboard not implemented | Originally planned with ratatui; CLI table output used instead |
| L-4 | Web5 DID/VC features not implemented | Planned as opt-in for future versions |
| L-5 | Prometheus exporter not implemented | Currently --json output can be integrated with external monitoring systems |
| L-6 | F-4 deviation | Tracks ITER\_NEW/TXN\_COMMIT instead of DELETE/ITER\_SEEK. Reason: CKB does not use rocksdb\_delete; ITER\_NEW and TXN\_COMMIT are more representative of CKB's actual access patterns |
| L-7 | Demo video replaced | Comprehensive demo-walkthrough document (EN/ZH) used instead of demo video |
| L-8 | CKB testnet only | By design |

### 7.2 Future Plans

- **v0.2.0**: `ckb-probe net` subcommand (P2P connection count, message size distribution)
- **v0.2.0**: `ckb-probe syscall` subcommand (syscall heatmap)
- **v0.3.0**: TUI dashboard (ratatui-based)
- **v0.3.0**: Prometheus metrics exporter
- **v0.4.0**: Web5 DID/VC opt-in features

---

## 8. Budget Usage

| Category | Amount | Description |
|----------|--------|-------------|
| Cloud server | $350 | VPS (Linux 5.15+, 4-core 8GB), dev + CKB testnet node, 8 weeks |
| Developer compensation | $450 | Core development, ~20-30h/week x 8 weeks |
| Documentation & community | $200 | Bilingual docs, architecture diagrams, 2 monthly sharing sessions, final report |
| **Total** | **$1,000** | |

---

## 9. Appendix: Document Index

| Document | Chinese | English |
|----------|---------|---------|
| Code Architecture | [中文](https://github.com/clairjoestar/ckb-probe/blob/v0.1.0/docs/code-architecture_zh.md) | [EN](https://github.com/clairjoestar/ckb-probe/blob/v0.1.0/docs/code-architecture.md) |
| Getting Started | [中文](https://github.com/clairjoestar/ckb-probe/blob/v0.1.0/docs/getting-started_zh.md) | [EN](https://github.com/clairjoestar/ckb-probe/blob/v0.1.0/docs/getting-started_en.md) |
| Docker Quickstart | [中文](https://github.com/clairjoestar/ckb-probe/blob/v0.1.0/docs/docker-quickstart_zh.md) | [EN](https://github.com/clairjoestar/ckb-probe/blob/v0.1.0/docs/docker-quickstart.md) |
| Technical Deep Dive | [中文](https://github.com/clairjoestar/ckb-probe/blob/v0.1.0/docs/technical-deep-dive_zh.md) | [EN](https://github.com/clairjoestar/ckb-probe/blob/v0.1.0/docs/technical-deep-dive_en.md) |
| Test Infrastructure | [中文](https://github.com/clairjoestar/ckb-probe/blob/v0.1.0/docs/test-infrastructure_zh.md) | [EN](https://github.com/clairjoestar/ckb-probe/blob/v0.1.0/docs/test-infrastructure_en.md) |
| Demo Walkthrough | [中文](https://github.com/clairjoestar/ckb-probe/blob/v0.1.0/docs/demo-walkthrough_zh.md) | [EN](https://github.com/clairjoestar/ckb-probe/blob/v0.1.0/docs/demo-walkthrough_en.md) |
| Final Report | [中文](https://github.com/clairjoestar/ckb-probe/blob/v0.1.0/docs/final-report_zh.md) | [EN](https://github.com/clairjoestar/ckb-probe/blob/v0.1.0/docs/final-report_en.md) |

---

*ckb-probe v0.1.0 -- eBPF-based deep observability for CKB testnet full nodes*
