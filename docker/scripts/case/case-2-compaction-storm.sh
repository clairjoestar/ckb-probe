#!/usr/bin/env bash
#
# case-2-compaction-storm.sh — compaction storm capture case study.
#
# Workflow:
#   1) merge aggressive RocksDB tuning into ckb.toml
#   2) restart CKB
#   3) attach ckb-probe rocksdb --slow --threshold 1000
#   4) wait for ANOMALY DETECTED in probe output (or timeout)
#   5) capture surrounding context, write report
#
# Usage:
#   ./case-2-compaction-storm.sh [max_wait_seconds]
#
# Default max wait: 1800 (30 minutes)

set -euo pipefail

MAX_WAIT="${1:-1800}"

CKB_BIN="${CKB_BIN:-/usr/local/bin/ckb}"
CKB_DATA="${CKB_DATA:-/data}"
CKB_RPC="${CKB_RPC:-http://127.0.0.1:8124}"
PROBE_BIN="${PROBE_BIN:-/usr/local/bin/ckb-probe}"
OUTPUT_DIR="${OUTPUT_DIR:-/tmp/perf-run}/case2"
mkdir -p "$OUTPUT_DIR"

CASE_LOG=$OUTPUT_DIR/case2.log
PROBE_LOG=$OUTPUT_DIR/probe.log
REPORT=$OUTPUT_DIR/REPORT.txt
> "$CASE_LOG"; > "$PROBE_LOG"

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

# ── 1) Apply aggressive tuning ────────────────────────────────
log "===== case-2: compaction storm capture ====="
TUNING=/opt/ckb-config/db-options.aggressive
TARGET=$CKB_DATA/default.db-options
BACKUP=$CKB_DATA/default.db-options.backup-case2

if [[ ! -f "$CKB_DATA/ckb.toml" ]]; then
    log "no ckb.toml found, running ckb init"
    "$CKB_BIN" init --chain testnet -C "$CKB_DATA"
fi

log "backing up current db-options -> $BACKUP"
cp "$TARGET" "$BACKUP"

log "replacing db-options with aggressive RocksDB tuning"
cp "$TUNING" "$TARGET"

# ── 2) Restart CKB ─────────────────────────────────────────────
if pgrep -x ckb >/dev/null; then
    log "stopping current ckb"
    kill -TERM $(pgrep -x ckb)
    while pgrep -x ckb >/dev/null; do sleep 2; done
fi

log "restarting ckb with aggressive tuning"
nohup "$CKB_BIN" run -C "$CKB_DATA" > /var/log/ckb.log 2>&1 &
disown

for _ in {1..150}; do
    if curl -sf -X POST "$CKB_RPC" \
        -H 'Content-Type: application/json' \
        -d '{"id":1,"jsonrpc":"2.0","method":"get_tip_block_number","params":[]}' \
        >/dev/null 2>&1; then
        break
    fi
    sleep 2
done
CKB_PID=$(pgrep -x ckb | head -n1)
log "ckb running, pid=$CKB_PID"

# ── 3) Attach ckb-probe ────────────────────────────────────────
log "attaching ckb-probe rocksdb --slow --threshold 1000 --interval 5"
nohup "$PROBE_BIN" rocksdb \
    --binary "$CKB_BIN" --pid "$CKB_PID" \
    --slow --threshold 1000 --interval 5 \
    > "$PROBE_LOG" 2>&1 &
disown
sleep 4
PROBE_PID=$(pgrep -x ckb-probe | head -n1)
log "ckb-probe pid=$PROBE_PID"

# ── 4) Wait for ANOMALY DETECTED ───────────────────────────────
log "waiting up to ${MAX_WAIT}s for ANOMALY DETECTED..."
START=$(date +%s)
DETECTED=0
while true; do
    if grep -q "ANOMALY DETECTED" "$PROBE_LOG" 2>/dev/null; then
        DETECTED=1
        log "ANOMALY DETECTED!"
        break
    fi
    NOW=$(date +%s)
    if (( NOW - START > MAX_WAIT )); then
        log "timeout waiting for anomaly"
        break
    fi
    sleep 10
done

# Capture 60s of additional context after first detection
if (( DETECTED == 1 )); then
    log "capturing 60s of post-detection context..."
    sleep 60
fi

# ── 5) Stop probe and write report ─────────────────────────────
kill -INT "$PROBE_PID" 2>/dev/null || true
sleep 3
PROBE_PID=""

# Restore original db-options
log "restoring original db-options"
cp "$BACKUP" "$TARGET"

ANOMALY_COUNT=$(grep -c "ANOMALY DETECTED" "$PROBE_LOG" 2>/dev/null || echo 0)
SLOW_COUNT=$(grep -cE "WRITE.*[0-9],[0-9]+μs" "$PROBE_LOG" 2>/dev/null || echo 0)

{
    echo "════════════════════════════════════════════════════════════════"
    echo "  case-2: compaction storm capture"
    echo "  Generated: $(date '+%F %T')"
    echo "════════════════════════════════════════════════════════════════"
    echo
    echo "Setup"
    echo "  tuning applied : $TUNING (low L0 trigger, 1 background job, 4MB memtable)"
    echo "  db-options.bak  : $BACKUP (restored at end)"
    echo "  max wait       : ${MAX_WAIT}s"
    echo
    echo "Result"
    echo "  ANOMALY DETECTED count : $ANOMALY_COUNT"
    echo "  slow WRITE entries     : $SLOW_COUNT"
    if (( ANOMALY_COUNT > 0 )); then
        echo "  status                 : ✅ storm captured"
    else
        echo "  status                 : ⚠️  no storm in window — try longer --threshold or more aggressive tuning"
    fi
    echo
    if (( ANOMALY_COUNT > 0 )); then
        echo "First ANOMALY DETECTED block:"
        grep -A 4 "ANOMALY DETECTED" "$PROBE_LOG" | head -20
        echo
        echo "Sample slow operations around the anomaly:"
        grep -B 1 -A 8 "ANOMALY DETECTED" "$PROBE_LOG" | head -40
    fi
    echo
    echo "Output files:"
    echo "  $PROBE_LOG  ($(wc -l < "$PROBE_LOG") lines)"
    echo "  $CASE_LOG"
    echo "════════════════════════════════════════════════════════════════"
} > "$REPORT"

log "report written to $REPORT"
log "===== case-2 complete ====="
