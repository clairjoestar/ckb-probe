#!/usr/bin/env bash
#
# case-1-ibd-write-pattern.sh — IBD write pattern case study.
#
# Captures RocksDB write amplification patterns during Initial Block Download.
# CKB must already be running and behind the network tip (in IBD state).
#
# Workflow:
#   1) attach ckb-probe rocksdb --histogram to the running CKB
#   2) poll tip every 30s to track sync progress
#   3) stop when within 10 blocks of network tip OR timeout
#   4) write summary report with PUT/WRITE throughput evolution
#
# Usage:
#   ./case-1-ibd-write-pattern.sh [max_duration_seconds]
#
# Default max duration: 7200 (2h)
#
# Testnet only. Never use with mainnet.

set -euo pipefail

MAX_SECS="${1:-7200}"

CKB_BIN="${CKB_BIN:-/usr/local/bin/ckb}"
CKB_RPC="${CKB_RPC:-http://127.0.0.1:8124}"
PROBE_BIN="${PROBE_BIN:-/usr/local/bin/ckb-probe}"
OUTPUT_DIR="${OUTPUT_DIR:-/tmp/perf-run}/case1"
mkdir -p "$OUTPUT_DIR"

CASE_LOG=$OUTPUT_DIR/case1.log
PROBE_LOG=$OUTPUT_DIR/probe.log
TIP_LOG=$OUTPUT_DIR/tip.log
REPORT=$OUTPUT_DIR/REPORT.txt
> "$CASE_LOG"; > "$PROBE_LOG"; > "$TIP_LOG"

log() { echo "[$(date '+%T')] $*" | tee -a "$CASE_LOG"; }

cleanup() {
    log "cleanup"
    if [[ -n "${PROBE_PID:-}" ]]; then
        kill -INT "$PROBE_PID" 2>/dev/null || true
        sleep 3
        kill -TERM "$PROBE_PID" 2>/dev/null || true
    fi
}
trap cleanup EXIT INT TERM

fetch_tip() {
    NO_PROXY=127.0.0.1 curl -s -X POST "$CKB_RPC" \
        -H 'Content-Type: application/json' \
        -d '{"id":1,"jsonrpc":"2.0","method":"get_tip_block_number","params":[]}' \
        | jq -r '.result // empty'
}

# ── 1) Verify CKB is running and in IBD ──────────────────────
log "===== case-1: IBD write pattern ====="
log "max duration: ${MAX_SECS}s"

CKB_PID=$(pgrep -x ckb | head -1 || true)
if [[ -z "$CKB_PID" ]]; then
    log "FATAL: CKB is not running. Start CKB with data behind network tip first."
    exit 1
fi

START_TIP_HEX=$(fetch_tip)
if [[ -z "$START_TIP_HEX" ]]; then
    log "FATAL: CKB RPC not responding"
    exit 1
fi
START_TIP=$(printf '%d' "$START_TIP_HEX")
START_TS=$(date +%s)
log "CKB pid=$CKB_PID, starting tip=$START_TIP"

# ── 2) Attach ckb-probe ──────────────────────────────────────
log "starting ckb-probe rocksdb --json --histogram --interval 10"
nohup "$PROBE_BIN" rocksdb \
    --binary "$CKB_BIN" --pid "$CKB_PID" \
    --json --histogram --interval 10 \
    > "$PROBE_LOG" 2>&1 &
disown
sleep 4
PROBE_PID=$(pgrep -x ckb-probe | head -1)
[[ -z "$PROBE_PID" ]] && { log "FATAL: ckb-probe failed"; tail -20 "$PROBE_LOG"; exit 1; }
log "ckb-probe attached, pid=$PROBE_PID"

# ── 3) Poll tip and track progress ───────────────────────────
echo "# ts tip_dec blocks_synced elapsed_s" > "$TIP_LOG"
PREV_TIP=$START_TIP

while true; do
    NOW=$(date +%s)
    ELAPSED=$((NOW - START_TS))

    if (( ELAPSED >= MAX_SECS )); then
        log "timeout reached (${MAX_SECS}s)"
        break
    fi

    CUR_HEX=$(fetch_tip)
    if [[ -n "$CUR_HEX" ]]; then
        CUR=$(printf '%d' "$CUR_HEX")
        SYNCED=$((CUR - START_TIP))
        echo "$NOW $CUR $SYNCED $ELAPSED" >> "$TIP_LOG"

        if (( CUR == PREV_TIP )) && (( ELAPSED > 300 )); then
            # If tip hasn't moved for a while, might have caught up
            log "tip stalled at $CUR (may have caught up to network tip)"
            break
        fi
        PREV_TIP=$CUR

        if (( ELAPSED % 300 < 30 )); then
            BPM=$(awk -v s="$SYNCED" -v e="$ELAPSED" 'BEGIN {if(e>0) printf "%.1f", s/(e/60); else print "0"}')
            log "progress: tip=$CUR  synced=$SYNCED blocks  ${BPM} blocks/min"
        fi
    fi

    sleep 30
done

# ── 4) Stop ckb-probe ────────────────────────────────────────
kill -INT "$PROBE_PID" 2>/dev/null || true
sleep 3
PROBE_PID=""

END_TIP_HEX=$(fetch_tip)
END_TIP=$(printf '%d' "$END_TIP_HEX" 2>/dev/null || echo "$START_TIP")
END_TS=$(date +%s)
TOTAL_BLOCKS=$((END_TIP - START_TIP))
TOTAL_SECS=$((END_TS - START_TS))
BPM=$(awk -v b="$TOTAL_BLOCKS" -v s="$TOTAL_SECS" 'BEGIN {if(s>0) printf "%.2f", b/(s/60); else print "0"}')

# ── 5) Write report ──────────────────────────────────────────
{
    echo "═══════════════════════════════════════════════════════════"
    echo "  Case Study 1: IBD Write Pattern Analysis"
    echo "  $(date '+%F %T')"
    echo "═══════════════════════════════════════════════════════════"
    echo
    echo "  start tip    : $START_TIP"
    echo "  end tip      : $END_TIP"
    echo "  blocks synced: $TOTAL_BLOCKS"
    echo "  duration     : ${TOTAL_SECS}s"
    echo "  avg rate     : $BPM blocks/min"
    echo
    echo "  Output files:"
    echo "    $PROBE_LOG  (JSON + histogram output)"
    echo "    $TIP_LOG    (tip progression)"
    echo "═══════════════════════════════════════════════════════════"
} | tee "$REPORT"

log "case-1 complete"
