#!/usr/bin/env bash
#
# p4-sync.sh — sample CKB tip block height for the P-4 constraint:
#   CKB 区块同步速度退化 < 1% (2h IBD-window blocks/min, with vs without ckb-probe).
#
# Usage:
#   ./p4-sync.sh baseline   [duration_minutes] [rpc_url]
#   ./p4-sync.sh with-probe [duration_minutes] [rpc_url]
#   ./p4-sync.sh compare
#
# Workflow:
#   1) Start a CKB testnet node from a snapshot at a known height.
#   2) Without ckb-probe attached, run:
#        ./p4-sync.sh baseline
#      Wait for 2h. Save the resulting log.
#   3) Restore the snapshot, restart CKB, attach ckb-probe rocksdb, then run:
#        ./p4-sync.sh with-probe
#   4) Diff:
#        ./p4-sync.sh compare
#
# IMPORTANT: both runs MUST start from the same CKB DB snapshot. IBD speed
# varies wildly with starting height, so a fair A/B test requires identical
# initial state. Per main_proj.md: testnet only, never mainnet.
#
# Defaults: duration=120 minutes (2h), rpc_url=http://127.0.0.1:8114
#
# Output files (in /tmp):
#   p4-sync-baseline.log    timestamp height (raw)
#   p4-sync-with-probe.log  timestamp height (raw)

set -euo pipefail

DURATION_MIN="${2:-120}"
RPC_URL="${3:-http://127.0.0.1:8114}"
LOG_DIR="/tmp"
P4_BUDGET_PCT=1.0

require_curl_jq() {
    for tool in curl jq; do
        if ! command -v "$tool" >/dev/null 2>&1; then
            echo "ERROR: $tool not installed." >&2
            exit 1
        fi
    done
}

fetch_tip() {
    # CKB JSON-RPC returns tip as a hex-encoded string (e.g. "0x1a2b3c").
    local hex
    hex=$(curl -s -X POST "$RPC_URL" \
        -H 'Content-Type: application/json' \
        -d '{"id":1,"jsonrpc":"2.0","method":"get_tip_block_number","params":[]}' \
        | jq -r '.result // empty')
    if [[ -z "$hex" || "$hex" == "null" ]]; then
        echo "ERROR: empty response from $RPC_URL (is the node up?)" >&2
        return 1
    fi
    # Convert 0x.. -> decimal
    printf '%d\n' "$hex"
}

run_sample() {
    local label="$1"
    local logfile="$LOG_DIR/p4-sync-${label}.log"
    require_curl_jq
    echo "[p4-sync] label=$label  duration=${DURATION_MIN} min  rpc=$RPC_URL"
    echo "[p4-sync] writing to $logfile"
    # Header
    echo "# unix_ts  height" > "$logfile"
    local i
    for ((i = 0; i < DURATION_MIN; i++)); do
        local h
        h=$(fetch_tip) || { echo "[p4-sync] aborting"; exit 1; }
        local ts
        ts=$(date +%s)
        echo "$ts $h" | tee -a "$logfile"
        sleep 60
    done
    summarise "$logfile"
}

summarise() {
    local logfile="$1"
    awk '
        /^#/ { next }
        NF == 2 {
            if (n == 0) { first_t = $1; first_h = $2 }
            last_t = $1; last_h = $2
            n++
        }
        END {
            if (n < 2) {
                print "[p4-sync] not enough samples"
                exit 1
            }
            dur_min = (last_t - first_t) / 60.0
            blocks  = last_h - first_h
            bpm     = blocks / dur_min
            printf "[p4-sync] samples=%d  duration=%.1f min  blocks=%d  blocks/min=%.3f\n", \
                n, dur_min, blocks, bpm
        }
    ' "$logfile"
}

cmd_compare() {
    local base="$LOG_DIR/p4-sync-baseline.log"
    local with="$LOG_DIR/p4-sync-with-probe.log"
    if [[ ! -f "$base" || ! -f "$with" ]]; then
        echo "ERROR: missing one of $base / $with — run baseline and with-probe first." >&2
        exit 1
    fi
    local b w
    b=$(awk '/^#/ {next} NF==2 {if (n==0) {ft=$1; fh=$2} lt=$1; lh=$2; n++} END {printf "%.4f", (lh-fh) / ((lt-ft)/60.0)}' "$base")
    w=$(awk '/^#/ {next} NF==2 {if (n==0) {ft=$1; fh=$2} lt=$1; lh=$2; n++} END {printf "%.4f", (lh-fh) / ((lt-ft)/60.0)}' "$with")
    local degr_pct
    degr_pct=$(awk -v a="$b" -v c="$w" 'BEGIN { if (a == 0) {print "NaN"; exit} printf "%.4f", (a - c) / a * 100.0 }')

    echo
    echo "===== P-4 result ====="
    echo "  baseline blocks/min      : $b"
    echo "  with-probe blocks/min    : $w"
    echo "  degradation (%)          : $degr_pct"
    printf "  P-4 budget               : <= %.1f%%\n" "$P4_BUDGET_PCT"
    awk -v d="$degr_pct" -v budget="$P4_BUDGET_PCT" 'BEGIN {
        if (d == "NaN") { print "  status                   : ⚠️  baseline rate was 0"; exit }
        if (d <= budget)  { print "  status                   : ✅ within budget" }
        else              { print "  status                   : ❌ EXCEEDS budget" }
    }'
}

case "${1:-}" in
    baseline)   run_sample baseline ;;
    with-probe) run_sample with-probe ;;
    compare)    cmd_compare ;;
    *)
        sed -n '3,30p' "$0"
        exit 1
        ;;
esac
