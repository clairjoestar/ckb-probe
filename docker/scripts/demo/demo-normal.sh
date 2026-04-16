#!/usr/bin/env bash
#
# demo-normal.sh — capture 5 minutes of normal monitoring as JSON snapshot.
#
# Runs ckb-probe rocksdb --json for 300 seconds, saves all per-cycle JSON
# objects as JSONL, extracts the final cycle as the canonical "snapshot".

set -euo pipefail

CKB_BIN="${CKB_BIN:-/usr/local/bin/ckb}"
PROBE_BIN="${PROBE_BIN:-/usr/local/bin/ckb-probe}"
OUTPUT_DIR="${OUTPUT_DIR:-/tmp/perf-run}/demo"
mkdir -p "$OUTPUT_DIR"

DURATION="${1:-300}"   # default 5 minutes
INTERVAL=5

JSONL_OUT=$OUTPUT_DIR/demo-normal.jsonl
SNAPSHOT_OUT=$OUTPUT_DIR/demo-normal-snapshot.json
PROBE_LOG=$OUTPUT_DIR/demo-normal.log
> "$JSONL_OUT"; > "$PROBE_LOG"

CKB_PID=$(pgrep -x ckb | head -n1 || true)
if [[ -z "$CKB_PID" ]]; then
    echo "demo-normal: starting ckb first..."
    /opt/scripts/case/start-ckb.sh
    CKB_PID=$(pgrep -x ckb | head -n1)
fi

echo "════════════════════════════════════════════════════════════════"
echo "  demo-normal — capture 5 min of normal monitoring as JSON"
echo "════════════════════════════════════════════════════════════════"
echo "  ckb pid     : $CKB_PID"
echo "  duration    : ${DURATION}s"
echo "  interval    : ${INTERVAL}s"
echo "  output      : $JSONL_OUT (full JSONL)"
echo "                $SNAPSHOT_OUT (final-cycle snapshot)"
echo

cleanup() {
    if [[ -n "${PROBE_PID:-}" ]]; then
        kill -INT "$PROBE_PID" 2>/dev/null || true
        sleep 2
        kill -TERM "$PROBE_PID" 2>/dev/null || true
    fi
}
trap cleanup EXIT INT TERM

echo "[demo-normal] starting ckb-probe rocksdb --json --interval ${INTERVAL}"
nohup "$PROBE_BIN" rocksdb \
    --binary "$CKB_BIN" --pid "$CKB_PID" \
    --json --interval $INTERVAL \
    > "$PROBE_LOG" 2>&1 &
disown
sleep 4
PROBE_PID=$(pgrep -x ckb-probe | head -n1)
[[ -z "$PROBE_PID" ]] && { echo "FATAL: ckb-probe failed"; cat "$PROBE_LOG"; exit 1; }

echo "[demo-normal] ckb-probe pid=$PROBE_PID, sampling for ${DURATION}s..."
sleep "$DURATION"

# Stop probe
kill -INT "$PROBE_PID" 2>/dev/null || true
sleep 3
PROBE_PID=""

# Parse the probe log into JSONL — each cycle is a pretty-printed JSON object
# starting with "{" and ending with "}". Use jq to compact each object.
awk '
    /^{/ { collecting = 1; buf = ""; depth = 0 }
    collecting {
        buf = buf $0 "\n"
        n = gsub(/{/, "{", $0); depth += n
        n = gsub(/}/, "}", $0); depth -= n
        if (depth == 0) {
            print buf
            collecting = 0
        }
    }
' "$PROBE_LOG" | jq -c '.' > "$JSONL_OUT"

CYCLES=$(wc -l < "$JSONL_OUT")
echo "[demo-normal] captured $CYCLES JSON cycles"

if (( CYCLES > 0 )); then
    tail -1 "$JSONL_OUT" | jq '.' > "$SNAPSHOT_OUT"
    echo
    echo "===== final cycle snapshot ====="
    cat "$SNAPSHOT_OUT"
    echo
    echo "  -> saved to $SNAPSHOT_OUT"
else
    echo "WARNING: no JSON cycles parsed from $PROBE_LOG"
    head -50 "$PROBE_LOG"
fi
