#!/usr/bin/env bash
#
# demo-histogram.sh — 端到端演示：直方图模式
#
# 启动 ckb-probe rocksdb --histogram，运行指定时长后停止，
# 将 log2 分桶延迟分布输出保存到文件。展示五种操作的延迟分布。
#
# Usage:
#   ./demo-histogram.sh [duration_seconds]
#
# Default duration: 60s

set -euo pipefail

DURATION="${1:-60}"
CKB_BIN="${CKB_BIN:-/usr/local/bin/ckb}"
PROBE_BIN="${PROBE_BIN:-/usr/local/bin/ckb-probe}"
OUTPUT_DIR="${OUTPUT_DIR:-/tmp/perf-run}/demo"
mkdir -p "$OUTPUT_DIR"

PROBE_LOG=$OUTPUT_DIR/demo-histogram.log

CKB_PID=$(pgrep -x ckb | head -n1 || true)
if [[ -z "$CKB_PID" ]]; then
    echo "FATAL: CKB is not running" >&2
    exit 1
fi

echo "════════════════════════════════════════════════════════════════"
echo "  demo-histogram — latency distribution mode"
echo "════════════════════════════════════════════════════════════════"
echo "  ckb pid     : $CKB_PID"
echo "  duration    : ${DURATION}s"
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

echo "[demo-histogram] starting ckb-probe rocksdb --histogram --interval 5"
nohup "$PROBE_BIN" rocksdb \
    --binary "$CKB_BIN" --pid "$CKB_PID" \
    --histogram --interval 5 \
    > "$PROBE_LOG" 2>&1 &
disown
sleep 4
PROBE_PID=$(pgrep -x ckb-probe | head -n1)
[[ -z "$PROBE_PID" ]] && { echo "FATAL: ckb-probe failed"; cat "$PROBE_LOG"; exit 1; }
echo "[demo-histogram] ckb-probe pid=$PROBE_PID, running for ${DURATION}s..."

sleep "$DURATION"

kill -INT "$PROBE_PID" 2>/dev/null || true
sleep 3
PROBE_PID=""

echo
echo "===== last histogram frame ====="
awk '/\[2J\[H/{buf=""} {buf=buf $0 "\n"} END{printf "%s", buf}' "$PROBE_LOG"

echo
echo "  -> saved to $PROBE_LOG"
echo
echo "════════════════════════════════════════════════════════════════"
echo "  demo-histogram complete"
echo "════════════════════════════════════════════════════════════════"
