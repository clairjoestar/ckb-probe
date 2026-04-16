#!/usr/bin/env bash
#
# demo-slow.sh — 端到端演示：慢操作模式
#
# 启动 ckb-probe rocksdb --slow，捕获超过阈值的 RocksDB 操作，
# 运行指定时长后停止。展示慢操作实时表格和 BPF 事件丢失率。
#
# Usage:
#   ./demo-slow.sh [duration_seconds] [threshold_us]
#
# Default: 60s, threshold 1000μs

set -euo pipefail

DURATION="${1:-60}"
THRESHOLD="${2:-1000}"
CKB_BIN="${CKB_BIN:-/usr/local/bin/ckb}"
PROBE_BIN="${PROBE_BIN:-/usr/local/bin/ckb-probe}"
OUTPUT_DIR="${OUTPUT_DIR:-/tmp/perf-run}/demo"
mkdir -p "$OUTPUT_DIR"

PROBE_LOG=$OUTPUT_DIR/demo-slow.log

CKB_PID=$(pgrep -x ckb | head -n1 || true)
if [[ -z "$CKB_PID" ]]; then
    echo "FATAL: CKB is not running" >&2
    exit 1
fi

echo "════════════════════════════════════════════════════════════════"
echo "  demo-slow — slow operations mode"
echo "════════════════════════════════════════════════════════════════"
echo "  ckb pid     : $CKB_PID"
echo "  duration    : ${DURATION}s"
echo "  threshold   : ${THRESHOLD}μs"
echo "  output      : $PROBE_LOG"
echo

cleanup() {
    if [[ -n "${PROBE_PID:-}" ]]; then
        kill -INT "$PROBE_PID" 2>/dev/null || true
        sleep 2
        kill -TERM "$PROBE_PID" 2>/dev/null || true
    fi
}
trap cleanup EXIT INT TERM

echo "[demo-slow] starting ckb-probe rocksdb --slow --threshold $THRESHOLD --interval 5"
nohup "$PROBE_BIN" rocksdb \
    --binary "$CKB_BIN" --pid "$CKB_PID" \
    --slow --threshold "$THRESHOLD" --interval 5 \
    > "$PROBE_LOG" 2>&1 &
disown
sleep 4
PROBE_PID=$(pgrep -x ckb-probe | head -n1)
[[ -z "$PROBE_PID" ]] && { echo "FATAL: ckb-probe failed"; cat "$PROBE_LOG"; exit 1; }
echo "[demo-slow] ckb-probe pid=$PROBE_PID, running for ${DURATION}s..."

sleep "$DURATION"

kill -INT "$PROBE_PID" 2>/dev/null || true
sleep 3
PROBE_PID=""

# Summary
SLOW_COUNT=$(grep -cE 'GET|PUT|WRITE|TXN_COMMIT|ITER_NEW' "$PROBE_LOG" 2>/dev/null || true)
SLOW_COUNT="${SLOW_COUNT:-0}"
LAST_LOSS=$(grep -a "BPF event loss" "$PROBE_LOG" | tail -1 || echo "n/a")

echo
echo "===== last slow-op frame ====="
awk '/\[2J\[H/{buf=""} {buf=buf $0 "\n"} END{printf "%s", buf}' "$PROBE_LOG"

echo
echo "  slow operations captured : $SLOW_COUNT"
echo "  $LAST_LOSS"
echo "  -> saved to $PROBE_LOG"
echo
echo "════════════════════════════════════════════════════════════════"
echo "  demo-slow complete"
echo "════════════════════════════════════════════════════════════════"
