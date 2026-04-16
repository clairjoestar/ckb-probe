#!/usr/bin/env bash
#
# perf-phase-a.sh — Run Phase A only (with-probe, 2h).
#
# CKB must NOT be running. This script starts CKB inside Docker,
# immediately attaches probe, runs 2h, then stops everything.
#
# After completion, combine with existing Phase B data to generate report:
#   Use perf-report.sh or manually merge.
#
# Usage:
#   ./perf-phase-a.sh <ckb-dir>
#
# Example:
#   # 1. Unzip fresh data (don't start CKB)
#   unzip -o ckb-testnet.zip -d /root/ckb-testnet
#   # 2. Run Phase A
#   ./perf-phase-a.sh /root/ckb-testnet
#
# Testnet only.

set -uo pipefail

CKB_DIR="${1:?usage: perf-phase-a.sh <ckb-dir>}"
WORK="${OUTPUT_DIR:-/tmp/perf-run}"
PHASE_SECS="${PHASE_SECS:-7200}"

mkdir -p "$WORK"

# Verify CKB is NOT running
if pgrep -x ckb >/dev/null 2>&1; then
    echo "FATAL: CKB is already running. Stop it first so both phases start from the same height." >&2
    exit 1
fi

# Verify data exists
if [[ ! -f "$CKB_DIR/ckb" || ! -d "$CKB_DIR/data/db" ]]; then
    echo "FATAL: $CKB_DIR does not contain ckb binary or data/db/" >&2
    exit 1
fi

mkdir -p "$CKB_DIR/data/logs"
rm -f "$CKB_DIR/data/db/LOCK"

echo "[$(date '+%F %T')] Starting Phase A (with-probe, ${PHASE_SECS}s)"
echo "[$(date '+%F %T')] CKB dir: $CKB_DIR"
echo "[$(date '+%F %T')] Output:  $WORK"

docker rm perf-phaseA 2>/dev/null || true

docker run -d --name perf-phaseA \
  --privileged --pid host --network host \
  --entrypoint "" \
  -v /sys/kernel/debug:/sys/kernel/debug:ro \
  -v /sys/kernel/btf:/sys/kernel/btf:ro \
  -v "$CKB_DIR:$CKB_DIR" \
  -v "$WORK:$WORK" \
  ckb-probe:latest bash -c '
set -uo pipefail
CKB_DIR='"$CKB_DIR"'
WORK='"$WORK"'
PHASE_SECS='"$PHASE_SECS"'
CKB_BIN="$CKB_DIR/ckb"
CKB_RPC=http://127.0.0.1:8124

log() { echo "[$(date "+%F %T")] $*" | tee -a "$WORK/progress.log"; }

log "Phase A: starting CKB..."
cd "$CKB_DIR" && nohup ./ckb run > /tmp/ckb-phaseA.log 2>&1 &
disown

for i in $(seq 1 120); do
    TIP=$(NO_PROXY=127.0.0.1 curl -s -X POST "$CKB_RPC" \
        -H "Content-Type: application/json" \
        -d "{\"id\":1,\"jsonrpc\":\"2.0\",\"method\":\"get_tip_block_number\",\"params\":[]}" \
        | jq -r ".result // empty")
    [ -n "$TIP" ] && break
    sleep 2
done
CKB_PID=$(pgrep -x ckb | head -1)
log "Phase A: CKB ready pid=$CKB_PID tip=$(printf %d $TIP)"

# Attach probe immediately
ckb-probe rocksdb --binary "$CKB_BIN" --pid "$CKB_PID" \
    --slow --threshold 1000 --interval 5 \
    > "$WORK/probe-slow.log" 2>&1 &
sleep 3
PROBE_PID=$(pgrep -x ckb-probe | head -1)
log "Phase A: probe pid=$PROBE_PID"

# P-1
pidstat -u -h -p "$CKB_PID" 5 1440 > "$WORK/p1-with-probe.log" 2>&1 &

# P-2
(> "$WORK/p2-rss.log"
while kill -0 "$PROBE_PID" 2>/dev/null; do
    ts=$(date +%s)
    rss=$(awk "/^VmRSS:/ {print \$2}" /proc/$PROBE_PID/status 2>/dev/null || echo 0)
    hwm=$(awk "/^VmHWM:/ {print \$2}" /proc/$PROBE_PID/status 2>/dev/null || echo 0)
    echo "$ts $rss $hwm" >> "$WORK/p2-rss.log"
    sleep 5
done) &

# P-4
(echo "# ts hex dec" > "$WORK/p4-with-probe.log"
for i in $(seq 1 120); do
    ts=$(date +%s)
    h=$(NO_PROXY=127.0.0.1 curl -s -X POST "$CKB_RPC" \
        -H "Content-Type: application/json" \
        -d "{\"id\":1,\"jsonrpc\":\"2.0\",\"method\":\"get_tip_block_number\",\"params\":[]}" \
        | jq -r ".result // empty")
    [ -n "$h" ] && echo "$ts $h $(printf %d $h)" >> "$WORK/p4-with-probe.log"
    sleep 60
done) &

log "Phase A: all collectors started, waiting ${PHASE_SECS}s..."
sleep "$PHASE_SECS"

pkill -x ckb-probe 2>/dev/null || true
sleep 3
pkill -x ckb 2>/dev/null || true
sleep 3
log "Phase A: complete"
'

echo "[$(date '+%F %T')] Phase A container started. Monitoring..."

# Follow progress
while docker ps --filter name=perf-phaseA --format "{{.Status}}" | grep -q Up; do
    sleep 60
done

docker rm perf-phaseA 2>/dev/null || true

echo ""
echo "[$(date '+%F %T')] Phase A finished."
echo "  p1: $(wc -l < $WORK/p1-with-probe.log 2>/dev/null) lines"
echo "  p2: $(wc -l < $WORK/p2-rss.log 2>/dev/null) lines"
echo "  p4: $(grep -vc '^#' $WORK/p4-with-probe.log 2>/dev/null) samples"
echo "  start tip: $(awk '/^#/{next} NF==3{print $3; exit}' $WORK/p4-with-probe.log)"
echo ""
echo "  Next: merge with Phase B data and generate report."
