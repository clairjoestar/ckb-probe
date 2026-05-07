# ckb-probe Getting Started Guide

> Complete steps from cloning the repository to running all tests and demos.
>
> **Scope: CKB testnet only, never mainnet.**

---

## 1. Prerequisites

| Requirement | Minimum Version |
|-------------|-----------------|
| Linux kernel | >= 5.8 |
| BTF support | `/sys/kernel/btf/vmlinux` must exist |
| Docker | >= 20.10 |
| Available memory | >= 4 GB |
| Available disk | >= 20 GB (excluding CKB data) |
| CKB testnet node data | A synced data directory |
| CKB binary | A ckb executable matching the data |

---

## 2. Clone the Repository

```bash
git clone https://github.com/<org>/ckb-probe.git
cd ckb-probe
```

---

## 3. Build the Docker Image

```bash
docker build -f docker/Dockerfile -t ckb-probe:latest .
```

Build takes about 10-15 minutes. The image includes:
- ckb-probe (compiled from source with eBPF)
- db_bench (compiled from RocksDB source)
- All test / demo / case study scripts

**Note:** CKB binary is NOT included in the image. It must be mounted from the host via `-v`.

---

## 4. Prepare the CKB Node

Place your existing CKB testnet node data on the host, e.g. `/root/ckb-testnet/`:

```
/root/ckb-testnet/
├── ckb              # CKB binary
├── ckb.toml         # Configuration file
├── ckb-miner.toml
├── default.db-options
└── data/            # Chain data (contains db/ subdirectory)
```

Start the CKB node:

```bash
cd /root/ckb-testnet
./ckb run &

# Verify RPC is available
curl -s -X POST http://127.0.0.1:8124 \
  -H 'Content-Type: application/json' \
  -d '{"id":1,"jsonrpc":"2.0","method":"get_tip_block_number","params":[]}' | jq
```

---

## 5. Docker Run Command Template

All scripts are run inside Docker using the following template:

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

**Parameter descriptions:**

| Parameter | Purpose |
|-----------|---------|
| `--privileged --pid host` | eBPF requires privileges + shared host PID namespace |
| `--network host` | Container uses host network directly (to access CKB RPC) |
| `-v .../ckb:...ckb:ro` | Mount the CKB binary (path must match the host process exe) |
| `-e CKB_BIN=...` | Tell the scripts the CKB binary path |

> **Critical:** The CKB binary path mounted with `-v` must exactly match the exe path of the CKB process on the host,
> otherwise uprobe cannot attach and no data will be collected. Verify with `readlink /proc/$(pgrep -x ckb)/exe`.

---

## 6. Run Demo Scripts

Demo scripts are read-only monitors that do not affect the CKB node and can be run at any time.

### 6.1 Environment Check

```bash
$DOCKER_RUN demo-check
```

Verifies kernel, BTF, BPF, CKB process, and RocksDB symbols; takes about 30 seconds.

### 6.2 Default Table Mode

```bash
$DOCKER_RUN demo-table 60       # 60 seconds
```

Displays a real-time QPS / Avg / P50 / P99 / Bytes/s table.

### 6.3 Latency Distribution Histogram

```bash
$DOCKER_RUN demo-histogram 60   # 60 seconds
```

Displays log2-bucketed latency distributions for five RocksDB operations.

### 6.4 Slow Operation Capture

```bash
$DOCKER_RUN demo-slow 60 1000   # 60 seconds, threshold 1000us
```

Captures RocksDB operations exceeding the threshold, showing timestamp / operation type / latency / size.

### 6.5 JSON Monitoring Output

```bash
$DOCKER_RUN demo-normal 60      # 60 seconds
```

Outputs machine-readable JSON-formatted monitoring data.

### 6.6 Stress Test (requires db_bench)

```bash
$DOCKER_RUN demo-stress 100000  # 100,000 fillrandom entries
```

Uses db_bench to inject RocksDB workload and observe ckb-probe capturing latency spikes and slow operations.

---

## 7. Run Performance Tests (P-1 ~ P-4)

### 7.1 Prerequisites

The CKB node must be **behind the network tip** (in IBD state) to generate sufficient RocksDB operation density.

Methods:
- Use node data from a node that has been stopped for several hours/days
- Or stop CKB for several hours then restart

### 7.2 Full 4-Hour Test

```bash
docker run -d --name perf-test \
  --privileged --pid host --network host \
  -v /sys/kernel/debug:/sys/kernel/debug:ro \
  -v /sys/kernel/btf:/sys/kernel/btf:ro \
  -v /root/ckb-testnet/ckb:/root/ckb-testnet/ckb:ro \
  -v /tmp/perf-run:/tmp/perf-run \
  -e CKB_BIN=/root/ckb-testnet/ckb \
  -e CKB_RPC=http://127.0.0.1:8124 \
  ckb-probe:latest perf
```

Phase A (2h with-probe) -> Phase B (2h baseline) -> report generated automatically.

### 7.3 Monitor Progress

```bash
# Progress
tail -5 /tmp/perf-run/progress.log

# P-2 RSS
tail -1 /tmp/perf-run/p2-rss.log | awk '{printf "RSS: %.1f MB\n", $2/1024}'

# P-3 event loss
grep -a "BPF event loss" /tmp/perf-run/probe-slow.log | tail -1

# P-4 sync
tail -3 /tmp/perf-run/p4-with-probe.log

# Final report
cat /tmp/perf-run/REPORT.txt
```

### 7.4 Individual Tests

If you don't want to run the full 4h suite, you can enter the container and run tests individually:

```bash
# Enter the container
docker run --rm -it --privileged --pid host --network host \
  -v /sys/kernel/debug:/sys/kernel/debug:ro \
  -v /sys/kernel/btf:/sys/kernel/btf:ro \
  -v /root/ckb-testnet/ckb:/root/ckb-testnet/ckb:ro \
  -v /tmp/perf-run:/tmp/perf-run \
  -e CKB_BIN=/root/ckb-testnet/ckb \
  -e CKB_RPC=http://127.0.0.1:8124 \
  --entrypoint "" \
  ckb-probe:latest bash

# Inside the container:
/opt/scripts/perf/p1-cpu.sh baseline 60       # P-1 baseline 1 minute
/opt/scripts/perf/p1-cpu.sh with-probe 60     # P-1 with-probe (ckb-probe must be started first)
/opt/scripts/perf/p2-rss.sh                   # P-2 RSS monitoring
/opt/scripts/perf/p3-stress.sh 300            # P-3 event loss 5 minutes
/opt/scripts/perf/p4-sync.sh baseline 5       # P-4 baseline 5 minutes

# P-3 extreme stress test: --threshold sets the slow operation
# threshold in microseconds (μs). Only operations exceeding this
# latency are sent from kernel to userspace via RingBuf.
#
# --threshold 1000 (default, 1ms): captures genuinely slow ops
#   (e.g. GET spiking from 10μs to 5ms due to compaction/cache miss).
#   Low event volume, minimal CPU overhead. Use for normal monitoring.
#
# --threshold 1 (1μs): almost all RocksDB ops exceed 1μs, so every
#   operation becomes an "event" — no filtering at all. This generates
#   10K+ events/sec during IBD via RingBuf. Normal ops (5-50μs) have
#   no diagnostic value at this threshold; the only purpose is
#   stress-testing P-3 BPF event loss under maximum load.
#   RingBuf eliminates per-event context switches (vs PerfEventArray),
#   significantly reducing CPU overhead.
ckb-probe rocksdb --binary $CKB_BIN --pid $(pgrep -x ckb) \
    --slow --threshold 1 --interval 5
```

### 7.5 Strict P-4 Comparison Test

P-4 requires both phases to run under IBD state. If the node catches up to the tip after Phase A, Phase B has no IBD workload, making the comparison meaningless.

Solution: Run Phase B with a freshly extracted copy of node data.

```bash
# After Phase A completes, stop CKB and re-extract the data
pkill -x ckb
rm -rf /root/ckb-testnet
unzip -o /root/ckb-testnet.zip -d /root/ckb-testnet
cd /root/ckb-testnet && ./ckb run &

# Run Phase B baseline separately
docker run -d --name perf-baseline \
  --privileged --pid host --network host \
  --entrypoint "" \
  -v /sys/kernel/debug:/sys/kernel/debug:ro \
  -v /sys/kernel/btf:/sys/kernel/btf:ro \
  -v /root/ckb-testnet/ckb:/root/ckb-testnet/ckb:ro \
  -v /tmp/perf-run:/tmp/perf-run \
  -e CKB_BIN=/root/ckb-testnet/ckb \
  -e CKB_RPC=http://127.0.0.1:8124 \
  ckb-probe:latest bash -c \
  "pidstat -u -h -p \$(pgrep -x ckb) 5 1440 > /tmp/perf-run/p1-baseline.log 2>&1"
  # Also run P-4 tip sampler (refer to Phase B logic in perf-run-orchestrator.sh)
```

---

## 8. Run Case Studies

### 8.1 Case 1: IBD Write Pattern Analysis

```bash
$DOCKER_RUN case-1 3600          # wait up to 1 hour
```

CKB must be in IBD state. Observe how PUT/WRITE throughput and latency evolve as chain height increases.

### 8.2 Case 2: Compaction Storm Capture

```bash
$DOCKER_RUN case-2 1800          # wait up to 30 minutes
```

Automatically applies `ckb.toml.aggressive` to lower compaction trigger thresholds, waits for ANOMALY DETECTED events, and captures the before/during/after context of latency spikes. The script automatically restores the original configuration when finished.

---

## 9. Run 48h Stability Tests (S-1 ~ S-4)

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
```

Test coverage:
- **S-1**: 48h with no crashes/panics/restarts
- **S-2**: RSS growth <= 5 MB
- **S-3**: No BPF warnings in dmesg
- **S-4**: Automatic CKB restart at T+24h to verify probe reconnection

### 9.1 Shorten Test Duration

```bash
# 2-hour quick verification
docker run -d --name stability-test \
  ... \
  -e DURATION_HOURS=2 \
  ckb-probe:latest stability
```

### 9.2 Generate Report

```bash
# Automatically generated after test completion, or manually regenerate
$DOCKER_RUN stability-report /tmp/perf-run/stability-<timestamp>/
```

---

## 10. View Output

All output is written to `/tmp/perf-run/` (accessible directly on the host via bind mount):

```bash
# Performance test report
cat /tmp/perf-run/REPORT.txt

# Stability test report
cat /tmp/perf-run/stability-*/STABILITY-REPORT.md

# Demo output
ls /tmp/perf-run/demo/

# Case study reports
cat /tmp/perf-run/case1/REPORT.txt
cat /tmp/perf-run/case2/REPORT.txt
```

---

## 11. Recommended Run Order

```
1. docker build                    # Build image (~15 min)
2. Start CKB node
3. demo-check                      # Verify environment (~30s)
4. demo-table / demo-histogram     # Quick demos (~1 min each)
5. demo-slow                       # Slow operation demo (~1 min)
6. demo-normal                     # JSON output (~5 min)
7. demo-stress                     # Stress test (~3 min)
8. case-1                          # IBD write pattern (~30 min, requires IBD state)
9. case-2                          # Compaction storm (~30 min)
10. perf                           # P-1~P-4 full test suite (~4h, requires IBD state)
11. stability                      # S-1~S-4 stability tests (48h)
```

**Notes:**
- Only one ckb-probe instance can run at a time
- Steps 8/10 require CKB to be in IBD state (node data behind the network tip)
- For a strict P-4 comparison in step 10, node data must be re-extracted for Phase B
- Step 11 takes 48 hours; it is recommended to run it last

---

## 12. Image Export

```bash
# Export
docker save ckb-probe:latest | gzip > ckb-probe-latest.tar.gz

# Import on another machine
docker load < ckb-probe-latest.tar.gz
```
