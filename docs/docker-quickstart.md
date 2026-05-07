# ckb-probe Docker Quickstart

eBPF-based deep observability for CKB testnet nodes.

## Build

```bash
docker build -f docker/Dockerfile -t ckb-probe:latest .
```

Image includes ckb-probe, db_bench, and all scripts. CKB binary is NOT included — mount it from the host via `-v`. CKB data is also bind-mounted from host.

## Quick Start (monitor host CKB)

```bash
docker run --rm --privileged --pid host --network host \
  -v /sys/kernel/debug:/sys/kernel/debug:ro \
  -v /sys/kernel/btf:/sys/kernel/btf:ro \
  -v /root/ckb-testnet/ckb:/root/ckb-testnet/ckb:ro \
  -v /tmp/perf-run:/tmp/perf-run \
  -e CKB_BIN=/root/ckb-testnet/ckb \
  -e CKB_RPC=http://127.0.0.1:8124 \
  ckb-probe:latest demo-check
```

**Important:** The CKB binary mount path must match the host process exe path exactly, otherwise uprobe cannot attach.

## Commands

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
| `perf` | Full P-1~P-4 evaluation (CKB must be behind tip) | ~4h |
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

## Export

```bash
docker save ckb-probe:latest | gzip > ckb-probe-latest.tar.gz
```

Testnet only. Never use with mainnet.
