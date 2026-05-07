# ckb-probe v0.1.0

**Release Date:** 2026-05-07
**License:** MIT OR Apache-2.0
**Author:** Clair
**Repository:** https://github.com/clairjoestar/ckb-probe

---

## What is ckb-probe?

ckb-probe is an eBPF-based deep observability tool for CKB (Nervos Network) testnet full nodes. It uses uprobe/kprobe/tracepoint to deliver application-semantic, real-time performance insights **without modifying CKB source code**.

Built on a pure Rust eBPF stack via the [Aya](https://aya-rs.dev/) framework.

---

## Features

### `ckb-probe check` — Environment Verification

- 8-point environment verification
- eBPF probe validation
- 3-second live event collection

### `ckb-probe symbols` — ELF Symbol Classification

Three-tier ELF symbol classification:

| Tier | Count | Description |
|------|-------|-------------|
| Tier 1 | 20 | RocksDB C API functions |
| Tier 2 | 21 | Rust functions |
| Tier 3 | 12 | Inlined functions |

### `ckb-probe rocksdb` — Real-Time RocksDB Monitoring

- **5 operations:** GET, PUT, WRITE, ITER_NEW, TXN_COMMIT
- **4 output modes:** table, histogram, slow operations, JSON
- **Metrics:** QPS, Avg/P50/P99 latency, Bytes/s throughput
- **EWMA anomaly detection:** 5-min warmup, baseline freeze on spike
- **Bytes/s throughput tracking:** GET via PinnableSlice, PUT via vlen register, TXN_COMMIT via accumulator
- **Auto-reconnect on CKB process restart** (S-4)

### Docker Environment

- Two-stage build
- 6 demo scripts
- Performance, stability, and case study scripts

### CI/CD

- Build, lint, script check
- Weekly CKB version compatibility check

---

## Performance Results

| Metric | Result | Budget | Status |
|--------|--------|--------|--------|
| P-1 CPU Overhead | +1.29% | ≤ 3% | PASS |
| P-2 RSS Memory | 22.89 MB | ≤ 50 MB | PASS |
| P-3 Event Loss | 0.0000% (0/20M) | < 0.1% | PASS |
| P-4 Sync Degradation | -0.86% | < 1% | PASS |

## Stability (48h Continuous Test)

| Metric | Result | Status |
|--------|--------|--------|
| S-1 No Crash | 48h zero panic | PASS |
| S-2 No Leak | RSS +0.00 MB | PASS |
| S-3 No BPF Errors | Clean dmesg | PASS |
| S-4 Restart Recovery | 1s reconnect | PASS |

---

## Quick Start

```bash
# Build
docker build -f docker/Dockerfile -t ckb-probe:latest .

# Run (monitor host CKB testnet node)
docker run --rm --privileged --pid host --network host \
  -v /sys/kernel/debug:/sys/kernel/debug:ro \
  -v /sys/kernel/btf:/sys/kernel/btf:ro \
  -v /root/ckb-testnet/ckb:/root/ckb-testnet/ckb:ro \
  -v /tmp/perf-run:/tmp/perf-run \
  -e CKB_BIN=/root/ckb-testnet/ckb \
  -e CKB_RPC=http://127.0.0.1:8124 \
  ckb-probe:latest demo-check
```

## Requirements

- Linux kernel >= 5.8 with BTF support
- root or CAP_BPF + CAP_SYS_ADMIN
- Docker >= 20.10

---

## Documentation

All documentation is available in both English and Chinese:

- [Getting Started](getting-started_en.md) / [从零开始](getting-started_zh.md)
- [Docker Quickstart](docker-quickstart.md) / [Docker 快速入门](docker-quickstart_zh.md)
- [Technical Deep Dive](technical-deep-dive_en.md) / [技术详解](technical-deep-dive_zh.md)
- [Code Architecture](code-architecture.md) / [代码架构](code-architecture_zh.md)
- [Demo Walkthrough](demo-walkthrough_en.md) / [演示流程](demo-walkthrough_zh.md)
- [Test Infrastructure](test-infrastructure_en.md) / [测试基础设施](test-infrastructure_zh.md)

---

## Codebase

- ~4,187 lines of Rust code
- 4 crates: `ckb-probe`, `ckb-probe-common`, `ckb-probe-ebpf`, `xtask`
- Pure Rust eBPF stack via Aya framework

---

## Known Limitations

- P2P network monitoring (`ckb-probe net`) -- eBPF probes exist but no dedicated CLI subcommand yet
- Syscall analysis (`ckb-probe syscall`) -- eBPF probes exist but no dedicated CLI subcommand yet
- TUI dashboard -- planned for future version
- CKB testnet only (by design)

---

## Full Changelog

https://github.com/clairjoestar/ckb-probe/commits/v0.1.0
