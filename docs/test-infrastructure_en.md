# ckb-probe Test Infrastructure Guide

> **Scope: CKB testnet only, never mainnet.**

---

## 1. Overview

ckb-probe testing is divided into two major categories:

| Category | Metrics | Duration | Purpose |
|----------|---------|----------|---------|
| **Performance Tests (P-1 ~ P-4)** | CPU / Memory / Event Loss / Sync Degradation | ~4.5h | Quantify the runtime overhead of probe on CKB |
| **Stability Tests (S-1 ~ S-4)** | No Crash / No Leak / No Kernel Warning / Restart Recovery | 48h | Verify reliability over long-running periods |

### Architecture

```
┌─────────────────────────────────────────────────────┐
│                    Host / Docker                     │
│                                                     │
│  ┌──────────┐    uprobe/uretprobe    ┌───────────┐  │
│  │   CKB    │◄──────────────────────│ ckb-probe │  │
│  │ (testnet)│    kprobe/tracepoint   │  (eBPF)   │  │
│  └──────────┘                        └───────────┘  │
│       │                                    │        │
│       ▼                                    ▼        │
│  data/db (RocksDB)                  /tmp/perf-run   │
│                                    REPORT.txt       │
└─────────────────────────────────────────────────────┘
```

---

## 2. Prerequisites

| Requirement | Minimum Version | How to Check |
|-------------|-----------------|--------------|
| Linux Kernel | ≥ 5.8 | `uname -r` |
| BTF Support | — | `/sys/kernel/btf/vmlinux` exists |
| Docker | ≥ 20.10 | `docker --version` |
| Available Memory | ≥ 4 GB | `free -g` |
| Available Disk | ≥ 20 GB | `df -h` |

One-command check:

```bash
./docker/env-check.sh
```

---

## 3. Performance Tests (P-1 ~ P-4)

### 3.1 Metric Definitions

| ID | Metric | Budget | Measurement Method |
|----|--------|--------|--------------------|
| P-1 | Additional CPU Usage | ≤ 3% | CKB %CPU delta over 1h window (with vs without probe) |
| P-2 | ckb-probe RSS | ≤ 50 MB | VmRSS during continuous monitoring |
| P-3 | BPF Event Loss Rate | < 0.1% | PerfEventArray loss counter |
| P-4 | Sync Speed Degradation | < 1% | blocks/min comparison over 2h IBD window |

### 3.2 How to Generate IBD Workload

A/B comparison near the tip is inaccurate -- block production is sparse, RocksDB operation density is low (~500/s), and P-4's blocks/min fluctuates significantly.

**Solution: Let the node fall behind the network tip.** Stop CKB for several hours (or use node data that is already behind), and when restarted the node needs to catch up to the network tip, producing real IBD workload.

```
Before stopping CKB:  Node tip = H = Network tip
After stopping N hours: Network tip = H + N×360 (testnet ~10s/block)
Start CKB:            Node IBD catches up from H → high-density RocksDB operations
```

The longer the stop, the greater the IBD workload. At least 2 hours (~720 blocks) is recommended. If you have node data that is several days behind (e.g., a backup from 15 days ago), that works even better and can be used directly.

### 3.3 Running Full P-1~P-4 Tests

**Prerequisite: CKB node is behind the network tip** (stopped for several hours, or using old data).

#### Running Directly on Host

```bash
# Make sure CKB is running and behind the tip
./docker/scripts/perf/perf-run-orchestrator.sh
```

#### Running Inside Docker Container

```bash
# Make sure host CKB is running and behind the tip
docker run -d --name perf-test \
  --privileged --pid host --network host \
  -v /sys/kernel/debug:/sys/kernel/debug:ro \
  -v /sys/kernel/btf:/sys/kernel/btf:ro \
  -v /root/ckb-testnet/ckb:/root/ckb-testnet/ckb:ro \
  -v /tmp/perf-run:/tmp/perf-run \
  -e CKB_BIN=/root/ckb-testnet/ckb \
  -e CKB_RPC=http://127.0.0.1:8124 \
  ckb-probe:latest perf

# Check progress
docker logs -f perf-test
cat /tmp/perf-run/progress.log

# View final report
cat /tmp/perf-run/REPORT.txt
```

#### Strict P-4 Comparison (Separate Phase A / Phase B)

Both phases must start from the same IBD state. Unzip fresh data (don't start CKB), the script starts CKB and attaches probe immediately:

```bash
# Phase A (with-probe): unzip fresh data, then:
./docker/scripts/perf/perf-phase-a.sh /root/ckb-testnet

# Phase B (baseline): re-unzip fresh data, then:
./docker/scripts/perf/perf-phase-b.sh /root/ckb-testnet
```

**Test Flow (total ~4 hours):**

```
Phase A: with-probe (2h)
  ├── Script starts CKB → immediately attaches probe
  ├── Collects P-1/P-2/P-3/P-4
  └── Stop

Phase B: baseline (2h) (after re-unzip)
  ├── Script starts CKB (no probe)
  ├── Collects P-1 baseline, P-4 baseline
  └── Stop
```

**Monitoring commands during testing:**

```bash
# Progress
tail -5 /tmp/perf-run/progress.log

# P-2 current RSS
tail -1 /tmp/perf-run/p2-rss.log | awk '{printf "RSS: %.1f MB\n", $2/1024}'

# P-3 event loss
grep -a "BPF event loss" /tmp/perf-run/probe-slow.log | tail -1

# P-4 sync sampling
tail -3 /tmp/perf-run/p4-with-probe.log
wc -l /tmp/perf-run/p4-with-probe.log  # Target: 121 lines
```

### 3.5 Reading the Report

Latest test results (2026-04-15, Docker container, real IBD workload):

| Metric | Result | Budget | Status |
|--------|--------|--------|--------|
| P-1 CPU Overhead | +1.29% (relative) | ≤ 3% | ✅ PASS |
| P-2 RSS Memory | 22.89 MB (stable, no growth) | ≤ 50 MB | ✅ PASS |
| P-3 Event Loss | 0 / 20,034,457 (0.0000%), peak 13K/s | < 0.1% | ✅ PASS |
| P-4 Sync Degradation | -0.86% (slightly faster) | < 1% | ✅ PASS |

```
P-1   CPU Overhead ≤ 3% (IBD peak, relative)
  baseline %CPU mean       : 318.45%
  with-probe %CPU mean     : 322.56%
  relative delta           : +1.29%
  status                   : ✅ PASS
```

- **relative delta** is `(with-probe - baseline) / baseline × 100%`
- On multi-core machines, %CPU can exceed 100% (pidstat reports the sum across all cores; 24 cores max 2400%)

> **Note:** P-2 previously failed due to oversized perf buffer allocation (1024 pages/CPU × 24 CPU = 96 MB).
> Fixed to 16 pages/CPU, RSS dropped from 87.9 MB to 22.9 MB and remains stable.

### 3.6 Individual Quick Tests

Don't want to run the full 4h? You can run individual tests:

```bash
# P-1: CPU overhead (1-minute quick verification)
./docker/scripts/perf/p1-cpu.sh baseline 60
./docker/scripts/perf/p1-cpu.sh with-probe 60
./docker/scripts/perf/p1-cpu.sh compare

# P-2: RSS memory (continuous monitoring, Ctrl+C to stop and output verdict)
./docker/scripts/perf/p2-rss.sh

# P-3: BPF event loss rate (5 minutes, requires db_bench)
./docker/scripts/perf/p3-stress.sh 300
./docker/scripts/perf/p3-stress.sh 300 --no-db-bench   # without db_bench

# P-4: Sync speed
./docker/scripts/perf/p4-sync.sh baseline 5   # 5-minute baseline
./docker/scripts/perf/p4-sync.sh with-probe 5  # 5-minute with-probe
./docker/scripts/perf/p4-sync.sh compare
```

---

## 4. Stability Tests (S-1 ~ S-4)

### 4.1 Metric Definitions

| ID | Metric | Pass Criteria | Measurement Method |
|----|--------|---------------|---------------------|
| S-1 | 48h No Crash | 0 crash/panic/restart | Process liveness check + stderr scan |
| S-2 | No Memory Leak | RSS growth ≤ 5 MB | avg(last 1h RSS) - avg(first 1h RSS) |
| S-3 | No Kernel BPF Warning | 0 new dmesg warnings | Periodic dmesg diff |
| S-4 | Process Restart Recovery | Reconnection time < 60s | Active CKB restart at T+24h |

### 4.2 Running

```bash
# Full 48-hour test
./docker/scripts/stability/stability-48h.sh

# Shortened test (e.g., 2 hours to verify script correctness)
DURATION_HOURS=2 ./docker/scripts/stability/stability-48h.sh

# Custom sampling interval
SAMPLE_SECS=10 ./docker/scripts/stability/stability-48h.sh
```

### 4.3 Data Collection

Sampling every 10 seconds, 48 hours produces **17,280 data points**:

| File | Content | Format |
|------|---------|--------|
| `timeseries.tsv` | Time series metrics | `ts probe_cpu% probe_rss_kb ckb_cpu% ckb_rss_kb` |
| `events.tsv` | Per-operation metrics | `ts op qps avg_us p50_us p99_us bps` |
| `probe-stderr.log` | ckb-probe error output | Text |
| `probe-json.log` | ckb-probe JSON output | JSON lines |
| `dmesg-start.log` | Starting dmesg | Text |
| `dmesg-end.log` | Ending dmesg | Text |
| `s4-restart.log` | S-4 restart test log | Text |

### 4.4 S-4 Automatic Restart Test

The script automatically executes at T+24h (test midpoint):

```
T+24:00:00  Stop CKB (SIGTERM)
T+24:00:10  Restart CKB (./ckb run)
T+24:00:12  ckb-probe detects new PID → auto-reconnect
T+24:00:12  Record reconnection time: 2s ✅
```

**Verified on a live CKB node (2026-04-13):**

```
  Monitoring 5 operations on PID 3310428 ...
  ⚠ Target process (PID 3310428) exited. Waiting for CKB to restart...
  ✅ CKB restarted (new PID 673651). Reattaching probes...
  Monitoring 5 operations on PID 673651 ...
```

S-4 implementation in ckb-probe (`rocksdb.rs`):
1. Background thread checks `/proc/{pid}` existence every second
2. Process exits → stop current monitoring loop, release BPF resources
3. Poll `/proc/*/exe` to find a new process with the same binary
4. New PID found → reload BPF, re-attach uprobe → resume monitoring
5. Header PID updates automatically, data resumes seamlessly

### 4.5 Generating Reports

```bash
# Auto-generated after test completion, or manually regenerate
./docker/scripts/stability/generate-report.sh /tmp/stability-<timestamp>/
```

**Report contents (per main_proj.md Section 6.5 specification):**

1. **S-1 ~ S-4 Verdict Table** -- Four-item PASS/FAIL overview
2. **Time Series Charts** -- CPU%, RSS, P99 Latency, Event Throughput (gnuplot PNG or ASCII)
3. **Resource Consumption Summary Table** -- Min / Max / Avg / P99 + threshold comparison
4. **Event Capture Fidelity** -- Total generated vs total captured, broken down by operation type
5. **Latency Distribution Histogram** -- log2 bucketed histogram + CDF for five operations
6. **Case Study 1: IBD Write Pattern** -- PUT/WRITE throughput evolution as chain grows
7. **Case Study 2: Compaction Latency Spikes** -- before/during/after latency + anomaly alerts
8. **Reproduction Instructions** -- Kernel version, CKB version, hardware config, reproduction commands

---

## 5. Docker Deployment

### 5.1 Prerequisite: Docker Proxy Configuration

If the host accesses the network through a proxy, the Docker daemon does **not inherit** proxy settings from environment variables by default and requires separate configuration:

```bash
# 1. Configure Docker daemon proxy (for pulling images)
mkdir -p /etc/systemd/system/docker.service.d
cat > /etc/systemd/system/docker.service.d/http-proxy.conf <<EOF
[Service]
Environment="HTTP_PROXY=http://your-proxy:port"
Environment="HTTPS_PROXY=http://your-proxy:port"
Environment="NO_PROXY=localhost,127.0.0.1"
EOF

# 2. Configure Docker client proxy (passed to container during build)
mkdir -p ~/.docker
cat > ~/.docker/config.json <<EOF
{
  "proxies": {
    "default": {
      "httpProxy": "http://your-proxy:port",
      "httpsProxy": "http://your-proxy:port",
      "noProxy": "localhost,127.0.0.1"
    }
  }
}
EOF

# 3. Restart Docker
systemctl daemon-reload && systemctl restart docker

# 4. Verify
docker info | grep -i proxy
```

### 5.2 Building the Image

The image is built in two stages:
1. **Stage 1** -- Compile ckb-probe (userspace + eBPF) + db_bench from `rust:latest`
2. **Stage 2** -- `ubuntu:24.04` minimal runtime, install binaries + scripts

```bash
# Build in project root (approximately 10-15 minutes, depending on network speed and compilation speed)
docker build -f docker/Dockerfile -t ckb-probe:latest .

# Verify image
docker images ckb-probe
```

**Key design: CKB binary and data are bind-mounted from host, not included in the image.** CKB testnet data is ~242 GB and the binary must match the host process exe path for uprobe to attach. The image only contains ckb-probe + db_bench + scripts.

### 5.3 Single Container Mode (Monitoring Host CKB)

When a CKB node is already running on the host, the container runs as a monitoring sidecar:

```bash
docker run --rm --privileged --pid host \
  -v /sys/kernel/debug:/sys/kernel/debug:ro \
  -v /sys/kernel/btf:/sys/kernel/btf:ro \
  -v /root/ckb:/root/ckb:ro \
  -v /root/data:/data:ro \
  -v /tmp/demo-output:/tmp/perf-run \
  -e CKB_BIN=/root/ckb \
  ckb-probe:latest <command>
```

**Key parameter descriptions:**

| Parameter | Purpose |
|-----------|---------|
| `--privileged --pid host` | eBPF requires privileged mode + shared host PID namespace |
| `-v /root/ckb:/root/ckb:ro` | Mount host CKB binary (path must match the process exe for uprobe to attach) |
| `-v /root/data:/data:ro` | Mount host CKB data directory |
| `-e CKB_BIN=/root/ckb` | Tell scripts inside the container to use the host-path CKB binary |

> **Why must the CKB binary be mounted with a matching path?**
> uprobe attaches to processes via the binary path. The CKB binary bundled inside the container is at `/usr/local/bin/ckb`, but the host process exe is `/root/ckb`. If the paths don't match, uprobe cannot hook and no data will be collected. Therefore, the host binary must be mounted into the container at its original path.

### 5.4 Demo Scripts

Six demo scripts:

| Script | Purpose | Duration |
|--------|---------|----------|
| `demo-check` | Environment check + eBPF validation + symbol analysis | < 30s |
| `demo-normal [seconds]` | Normal monitoring + JSON snapshot | Default 5min |
| `demo-table [seconds]` | Default table mode (QPS / Avg / P50 / P99 / Bytes/s) | Default 60s |
| `demo-histogram [seconds]` | Latency distribution histogram mode (log2 bucketing) | Default 60s |
| `demo-slow [seconds] [threshold-us]` | Slow operation capture mode | Default 60s |
| `demo-stress [entries]` | db_bench stress injection + anomaly detection | 2-3 min |

```bash
# Example usage (single container mode, monitoring host CKB)
DOCKER_RUN="docker run --rm --privileged --pid host \
  -v /sys/kernel/debug:/sys/kernel/debug:ro \
  -v /sys/kernel/btf:/sys/kernel/btf:ro \
  -v /root/ckb:/root/ckb:ro \
  -v /root/data:/data:ro \
  -v /tmp/demo-output:/tmp/perf-run \
  -e CKB_BIN=/root/ckb \
  ckb-probe:latest"

$DOCKER_RUN demo-check             # Environment + symbol check
$DOCKER_RUN demo-table 30          # 30-second table mode
$DOCKER_RUN demo-histogram 30      # 30-second histogram mode
$DOCKER_RUN demo-slow 30 500       # 30-second slow ops (threshold 500us)
$DOCKER_RUN demo-normal 60         # 1-minute JSON monitoring
$DOCKER_RUN demo-stress 100000     # db_bench 100K entries stress test
$DOCKER_RUN bash                   # Enter container interactive shell
```

**demo-stress** uses `db_bench` to inject RocksDB load (fillrandom 4KB x 100K entries, 4 concurrent threads), causing CKB's RocksDB latency to increase through disk I/O contention, triggering ckb-probe's slow operation capture and anomaly detection. db_bench is pre-compiled in the image.

### 5.5 Image Export and Distribution

```bash
# Export to file
docker save ckb-probe:latest | gzip > ckb-probe-latest.tar.gz

# Import on another machine
docker load < ckb-probe-latest.tar.gz
```

---

## 6. Case Studies

### 6.1 Case 1: IBD Write Pattern Analysis

Capture RocksDB write amplification patterns during Initial Block Download:

```bash
./docker/scripts/case/case-1-ibd-write-pattern.sh
```

- Start CKB from snapshot (fresh IBD)
- Monitor for 30 minutes, 10-second sampling
- Output PUT/WRITE throughput and latency time series
- Analyze write amplification trends as chain height grows

### 6.2 Case 2: Compaction Storm Capture

Capture latency spikes caused by RocksDB compaction:

```bash
./docker/scripts/case/case-2-compaction-storm.sh
```

- Use `ckb.toml.aggressive` configuration to lower compaction trigger thresholds
- Monitor until ANOMALY DETECTED event appears
- Output before / during / after latency comparison
- Demonstrate ckb-probe's anomaly detection capability

---

## 7. File Structure

```
ckb-probe/
├── .dockerignore
│
├── docs/                                    # ← All documentation centralized here
│   ├── getting-started_{en,zh}.md           # Getting Started Guide
│   ├── docker-quickstart{,_zh}.md           # Docker Quickstart
│   ├── technical-deep-dive_{en,zh}.md       # eBPF Technical Deep Dive
│   ├── code-architecture{,_zh}.md           # Code Architecture
│   ├── demo-walkthrough_{en,zh}.md          # Demo Walkthrough (5-step with real output)
│   ├── test-infrastructure_{en,zh}.md       # This document: Test Infrastructure Guide
│   ├── STABILITY-REPORT{,_zh}.md            # 48h Stability Test Report
│   ├── CASE-STUDY-REPORT_zh.md              # Case Study Report
│   ├── final-report_{en,zh}.md              # Final Project Report
│   ├── monthly-report-final_{en,zh}.md      # Final Monthly Community Report
│   └── RELEASE-v0.1.0.md                    # v0.1.0 Release Notes
│
├── docker/                                  # Docker build + all scripts
│   ├── Dockerfile                           # Two-stage build (rust + ubuntu)
│   ├── entrypoint.sh                        # Container entry dispatcher
│   ├── env-check.sh                         # Host environment check
│   ├── README.md                            # Docker quick reference
│   ├── ckb-config/
│   │   └── ckb.toml.aggressive              # Compaction trigger configuration
│   └── scripts/                             # ← All scripts centralized here
│       ├── perf/                             # Performance tests (P-1~P-4)
│       │   ├── perf-run-orchestrator.sh      #   Full 4h test (live node)
│       │   ├── perf-phase-a.sh               #   Phase A only (with-probe)
│       │   ├── perf-phase-b.sh               #   Phase B only (baseline)
│       │   ├── p1-cpu.sh                     #   Individual CPU test
│       │   ├── p2-rss.sh                     #   Individual RSS test
│       │   ├── p3-stress.sh                  #   Individual event loss test
│       │   └── p4-sync.sh                    #   Individual sync test
│       ├── stability/                        # Stability tests (S-1~S-4)
│       │   ├── stability-48h.sh              #   48h continuous test
│       │   └── generate-report.sh            #   Report generator
│       ├── demo/                             # Demo scripts
│       │   ├── demo-check.sh                 #   Environment + symbol check
│       │   ├── demo-table.sh                 #   Default table mode
│       │   ├── demo-histogram.sh             #   Latency distribution histogram
│       │   ├── demo-slow.sh                  #   Slow operation capture
│       │   ├── demo-normal.sh                #   JSON monitoring output
│       │   └── demo-stress.sh                #   db_bench stress test
│       └── case/                             # Case studies
│           ├── start-ckb.sh                  #   Start CKB utility
│           ├── case-1-ibd-write-pattern.sh   #   IBD write pattern
│           └── case-2-compaction-storm.sh    #   Compaction storm
│
└── README.md / README_zh.md                  # Project README
```

---

## 8. Troubleshooting

### ckb-probe Fails to Start

```bash
# Check if eBPF binary exists
ls -la ckb-probe-ebpf/target/bpfel-unknown-none/release/ckb-probe-ebpf

# Rebuild
cargo xtask build-ebpf && cargo build --release
```

### RocksDB Symbols Not Found

```bash
# Verify RocksDB symbols in CKB binary
ckb-probe symbols /path/to/ckb --tier 1
```

### P-4 Results Are Unstable

blocks/min fluctuates significantly when the node is near the tip -- this is expected behavior. Stop CKB for several hours to fall behind the tip before testing:

```bash
# Stop CKB for a few hours, then run the test after restart
./docker/scripts/perf/perf-run-orchestrator.sh
```

### Insufficient BPF Permissions in Docker

Make sure to use `--privileged` and mount:
```bash
-v /sys/kernel/debug:/sys/kernel/debug:ro
-v /sys/kernel/btf:/sys/kernel/btf:ro
```

### uprobe Collects No Data in Docker (QPS All Zeros)

Cause: uprobe attaches via binary path. The container defaults to `/usr/local/bin/ckb`, but the host process exe is `/root/ckb` -- the path mismatch causes hook failure.

Solution: Mount the host CKB binary and keep paths consistent:
```bash
-v /root/ckb:/root/ckb:ro -e CKB_BIN=/root/ckb
```

### Docker Build Fails: Cannot Pull Images

The Docker daemon does not inherit proxy settings from shell environment variables by default. Separate configuration is required -- see [Section 5.1](#51-prerequisite-docker-proxy-configuration).

### Docker Build Fails: GLIBC Version Mismatch

The Rust base image used during compilation may have a higher glibc version than the runtime image. Ensure the runtime stage uses `ubuntu:24.04` (glibc 2.39) rather than `debian:bookworm-slim` (glibc 2.36).

### 48h Test Interrupted Midway

Data files are written incrementally -- already collected data is not lost:

```bash
# Generate partial report from existing data
./docker/scripts/stability/generate-report.sh /tmp/stability-<timestamp>/
```
