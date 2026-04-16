#!/usr/bin/env bash
#
# perf-run-orchestrator.sh — full P-1 ~ P-4 measurement per main_proj.md spec.
#
# Phase A (2h, ckb-probe rocksdb attached):
#   - P-1 with-probe: pidstat CKB %CPU every 5s for 7200s
#   - P-2:            VmRSS poller for ckb-probe every 5s for 7200s
#   - P-3:            ckb-probe rocksdb --slow --threshold 1000footer log
#   - P-4 with-probe: CKB tip via JSON-RPC every 60s for 120 samples
#
# Phase B (2h, no probe — baseline):
#   - P-1 baseline:   pidstat CKB %CPU every 5s for 7200s
#   - P-4 baseline:   CKB tip via JSON-RPC every 60s for 120 samples
#
# Phase C: compute verdicts and write REPORT.txt
#
# Total wall time: ~4 hours.

set -uo pipefail

# ════════════════════════════════════════════════════════════════════
# Config
# ════════════════════════════════════════════════════════════════════
CKB_PID=$(pgrep -x ckb | head -1)
if [[ -z "$CKB_PID" ]]; then
    echo "FATAL: no running CKB process found" >&2
    exit 1
fi
CKB_BINARY="${CKB_BIN:-/root/ckb}"
CKB_RPC="${CKB_RPC:-http://127.0.0.1:8124}"
PROBE_BIN="${PROBE_BIN:-/root/ckb-probe/target/release/ckb-probe}"

WORK="${OUTPUT_DIR:-/tmp/perf-run}"
PHASE_A_SECS=7200       # 2h
PHASE_B_SECS=7200       # 2h
SAMPLE_SECS=5           # CPU + RSS sample interval
TIP_SECS=60             # P-4 sample interval
TIP_SAMPLES=120         # 60s × 120 = 2h
PHASE_A_CPU_SAMPLES=$((PHASE_A_SECS / SAMPLE_SECS))   # 1440
PHASE_B_CPU_SAMPLES=$((PHASE_B_SECS / SAMPLE_SECS))   # 1440

P1_BUDGET_PCT=3.0
P2_BUDGET_MB=50
P3_BUDGET_PCT=0.1
P4_BUDGET_PCT=1.0

mkdir -p "$WORK"
PROGRESS=$WORK/progress.log
PROBE_LOG=$WORK/probe-slow.log
P1_WP_LOG=$WORK/p1-with-probe.log
P1_BL_LOG=$WORK/p1-baseline.log
P2_LOG=$WORK/p2-rss.log
P4_WP_LOG=$WORK/p4-with-probe.log
P4_BL_LOG=$WORK/p4-baseline.log
REPORT=$WORK/REPORT.txt
PIDS_FILE=$WORK/pids

# ════════════════════════════════════════════════════════════════════
# Helpers
# ════════════════════════════════════════════════════════════════════
log() {
    echo "[$(date '+%F %T')] $*" | tee -a "$PROGRESS"
}

fetch_tip() {
    NO_PROXY=127.0.0.1 curl -s -X POST "$CKB_RPC" \
        -H 'Content-Type: application/json' \
        -d '{"id":1,"jsonrpc":"2.0","method":"get_tip_block_number","params":[]}' \
        | jq -r '.result // empty'
}

cleanup() {
    log "cleanup: stopping any background tasks"
    if [[ -f "$PIDS_FILE" ]]; then
        while read -r pid; do
            kill "$pid" 2>/dev/null || true
        done < "$PIDS_FILE"
    fi
    if [[ -n "${PROBE_PID:-}" ]]; then
        kill -INT "$PROBE_PID" 2>/dev/null || true
        sleep 2
        kill -TERM "$PROBE_PID" 2>/dev/null || true
    fi
}
trap cleanup EXIT INT TERM

# ════════════════════════════════════════════════════════════════════
# Sanity
# ════════════════════════════════════════════════════════════════════
log "===== perf-run-orchestrator started ====="
log "WORK=$WORK"
log "CKB pid=$CKB_PID  RPC=$CKB_RPC"
log "Phase A: 2h with-probe   Phase B: 2h baseline   Total: ~4h"

if ! kill -0 "$CKB_PID" 2>/dev/null; then
    log "FATAL: CKB pid $CKB_PID not running"
    exit 1
fi

if ! [[ -x "$PROBE_BIN" ]]; then
    log "FATAL: $PROBE_BIN not found or not executable"
    exit 1
fi

if [[ -z "$(fetch_tip)" ]]; then
    log "FATAL: CKB RPC at $CKB_RPC not responding"
    exit 1
fi

# Make sure no stale ckb-probe is running
if pgrep -x ckb-probe >/dev/null; then
    log "WARN: existing ckb-probe found, killing"
    pkill -x ckb-probe || true
    sleep 2
fi

> "$PIDS_FILE"

# ════════════════════════════════════════════════════════════════════
# Phase A — 2h with ckb-probe attached
# ════════════════════════════════════════════════════════════════════
log "----- Phase A: 2h with-probe -----"
PHASE_A_START=$(date +%s)

# Start ckb-probe with the lowest practical threshold to maximize event rate
# (--threshold 1000→ 1 µs → essentially every RocksDB op becomes a slow event,
# stressing the PerfEventArray for the P-3 budget).
log "starting ckb-probe rocksdb --slow --threshold 1000--interval 5"
nohup "$PROBE_BIN" rocksdb \
    --binary "$CKB_BINARY" --pid "$CKB_PID" \
    --slow --threshold 1000--interval 5 \
    > "$PROBE_LOG" 2>&1 &
PROBE_BG=$!
sleep 4
PROBE_PID=$(pgrep -x ckb-probe | head -n1)
if [[ -z "$PROBE_PID" ]]; then
    log "FATAL: ckb-probe failed to spawn. tail of log:"
    tail -20 "$PROBE_LOG" | tee -a "$PROGRESS"
    exit 1
fi
log "ckb-probe attached, pid=$PROBE_PID"

# P-1 with-probe: pidstat CKB
pidstat -u -h -p "$CKB_PID" "$SAMPLE_SECS" "$PHASE_A_CPU_SAMPLES" > "$P1_WP_LOG" 2>&1 &
P1_BG=$!
echo "$P1_BG" >> "$PIDS_FILE"
log "P-1 with-probe: pidstat bg=$P1_BG samples=$PHASE_A_CPU_SAMPLES"

# P-2: ckb-probe RSS poller
(
    > "$P2_LOG"
    while kill -0 "$PROBE_PID" 2>/dev/null; do
        if [[ -f /proc/$PROBE_PID/status ]]; then
            ts=$(date +%s)
            rss=$(awk '/^VmRSS:/ {print $2}' /proc/$PROBE_PID/status 2>/dev/null || echo 0)
            hwm=$(awk '/^VmHWM:/ {print $2}' /proc/$PROBE_PID/status 2>/dev/null || echo 0)
            echo "$ts $rss $hwm" >> "$P2_LOG"
        fi
        sleep "$SAMPLE_SECS"
    done
) &
P2_BG=$!
echo "$P2_BG" >> "$PIDS_FILE"
log "P-2: RSS poller bg=$P2_BG"

# P-4 with-probe: tip sampler
(
    echo "# unix_ts hex_height dec_height" > "$P4_WP_LOG"
    for ((i = 0; i < TIP_SAMPLES; i++)); do
        ts=$(date +%s)
        h=$(fetch_tip)
        if [[ -n "$h" ]]; then
            d=$(printf '%d' "$h")
            echo "$ts $h $d" >> "$P4_WP_LOG"
        fi
        sleep "$TIP_SECS"
    done
) &
P4_BG=$!
echo "$P4_BG" >> "$PIDS_FILE"
log "P-4 with-probe: tip sampler bg=$P4_BG samples=$TIP_SAMPLES"

# Halftime marker
( sleep $((PHASE_A_SECS / 2)); log "Phase A halftime (1h elapsed)" ) &

# Wait for the longest-running task (pidstat = 7200s)
log "Phase A waiting for measurements to finish..."
wait "$P1_BG" 2>/dev/null
log "Phase A: pidstat done"
wait "$P4_BG" 2>/dev/null
log "Phase A: tip sampler done"
# RSS poller will stop on its own when probe is killed
log "Phase A: stopping ckb-probe"
kill -INT "$PROBE_PID" 2>/dev/null || true
sleep 3
kill -TERM "$PROBE_PID" 2>/dev/null || true
sleep 1
PROBE_PID=""
wait "$P2_BG" 2>/dev/null
log "Phase A: RSS poller done"

PHASE_A_END=$(date +%s)
log "Phase A complete in $((PHASE_A_END - PHASE_A_START))s"

# Cool down a few seconds before baseline phase to let CKB stabilise
sleep 10

# ════════════════════════════════════════════════════════════════════
# Phase B — 2h baseline (no probe)
# ════════════════════════════════════════════════════════════════════
log "----- Phase B: 2h baseline (no probe) -----"
PHASE_B_START=$(date +%s)

# Confirm no probe is running
if pgrep -x ckb-probe >/dev/null; then
    log "WARN: ckb-probe still running, killing"
    pkill -x ckb-probe || true
    sleep 2
fi

# P-1 baseline: pidstat CKB
pidstat -u -h -p "$CKB_PID" "$SAMPLE_SECS" "$PHASE_B_CPU_SAMPLES" > "$P1_BL_LOG" 2>&1 &
P1B_BG=$!
echo "$P1B_BG" >> "$PIDS_FILE"
log "P-1 baseline: pidstat bg=$P1B_BG"

# P-4 baseline: tip sampler
(
    echo "# unix_ts hex_height dec_height" > "$P4_BL_LOG"
    for ((i = 0; i < TIP_SAMPLES; i++)); do
        ts=$(date +%s)
        h=$(fetch_tip)
        if [[ -n "$h" ]]; then
            d=$(printf '%d' "$h")
            echo "$ts $h $d" >> "$P4_BL_LOG"
        fi
        sleep "$TIP_SECS"
    done
) &
P4B_BG=$!
echo "$P4B_BG" >> "$PIDS_FILE"
log "P-4 baseline: tip sampler bg=$P4B_BG"

( sleep $((PHASE_B_SECS / 2)); log "Phase B halftime (1h elapsed)" ) &

wait "$P1B_BG" 2>/dev/null
log "Phase B: pidstat done"
wait "$P4B_BG" 2>/dev/null
log "Phase B: tip sampler done"

PHASE_B_END=$(date +%s)
log "Phase B complete in $((PHASE_B_END - PHASE_B_START))s"

# ════════════════════════════════════════════════════════════════════
# Phase C — compute verdicts
# ════════════════════════════════════════════════════════════════════
log "----- Phase C: computing verdicts -----"

#
# P-1: CKB %CPU diff over a 1h window from each phase.
# Spec says 1h, but we have 2h of data; use the first hour for an apples-to-
# apples comparison. (Mean over the full 2h is also reported.)
#
compute_p1() {
    local logfile="$1" hours="$2"
    local samples_1h=$((3600 / SAMPLE_SECS))
    awk -v limit="$samples_1h" -v hours="$hours" '
        /^#/ { next }
        NF >= 10 {
            n_full++; sum_full += $8
            if (n_1h < limit) { n_1h++; sum_1h += $8 }
        }
        END {
            if (hours == 1) {
                if (n_1h == 0) print "NaN NaN"
                else printf "%.4f %d\n", sum_1h / n_1h, n_1h
            } else {
                if (n_full == 0) print "NaN NaN"
                else printf "%.4f %d\n", sum_full / n_full, n_full
            }
        }
    ' "$logfile"
}

read P1_WP_1H_MEAN P1_WP_1H_N <<< "$(compute_p1 "$P1_WP_LOG" 1)"
read P1_BL_1H_MEAN P1_BL_1H_N <<< "$(compute_p1 "$P1_BL_LOG" 1)"
read P1_WP_2H_MEAN P1_WP_2H_N <<< "$(compute_p1 "$P1_WP_LOG" 2)"
read P1_BL_2H_MEAN P1_BL_2H_N <<< "$(compute_p1 "$P1_BL_LOG" 2)"

P1_DELTA_1H=$(awk -v a="$P1_WP_1H_MEAN" -v b="$P1_BL_1H_MEAN" 'BEGIN {
    if (b == 0 || b == "NaN") printf "NaN"
    else printf "%+.4f", (a - b) / b * 100
}')
P1_DELTA_2H=$(awk -v a="$P1_WP_2H_MEAN" -v b="$P1_BL_2H_MEAN" 'BEGIN {
    if (b == 0 || b == "NaN") printf "NaN"
    else printf "%+.4f", (a - b) / b * 100
}')

#
# P-2: sustained VmRSS — use max VmRSS over the 2h, ignore VmHWM for verdict.
#
P2_STATS=$(awk '
    NF == 3 {
        sum += $2; n++;
        if ($2 > max_rss) max_rss = $2;
        if ($3 > max_hwm) max_hwm = $3;
    }
    END {
        if (n == 0) { print "NaN NaN NaN NaN"; exit }
        printf "%.4f %.4f %.4f %d\n", sum/n/1024, max_rss/1024, max_hwm/1024, n
    }
' "$P2_LOG")
read P2_MEAN_MB P2_MAX_MB P2_HWM_MB P2_N <<< "$P2_STATS"

#
# P-3: from probe log footer — extract last "BPF event loss" line
#
P3_LINE=$(grep -a "BPF event loss" "$PROBE_LOG" | tail -1 || echo "")
if [[ -n "$P3_LINE" ]]; then
    P3_LOST=$(echo "$P3_LINE" | grep -oP '^\s*BPF event loss: \K\d+')
    P3_TOTAL=$(echo "$P3_LINE" | grep -oP '\d+(?= attempted)')
    P3_PCT=$(echo "$P3_LINE" | grep -oP '\(\K[0-9.]+(?=%)')
    P3_RATE=$(awk -v t="$P3_TOTAL" -v s="$PHASE_A_SECS" 'BEGIN {printf "%.0f", t/s}')
else
    P3_LOST="?"
    P3_TOTAL="?"
    P3_PCT="?"
    P3_RATE="?"
fi

#
# P-4: blocks/min over the full 2h sample window from each phase.
#
compute_p4() {
    local logfile="$1"
    awk '
        /^#/ { next }
        NF == 3 {
            if (n == 0) { ft = $1; fh = $3 }
            lt = $1; lh = $3; n++
        }
        END {
            if (n < 2) { print "NaN NaN NaN"; exit }
            dur_min = (lt - ft) / 60.0
            blocks  = lh - fh
            printf "%.4f %d %.2f\n", blocks / dur_min, blocks, dur_min
        }
    ' "$logfile"
}

read P4_WP_BPM P4_WP_BLOCKS P4_WP_DUR <<< "$(compute_p4 "$P4_WP_LOG")"
read P4_BL_BPM P4_BL_BLOCKS P4_BL_DUR <<< "$(compute_p4 "$P4_BL_LOG")"

P4_DEGRAD_PCT=$(awk -v a="$P4_BL_BPM" -v b="$P4_WP_BPM" 'BEGIN {
    if (a == 0 || a == "NaN") { print "NaN" }
    else { printf "%+.4f", (a - b) / a * 100.0 }
}')

# ════════════════════════════════════════════════════════════════════
# Write REPORT
# ════════════════════════════════════════════════════════════════════
{
    echo "════════════════════════════════════════════════════════════════════════════════"
    echo "  ckb-probe rocksdb · 4-hour P-1 ~ P-4 performance overhead report"
    echo "  Generated: $(date '+%F %T')"
    echo "════════════════════════════════════════════════════════════════════════════════"
    echo
    echo "Test setup"
    echo "  target CKB pid     : $CKB_PID  ($CKB_BINARY)"
    echo "  CKB JSON-RPC       : $CKB_RPC"
    echo "  probe binary       : $PROBE_BIN"
    echo "  probe args         : rocksdb --slow --threshold 1000--interval 5"
    echo "  phase A duration   : ${PHASE_A_SECS}s with ckb-probe attached"
    echo "  phase B duration   : ${PHASE_B_SECS}s baseline (no probe)"
    echo "  CPU sample rate    : every ${SAMPLE_SECS}s ($((PHASE_A_CPU_SAMPLES)) samples per phase)"
    echo "  RSS sample rate    : every ${SAMPLE_SECS}s"
    echo "  P-4 sample rate    : every ${TIP_SECS}s × $TIP_SAMPLES samples per phase (= ${PHASE_A_SECS}s)"
    echo "  Per main_proj.md   : testnet only, never mainnet"
    echo
    echo "────────────────────────────────────────────────────────────────────────────────"
    echo "  P-1   附加 CPU 使用率 ≤ 3% (1h window)"
    echo "────────────────────────────────────────────────────────────────────────────────"
    printf "  baseline %%CPU mean (1h)   : %s   (n=%s samples)\n" "$P1_BL_1H_MEAN" "$P1_BL_1H_N"
    printf "  with-probe %%CPU mean (1h) : %s   (n=%s samples)\n" "$P1_WP_1H_MEAN" "$P1_WP_1H_N"
    printf "  relative delta            : %s%%\n" "$P1_DELTA_1H"
    printf "  P-1 budget                : ≤ +%.1f%%\n" "$P1_BUDGET_PCT"
    awk -v d="$P1_DELTA_1H" -v b="$P1_BUDGET_PCT" 'BEGIN {
        if (d <= b) print "  status                    : ✅ PASS"
        else        print "  status                    : ❌ FAIL"
    }'
    echo
    printf "  (full 2h reference: baseline=%s  with-probe=%s  delta=%s)\n" \
        "$P1_BL_2H_MEAN" "$P1_WP_2H_MEAN" "$P1_DELTA_2H"
    echo
    echo "────────────────────────────────────────────────────────────────────────────────"
    echo "  P-2   ckb-probe RSS ≤ 50 MB (持续监控状态, 2h)"
    echo "────────────────────────────────────────────────────────────────────────────────"
    printf "  samples                   : %s\n" "$P2_N"
    printf "  mean VmRSS                : %s MB    (sustained — what P-2 measures)\n" "$P2_MEAN_MB"
    printf "  max  VmRSS                : %s MB    (sustained — what P-2 measures)\n" "$P2_MAX_MB"
    printf "  peak VmHWM                : %s MB    (one-shot — info only, BPF map setup)\n" "$P2_HWM_MB"
    printf "  P-2 budget                : ≤ %d MB sustained\n" "$P2_BUDGET_MB"
    awk -v m="$P2_MAX_MB" -v b="$P2_BUDGET_MB" 'BEGIN {
        if (m <= b) print "  status                    : ✅ PASS"
        else        print "  status                    : ❌ FAIL"
    }'
    echo
    echo "────────────────────────────────────────────────────────────────────────────────"
    echo "  P-3   BPF 事件丢失率 < 0.1% (10K events/sec sustained per spec)"
    echo "────────────────────────────────────────────────────────────────────────────────"
    printf "  total events attempted    : %s\n" "$P3_TOTAL"
    printf "  events lost               : %s\n" "$P3_LOST"
    printf "  loss rate                 : %s%%\n" "$P3_PCT"
    printf "  achieved event rate       : %s events/sec  (over %ss)\n" "$P3_RATE" "$PHASE_A_SECS"
    printf "  P-3 budget                : < %.1f%% loss\n" "$P3_BUDGET_PCT"
    if [[ "$P3_PCT" != "?" ]]; then
        awk -v p="$P3_PCT" -v b="$P3_BUDGET_PCT" 'BEGIN {
            if (p < b) print "  status                    : ✅ PASS"
            else       print "  status                    : ❌ FAIL"
        }'
        if [[ "$P3_RATE" != "?" ]] && (( P3_RATE < 10000 )); then
            echo "  caveat                    : 实测速率 $P3_RATE/s < spec 目标 10000/s,"
            echo "                              因为同步到 tip 后稳态 RocksDB 操作密度有限."
            echo "                              要触达 10K/s 需要 IBD 阶段或 RPC 风暴."
        fi
    else
        echo "  status                    : ⚠️  no P-3 data (probe log parse failed)"
    fi
    echo
    echo "────────────────────────────────────────────────────────────────────────────────"
    echo "  P-4   CKB 同步速度退化 < 1% (2h IBD window)"
    echo "────────────────────────────────────────────────────────────────────────────────"
    printf "  baseline blocks/min       : %s   (%s blocks over %s min)\n" "$P4_BL_BPM" "$P4_BL_BLOCKS" "$P4_BL_DUR"
    printf "  with-probe blocks/min     : %s   (%s blocks over %s min)\n" "$P4_WP_BPM" "$P4_WP_BLOCKS" "$P4_WP_DUR"
    printf "  degradation               : %s%%\n" "$P4_DEGRAD_PCT"
    printf "  P-4 budget                : < %.1f%% degradation\n" "$P4_BUDGET_PCT"
    if [[ "$P4_DEGRAD_PCT" != "NaN" ]]; then
        awk -v d="$P4_DEGRAD_PCT" -v b="$P4_BUDGET_PCT" 'BEGIN {
            if (d <= b) print "  status                    : ✅ PASS"
            else        print "  status                    : ❌ FAIL"
        }'
    else
        echo "  status                    : ⚠️  insufficient data"
    fi
    echo "  caveat                    : 节点已接近 tip,非真正 IBD 阶段;"
    echo "                              spec 的 IBD 窗口要从 snapshot 启动才能严格复现."
    echo
    echo "════════════════════════════════════════════════════════════════════════════════"
    echo "  raw data files (in $WORK):"
    echo "    $P1_WP_LOG     ($(wc -l < "$P1_WP_LOG" 2>/dev/null || echo 0) lines)"
    echo "    $P1_BL_LOG     ($(wc -l < "$P1_BL_LOG" 2>/dev/null || echo 0) lines)"
    echo "    $P2_LOG        ($(wc -l < "$P2_LOG" 2>/dev/null || echo 0) lines)"
    echo "    $PROBE_LOG     ($(wc -l < "$PROBE_LOG" 2>/dev/null || echo 0) lines)"
    echo "    $P4_WP_LOG     ($(wc -l < "$P4_WP_LOG" 2>/dev/null || echo 0) lines)"
    echo "    $P4_BL_LOG     ($(wc -l < "$P4_BL_LOG" 2>/dev/null || echo 0) lines)"
    echo "════════════════════════════════════════════════════════════════════════════════"
} > "$REPORT"

log "Report written to $REPORT"
log "===== perf-run-orchestrator finished ====="
