#!/usr/bin/env bash
#
# perf-phase-b.sh — Run Phase B only (baseline, no probe, 2h).
#
# CKB must NOT be running. This script starts CKB inside Docker,
# runs 2h WITHOUT probe, then stops everything.
#
# Usage:
#   ./perf-phase-b.sh <ckb-dir>
#
# Example:
#   # 1. Unzip fresh data (don't start CKB)
#   unzip -o ckb-testnet.zip -d /root/ckb-testnet
#   # 2. Run Phase B
#   ./perf-phase-b.sh /root/ckb-testnet
#
# Testnet only.

set -uo pipefail

CKB_DIR="${1:?usage: perf-phase-b.sh <ckb-dir>}"
WORK="${OUTPUT_DIR:-/tmp/perf-run}"
PHASE_SECS="${PHASE_SECS:-7200}"

mkdir -p "$WORK"

if pgrep -x ckb >/dev/null 2>&1; then
    echo "FATAL: CKB is already running. Stop it first." >&2
    exit 1
fi

if [[ ! -f "$CKB_DIR/ckb" || ! -d "$CKB_DIR/data/db" ]]; then
    echo "FATAL: $CKB_DIR does not contain ckb binary or data/db/" >&2
    exit 1
fi

mkdir -p "$CKB_DIR/data/logs"
rm -f "$CKB_DIR/data/db/LOCK"

echo "[$(date '+%F %T')] Starting Phase B (baseline, no probe, ${PHASE_SECS}s)"
echo "[$(date '+%F %T')] CKB dir: $CKB_DIR"
echo "[$(date '+%F %T')] Output:  $WORK"

docker rm perf-phaseB 2>/dev/null || true

docker run -d --name perf-phaseB \
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
CKB_RPC=http://127.0.0.1:8124

log() { echo "[$(date "+%F %T")] $*" | tee -a "$WORK/progress.log"; }

log "Phase B: starting CKB (NO probe)..."
cd "$CKB_DIR" && nohup ./ckb run > /tmp/ckb-phaseB.log 2>&1 &
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
log "Phase B: CKB ready pid=$CKB_PID tip=$(printf %d $TIP) (NO probe)"

# P-1 baseline
pidstat -u -h -p "$CKB_PID" 5 1440 > "$WORK/p1-baseline.log" 2>&1 &

# P-4 baseline
(echo "# ts hex dec" > "$WORK/p4-baseline.log"
for i in $(seq 1 120); do
    ts=$(date +%s)
    h=$(NO_PROXY=127.0.0.1 curl -s -X POST "$CKB_RPC" \
        -H "Content-Type: application/json" \
        -d "{\"id\":1,\"jsonrpc\":\"2.0\",\"method\":\"get_tip_block_number\",\"params\":[]}" \
        | jq -r ".result // empty")
    [ -n "$h" ] && echo "$ts $h $(printf %d $h)" >> "$WORK/p4-baseline.log"
    sleep 60
done) &

log "Phase B: collectors started, waiting ${PHASE_SECS}s..."
sleep "$PHASE_SECS"

pkill -x ckb 2>/dev/null || true
sleep 3
log "Phase B: complete"
'

echo "[$(date '+%F %T')] Phase B container started. Monitoring..."

while docker ps --filter name=perf-phaseB --format "{{.Status}}" | grep -q Up; do
    sleep 60
done

docker rm perf-phaseB 2>/dev/null || true

echo ""
echo "[$(date '+%F %T')] Phase B finished."
echo "  p1: $(wc -l < $WORK/p1-baseline.log 2>/dev/null) lines"
echo "  p4: $(grep -vc '^#' $WORK/p4-baseline.log 2>/dev/null) samples"
echo "  start tip: $(awk '/^#/{next} NF==3{print $3; exit}' $WORK/p4-baseline.log)"
