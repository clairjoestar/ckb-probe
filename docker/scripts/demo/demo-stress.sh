#!/usr/bin/env bash
#
# demo-stress.sh — inject synthetic RocksDB load with db_bench, watch ckb-probe
# react with elevated WRITE/TXN_COMMIT latency and slow operation entries.
#
# Workflow:
#   1) start ckb-probe rocksdb --slow --threshold 500 against running CKB
#   2) launch db_bench fillrandom --num=100000 in background (separate db,
#      same disk → creates I/O contention that ripples into CKB's RocksDB)
#   3) wait for db_bench to finish + 30s cool-down
#   4) stop ckb-probe, summarise: slow events count, anomaly count, etc.
#
# Requires: db_bench (from rocksdb-tools or compiled from source)
#
# Testnet only. Never use with mainnet.

set -euo pipefail

CKB_BIN="${CKB_BIN:-/usr/local/bin/ckb}"
PROBE_BIN="${PROBE_BIN:-/usr/local/bin/ckb-probe}"
OUTPUT_DIR="${OUTPUT_DIR:-/tmp/perf-run}/demo"
mkdir -p "$OUTPUT_DIR"

NUM_ENTRIES="${1:-100000}"
DBBENCH_DIR=/tmp/dbbench-demo-db
PROBE_LOG=$OUTPUT_DIR/demo-stress-probe.log
DBBENCH_LOG=$OUTPUT_DIR/demo-stress-dbbench.log
REPORT=$OUTPUT_DIR/demo-stress.txt
> "$PROBE_LOG"; > "$DBBENCH_LOG"; > "$REPORT"

# ── Pre-flight: db_bench is required ─────────────────────────
if ! command -v db_bench >/dev/null 2>&1; then
    echo "FATAL: db_bench not found." >&2
    echo "Install it:" >&2
    echo "  apt install rocksdb-tools        # Debian" >&2
    echo "  or build from RocksDB source:    make db_bench" >&2
    exit 1
fi

CKB_PID=$(pgrep -x ckb | head -n1 || true)
if [[ -z "$CKB_PID" ]]; then
    echo "FATAL: CKB is not running" >&2
    exit 1
fi

cleanup() {
    [[ -n "${DBB_PID:-}" ]] && kill "$DBB_PID" 2>/dev/null || true
    if [[ -n "${PROBE_PID:-}" ]]; then
        kill -INT "$PROBE_PID" 2>/dev/null || true
        sleep 2
        kill -TERM "$PROBE_PID" 2>/dev/null || true
    fi
}
trap cleanup EXIT INT TERM

echo "════════════════════════════════════════════════════════════════"
echo "  demo-stress — synthetic RocksDB load injection (db_bench)"
echo "════════════════════════════════════════════════════════════════"
echo "  ckb pid       : $CKB_PID"
echo "  db_bench size : $NUM_ENTRIES entries × 4KB = ~$(( NUM_ENTRIES * 4 / 1024 )) MB"
echo "  output        : $REPORT"
echo

# ── 1) Attach ckb-probe in slow mode ─────────────────────────
echo "[demo-stress] starting ckb-probe rocksdb --slow --threshold 500"
nohup "$PROBE_BIN" rocksdb \
    --binary "$CKB_BIN" --pid "$CKB_PID" \
    --slow --threshold 500 --interval 3 \
    > "$PROBE_LOG" 2>&1 &
disown
sleep 4
PROBE_PID=$(pgrep -x ckb-probe | head -n1)
[[ -z "$PROBE_PID" ]] && { echo "FATAL: ckb-probe failed"; cat "$PROBE_LOG"; exit 1; }
echo "[demo-stress] ckb-probe pid=$PROBE_PID"

# Baseline window
echo "[demo-stress] capturing 15s baseline..."
sleep 15

# ── 2) Launch db_bench burst ─────────────────────────────────
rm -rf "$DBBENCH_DIR"
echo "[demo-stress] launching db_bench fillrandom --num=$NUM_ENTRIES --threads=4 --value_size=4096"
nohup db_bench \
    --benchmarks=fillrandom \
    --num="$NUM_ENTRIES" \
    --threads=4 \
    --value_size=4096 \
    --db="$DBBENCH_DIR" \
    > "$DBBENCH_LOG" 2>&1 &
disown
sleep 1
DBB_PID=$(pgrep -f 'db_bench.*fillrandom' | head -n1 || true)
echo "[demo-stress] db_bench pid=$DBB_PID"

# ── 3) Wait for db_bench to finish ───────────────────────────
echo "[demo-stress] waiting for db_bench to complete..."
while kill -0 "$DBB_PID" 2>/dev/null; do
    sleep 5
done
echo "[demo-stress] db_bench done"
DBB_PID=""

# Cool-down to capture post-burst recovery
echo "[demo-stress] 30s cool-down..."
sleep 30

# ── 4) Stop ckb-probe and summarise ──────────────────────────
kill -INT "$PROBE_PID" 2>/dev/null || true
sleep 3
PROBE_PID=""

ANOMALY_COUNT=$(grep -c "ANOMALY DETECTED" "$PROBE_LOG" 2>/dev/null || true)
ANOMALY_COUNT="${ANOMALY_COUNT:-0}"
SLOW_LINE_COUNT=$(grep -cE 'GET|PUT|WRITE|TXN_COMMIT|ITER_NEW' "$PROBE_LOG" 2>/dev/null || true)
SLOW_LINE_COUNT="${SLOW_LINE_COUNT:-0}"
LAST_LOSS=$(grep -a "BPF event loss" "$PROBE_LOG" | tail -1 || echo "n/a")

DBBENCH_SUMMARY=$(grep -E '^fillrandom' "$DBBENCH_LOG" | head -3 || echo "(no summary parsed)")

{
    echo "════════════════════════════════════════════════════════════════"
    echo "  demo-stress result"
    echo "  $(date '+%F %T')"
    echo "════════════════════════════════════════════════════════════════"
    echo
    echo "ckb-probe captured during stress:"
    echo "  ANOMALY DETECTED count : $ANOMALY_COUNT"
    echo "  slow op log lines      : $SLOW_LINE_COUNT"
    echo "  $LAST_LOSS"
    echo
    echo "db_bench fillrandom summary:"
    echo "$DBBENCH_SUMMARY"
    echo
    if (( ANOMALY_COUNT > 0 )); then
        echo "First ANOMALY block:"
        grep -A 4 "ANOMALY DETECTED" "$PROBE_LOG" | head -20
    else
        echo "Note: no ANOMALY DETECTED triggered. This can happen if the disk had"
        echo "      enough headroom to absorb db_bench without contending with CKB."
        echo "      Try with a larger --num or apply ckb.toml.aggressive via case-2."
    fi
    echo
    echo "Output files:"
    echo "  $PROBE_LOG"
    echo "  $DBBENCH_LOG"
} | tee "$REPORT"

# Cleanup db_bench data
rm -rf "$DBBENCH_DIR"
