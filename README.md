# ckb-probe

Deep observability tool for CKB full nodes, powered by eBPF.

[中文文档](README_zh.md)

## Introduction

ckb-probe leverages eBPF (uprobe / kprobe / tracepoint) to deliver application-semantic, real-time performance insights for CKB full nodes — without modifying CKB source code. It outputs "RocksDB GET took 23μs, read 512 bytes" instead of "pwrite64 syscall".

## Features

- **Five RocksDB operations tracked**: GET, PUT, WRITE, ITER_NEW, TXN_COMMIT via uprobe/uretprobe
- **Real-time metrics**: QPS, Avg/P50/P99 latency, Bytes/s per operation
- **Four display modes**: Default table / Histogram / Slow operations / JSON
- **EWMA anomaly detection**: Baseline learning + 5× spike alert + absolute P99 caps
- **Process restart recovery**: Auto-detects CKB exit and reattaches to new PID (S-4)
- **Low overhead**: +1.29% CPU, 22.9 MB RSS, zero BPF event loss at 13K events/sec
- **Three-tier symbol analysis**: Classifies CKB binary symbols for uprobe feasibility
- **eBPF probe validation**: Verifies uprobe/kprobe/tracepoint + live event collection
- **Docker reproducible environment**: Single container with all tools and scripts

## Subcommands

| Command | Description |
|---------|-------------|
| `check` | Environment verification + eBPF probe validation + live event collection |
| `symbols` | ELF symbol analysis with three-tier classification |
| `rocksdb` | Real-time RocksDB monitoring (table / histogram / slow ops / JSON) |

## Quick Start

### Prerequisites

- Linux kernel ≥ 5.8 with BTF support (`/sys/kernel/btf/vmlinux`)
- Root or CAP_BPF + CAP_SYS_ADMIN
- Docker ≥ 20.10
- CKB testnet node with data directory
- **Testnet only. Never use with mainnet.**

### 1. Clone and build Docker image

```bash
git clone https://github.com/<org>/ckb-probe.git
cd ckb-probe
docker build -f docker/Dockerfile -t ckb-probe:latest .
```

Build takes ~10-15 min. The two-stage image (~100 MB) bundles ckb-probe, db_bench, and all scripts. CKB binary is **not** included — it must be mounted from the host (see step 3) so uprobe attachment paths align with the target process exe.

### 2. Prepare CKB node

Place your CKB testnet node data on the host:

```
/root/ckb-testnet/
├── ckb              # CKB binary
├── ckb.toml         # Config
└── data/            # Chain data (contains db/ subdirectory)
```

Start CKB:

```bash
cd /root/ckb-testnet && ./ckb run &
```

### 3. Docker run template

All scripts run via this template:

```bash
DOCKER_RUN="docker run --rm --privileged --pid host --network host \
  -v /sys/kernel/debug:/sys/kernel/debug:ro \
  -v /sys/kernel/btf:/sys/kernel/btf:ro \
  -v /root/ckb-testnet/ckb:/root/ckb-testnet/ckb:ro \
  -v /tmp/perf-run:/tmp/perf-run \
  -e CKB_BIN=/root/ckb-testnet/ckb \
  -e CKB_RPC=http://127.0.0.1:8124 \
  ckb-probe:latest"
```

> **Important:** The `-v` mount path for CKB binary must match the host process exe path exactly. Verify with `readlink /proc/$(pgrep -x ckb)/exe`. If paths don't match, uprobe cannot attach and no data will be collected.

### 4. Run demo scripts

```bash
$DOCKER_RUN demo-check             # Environment + symbol check       (< 30s)
$DOCKER_RUN demo-table 60          # Default stats table              (60s)
$DOCKER_RUN demo-histogram 60      # Latency distribution histogram   (60s)
$DOCKER_RUN demo-slow 60 1000      # Slow operations (threshold 1ms)  (60s)
$DOCKER_RUN demo-normal 60         # JSON monitoring output            (60s)
$DOCKER_RUN demo-stress 100000     # db_bench stress + anomaly detect  (2-3 min)
```

### 5. Run performance test (P-1 ~ P-4)

CKB must be **behind network tip** (IBD state) for meaningful results. Use node data that has been offline for hours/days, or stop CKB for a few hours before testing.

```bash
# Full 4h test (Phase A with-probe + Phase B baseline)
docker run -d --name perf-test \
  --privileged --pid host --network host \
  -v /sys/kernel/debug:/sys/kernel/debug:ro \
  -v /sys/kernel/btf:/sys/kernel/btf:ro \
  -v /root/ckb-testnet/ckb:/root/ckb-testnet/ckb:ro \
  -v /tmp/perf-run:/tmp/perf-run \
  -e CKB_BIN=/root/ckb-testnet/ckb \
  -e CKB_RPC=http://127.0.0.1:8124 \
  ckb-probe:latest perf

# Monitor progress
tail -5 /tmp/perf-run/progress.log

# View report
cat /tmp/perf-run/REPORT.txt
```

For strict P-4 comparison (both phases in IBD), run Phase A and Phase B separately with fresh data each time:

```bash
# Phase A only (with-probe): stop CKB, unzip fresh data, then:
./docker/scripts/perf/perf-phase-a.sh /root/ckb-testnet

# Phase B only (baseline): stop CKB, unzip fresh data again, then:
./docker/scripts/perf/perf-phase-b.sh /root/ckb-testnet
```

### 6. Run case studies

```bash
# IBD write pattern analysis (CKB must be in IBD state)
$DOCKER_RUN case-1 3600

# Compaction storm capture (applies aggressive tuning, auto-restores config)
$DOCKER_RUN case-2 1800
```

### 7. Run 48h stability test (S-1 ~ S-4)

```bash
docker run -d --name stability-test \
  --privileged --pid host --network host \
  -v /sys/kernel/debug:/sys/kernel/debug:ro \
  -v /sys/kernel/btf:/sys/kernel/btf:ro \
  -v /root/ckb-testnet/ckb:/root/ckb-testnet/ckb:ro \
  -v /tmp/perf-run:/tmp/perf-run \
  -e CKB_BIN=/root/ckb-testnet/ckb \
  -e CKB_RPC=http://127.0.0.1:8124 \
  ckb-probe:latest stability

# Shorten for quick validation
docker run -d --name stability-test \
  ... \
  -e DURATION_HOURS=2 \
  ckb-probe:latest stability
```

Tests: S-1 (no crash for 48h), S-2 (RSS growth ≤ 5 MB), S-3 (no BPF dmesg errors), S-4 (auto-reconnect after CKB restart at T+24h).

### 8. Interactive shell

```bash
docker run --rm -it --privileged --pid host --network host \
  -v /sys/kernel/debug:/sys/kernel/debug:ro \
  -v /sys/kernel/btf:/sys/kernel/btf:ro \
  -v /root/ckb-testnet/ckb:/root/ckb-testnet/ckb:ro \
  --entrypoint "" \
  ckb-probe:latest bash
```

## Performance Test Results (P-1 ~ P-4)

Tested on CKB testnet with real IBD workload (Docker, 24-core Linux 6.8, CKB v0.204.0):

| Metric | Result | Budget | Status |
|--------|--------|--------|--------|
| P-1 CPU overhead | +1.29% (relative) | ≤ 3% | ✅ PASS |
| P-2 RSS memory | 22.89 MB (stable, no growth) | ≤ 50 MB | ✅ PASS |
| P-3 BPF event loss | 0 / 20M events (0.0000%), peak 13K/s | < 0.1% | ✅ PASS |
| P-4 Sync degradation | -0.86% (no degradation) | < 1% | ✅ PASS |

## All Docker Commands

| Command | Description | Duration |
|---------|-------------|----------|
| **Demo** | | |
| `demo-check` | Environment + symbol check + eBPF validation | < 30s |
| `demo-table [secs]` | Default stats table | 60s |
| `demo-histogram [secs]` | Latency distribution histogram | 60s |
| `demo-slow [secs] [μs]` | Slow operations capture | 60s |
| `demo-normal [secs]` | JSON monitoring output | 5 min |
| `demo-stress [num]` | db_bench stress + anomaly detection | 2-3 min |
| **Performance** | | |
| `perf` | Full P-1~P-4 evaluation | ~4h |
| `p3-stress [secs]` | Standalone P-3 event loss test | 5 min |
| **Stability** | | |
| `stability` | 48h S-1~S-4 stability test | 48h |
| `stability-report [dir]` | Generate stability report | instant |
| **Case Study** | | |
| `case-1 [secs]` | IBD write pattern analysis | ~2h |
| `case-2 [secs]` | Compaction storm capture | ~30 min |
| **Utility** | | |
| `bash` | Interactive shell | - |
| `start-ckb` | Start CKB inside container | - |
| `help` | Show usage | - |

## RocksDB Operations Tracked

| Op | RocksDB Function | Bytes/s Source |
|----|-----------------|----------------|
| GET | `rocksdb_get_pinned_cf` | uretprobe reads PinnableSlice size |
| PUT | `rocksdb_transaction_put_cf` | entry probe reads vlen from arg(5) |
| WRITE | `rocksdb_write` | — (WriteBatch internal) |
| ITER_NEW | `rocksdb_create_iterator_cf` | — (no payload) |
| TXN_COMMIT | `rocksdb_transaction_commit` | per-TID PUT accumulator |

## Project Structure

```
ckb-probe/
├── ckb-probe/                  # Userspace CLI (Rust + tokio)
│   └── src/commands/
│       ├── check.rs            # Environment check + eBPF validation
│       ├── symbols.rs          # ELF symbol analysis
│       └── rocksdb.rs          # RocksDB monitoring + anomaly detection + S-4
├── ckb-probe-ebpf/             # eBPF kernel programs (#![no_std])
│   └── src/main.rs             # uprobe/kprobe/tracepoint BPF programs
├── ckb-probe-common/           # Shared type definitions
├── docker/                     # Docker + all scripts
│   ├── Dockerfile              # Two-stage build (rust builder + ubuntu runtime)
│   ├── entrypoint.sh           # Command dispatcher
│   ├── env-check.sh            # Host prerequisite checker
│   └── scripts/
│       ├── perf/               # P-1~P-4 performance test scripts
│       ├── stability/          # S-1~S-4 stability test + report generator
│       ├── demo/               # 6 demo scripts
│       └── case/               # 2 case study scripts
├── docs/                       # Documentation (EN + 中文)
└── .github/workflows/ci.yml    # CI: build + lint + script check
```

## Documentation

| Document | EN | 中文 |
|----------|-----|------|
| Getting Started | [EN](docs/getting-started_en.md) | [中文](docs/getting-started_zh.md) |
| Docker Quickstart | [EN](docs/docker-quickstart.md) | [中文](docs/docker-quickstart_zh.md) |
| Technical Deep Dive | [EN](docs/technical-deep-dive_en.md) | [中文](docs/technical-deep-dive_zh.md) |
| Code Architecture | [EN](docs/code-architecture.md) | [中文](docs/code-architecture_zh.md) |
| Demo Walkthrough | [EN](docs/demo-walkthrough_en.md) | [中文](docs/demo-walkthrough_zh.md) |
| Test Infrastructure | [EN](docs/test-infrastructure_en.md) | [中文](docs/test-infrastructure_zh.md) |
| Stability Report | [EN](docs/STABILITY-REPORT.md) | [中文](docs/STABILITY-REPORT_zh.md) |
| Case Study Report | — | [中文](docs/CASE-STUDY-REPORT_zh.md) |
| Final Report | [EN](docs/final-report_en.md) | [中文](docs/final-report_zh.md) |
| Monthly Report (Final) | [EN](docs/monthly-report-final_en.md) | [中文](docs/monthly-report-final_zh.md) |
| Release Notes v0.1.0 | [EN](docs/RELEASE-v0.1.0.md) | — |

## Verification Checklist

### Functional (F-1 ~ F-10)

| # | Requirement | Status |
|---|-------------|--------|
| F-1 | `check` reports kernel/BTF/BPF with actionable hints | ✅ |
| F-2 | `symbols` generates Tier 1/2/3 report + RocksDB linkage detection | ✅ |
| F-3 | `rocksdb --pid` outputs real-time stats table at 1s intervals | ✅ |
| F-4 | Five operations (GET/PUT/WRITE/ITER_NEW/TXN_COMMIT) tracked with QPS/avg/P50/P99/bytes | ✅ |
| F-5 | `--slow --threshold` captures individual slow operations | ✅ |
| F-6 | `--histogram` displays log2-bucket latency distribution | ✅ |
| F-7 | EWMA anomaly detection triggers within 15s of synthetic spike | ✅ |
| F-8 | `--json` outputs valid JSON parseable by jq | ✅ |
| F-9 | Graceful shutdown on SIGINT/SIGTERM, clean BPF unload | ✅ |
| F-10 | Graceful handling when CKB exits + auto-reconnect on restart | ✅ |

### Performance (P-1 ~ P-4)

| # | Requirement | Result | Status |
|---|-------------|--------|--------|
| P-1 | CPU overhead ≤ 3% (relative) | +1.29% | ✅ |
| P-2 | RSS ≤ 50 MB | 22.89 MB | ✅ |
| P-3 | BPF event loss < 0.1% at 10K+/s | 0.0000% at 13K/s | ✅ |
| P-4 | Sync degradation < 1% | -0.86% | ✅ |

### Stability (S-1 ~ S-4)

| # | Requirement | Status |
|---|-------------|--------|
| S-1 | 48h no crash/panic | Scripts ready |
| S-2 | RSS growth ≤ 5 MB over 48h | Scripts ready |
| S-3 | No BPF dmesg warnings | Scripts ready |
| S-4 | Auto-reconnect on CKB restart | ✅ Verified |

## Image Export

```bash
docker save ckb-probe:latest | gzip > ckb-probe-latest.tar.gz
docker load < ckb-probe-latest.tar.gz   # on another machine
```

## License

MIT OR Apache-2.0
