#!/usr/bin/env bash
#
# p3-stress.sh — sustained-load BPF event loss test for P-3 (< 0.1%).
#
# Method: run ckb-probe in slow mode with --threshold 1 (every RocksDB op
# becomes a slow event), optionally create extra disk pressure with db_bench,
# read the loss rate from the probe footer at the end.
#
# Usage:
#   ./p3-stress.sh [duration_seconds] [--no-db-bench]

set -euo pipefail

OUTPUT_DIR="${OUTPUT_DIR:-/tmp/perf-run}"
PROBE_BIN="${PROBE_BIN:-$(command -v ckb-probe 2>/dev/null || echo /root/ckb-probe/target/release/ckb-probe)}"
CKB_BIN="${CKB_BIN:-$(command -v ckb 2>/dev/null || echo /root/ckb)}"
mkdir -p "$OUTPUT_DIR"

DURATION="${1:-300}"   # default 5 minutes
USE_DB_BENCH=1
[[ "${2:-}" == "--no-db-bench" ]] && USE_DB_BENCH=0

PROBE_LOG="$OUTPUT_DIR/p3-probe.log"
DBBENCH_LOG="$OUTPUT_DIR/p3-dbbench.log"
> "$PROBE_LOG"; > "$DBBENCH_LOG"

CKB_PID=$(pgrep -x ckb || true)
if [[ -z "$CKB_PID" ]]; then
    echo "[p3-stress] FATAL: no ckb running" >&2
    exit 1
fi

echo "[p3-stress] starting ckb-probe slow mode --threshold 1 against ckb pid=$CKB_PID"
nohup "$PROBE_BIN" rocksdb \
    --binary "$CKB_BIN" --pid "$CKB_PID" \
    --slow --threshold 1 --interval 5 \
    > "$PROBE_LOG" 2>&1 &
disown
sleep 4
PROBE_PID=$(pgrep -x ckb-probe | head -n1)
echo "[p3-stress] ckb-probe pid=$PROBE_PID"

if [[ "$USE_DB_BENCH" == "1" ]]; then
    echo "[p3-stress] starting db_bench background load"
    rm -rf /tmp/dbbench-db
    nohup db_bench \
        --benchmarks=fillrandom,readrandom,fillrandom \
        --num=1000000 \
        --threads=2 \
        --db=/tmp/dbbench-db \
        > "$DBBENCH_LOG" 2>&1 &
    disown
    DBB_PID=$(pgrep -f 'db_bench' | head -n1)
    echo "[p3-stress] db_bench pid=$DBB_PID"
fi

echo "[p3-stress] running for ${DURATION}s..."
sleep "$DURATION"

# Stop everything
echo "[p3-stress] stopping..."
[[ -n "${DBB_PID:-}" ]] && kill "$DBB_PID" 2>/dev/null || true
kill -INT "$PROBE_PID" 2>/dev/null || true
sleep 3
kill -TERM "$PROBE_PID" 2>/dev/null || true

# Parse the last "BPF event loss" line from the probe footer
LAST=$(grep -a "BPF event loss" "$PROBE_LOG" | tail -1 || echo "")
if [[ -z "$LAST" ]]; then
    echo "[p3-stress] FATAL: no 'BPF event loss' line found in $PROBE_LOG" >&2
    exit 1
fi
LOST=$(echo "$LAST" | grep -oP '^\s*BPF event loss: \K\d+')
TOTAL=$(echo "$LAST" | grep -oP '\d+(?= attempted)')
PCT=$(echo "$LAST" | grep -oP '\(\K[0-9.]+(?=%)')
RATE=$(awk -v t="$TOTAL" -v s="$DURATION" 'BEGIN {printf "%.0f", t/s}')

echo
echo "===== P-3 result ====="
printf "  duration               : %ds\n" "$DURATION"
printf "  total events attempted : %s\n" "$TOTAL"
printf "  events lost            : %s\n" "$LOST"
printf "  loss rate              : %s%%\n" "$PCT"
printf "  achieved event rate    : %s events/sec\n" "$RATE"
printf "  P-3 budget             : < 0.1%% loss\n"
awk -v p="$PCT" 'BEGIN {
    if (p < 0.1) print "  status                 : ✅ PASS"
    else         print "  status                 : ❌ FAIL"
}'

if (( RATE < 10000 )); then
    cat <<NOTE

Note: achieved rate $RATE/s is below the 10K/s P-3 spec target. This is
expected when CKB is near tip; for a true 10K/s test the node should be
in IBD or under sustained heavy RPC load. Run case-1 + p3-stress in
combination for the most stressful scenario.
NOTE
fi
