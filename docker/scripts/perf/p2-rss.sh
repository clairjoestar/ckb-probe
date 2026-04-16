#!/usr/bin/env bash
#
# p2-rss.sh — continuously monitor ckb-probe RSS for the P-2 constraint:
#   ckb-probe 进程 RSS 内存使用 ≤ 50 MB (持续监控状态).
#
# Usage:
#   ./p2-rss.sh [interval_seconds] [log_file]
#
# Defaults: interval=5, log_file=/tmp/p2-rss.log
#
# The script auto-detects the ckb-probe PID via pgrep -x. If multiple instances
# are running it picks the first; pass --pid <PID> to override:
#   ./p2-rss.sh --pid 12345 [interval] [log_file]
#
# Output columns: timestamp, vmrss_kb, vmrss_mb, peak_kb, peak_mb
#
# When the script exits (Ctrl+C or process death), it prints a summary with
# mean / max RSS and the P-2 verdict.

set -euo pipefail

PROBE_PID=""
if [[ "${1:-}" == "--pid" ]]; then
    PROBE_PID="$2"
    shift 2
fi

INTERVAL="${1:-5}"
LOG="${2:-/tmp/p2-rss.log}"
P2_BUDGET_MB=50

if [[ -z "$PROBE_PID" ]]; then
    PROBE_PID=$(pgrep -x ckb-probe | head -n 1 || true)
    if [[ -z "$PROBE_PID" ]]; then
        echo "ERROR: no running ckb-probe process found." >&2
        echo "       Start one (e.g. sudo ckb-probe rocksdb --binary ./ckb --pid \$(pgrep -x ckb))" >&2
        echo "       in another terminal first, or pass --pid <PID>." >&2
        exit 1
    fi
fi

if [[ ! -d "/proc/$PROBE_PID" ]]; then
    echo "ERROR: /proc/$PROBE_PID does not exist (process gone?)" >&2
    exit 1
fi

echo "[p2-rss] watching pid=$PROBE_PID  interval=${INTERVAL}s  log=$LOG"
echo "[p2-rss] Ctrl+C to stop and print summary."
echo "# timestamp vmrss_kb vmrss_mb peak_kb peak_mb" > "$LOG"

cleanup() {
    echo
    echo "===== P-2 result ====="
    awk -v budget="$P2_BUDGET_MB" '
        /^#/ { next }
        NF >= 5 {
            sum += $3
            n++
            if ($3 > max) max = $3
            if ($5 > peak) peak = $5
        }
        END {
            if (n == 0) { print "  no samples"; exit 1 }
            printf "  samples            : %d\n", n
            printf "  mean VmRSS (MB)    : %.2f  (sustained — what P-2 measures)\n", sum / n
            printf "  max  VmRSS (MB)    : %.2f  (sustained — what P-2 measures)\n", max
            printf "  peak VmHWM (MB)    : %.2f  (one-shot — info only, e.g. BPF map setup)\n", peak
            printf "  P-2 budget         : <= %d MB (持续监控状态)\n", budget
            # Per main_proj.md, P-2 measures sustained monitoring state, so the
            # verdict only checks max VmRSS. VmHWM (high-water mark since process
            # start) routinely captures the brief allocation spike when aya loads
            # the BPF program and maps the per-CPU arrays — that page set is then
            # released and is NOT representative of steady-state RSS.
            if (max <= budget) {
                print "  status             : ✅ within budget (sustained)"
            } else {
                print "  status             : ❌ EXCEEDS budget (sustained)"
            }
        }
    ' "$LOG"
}
trap cleanup EXIT

while kill -0 "$PROBE_PID" 2>/dev/null; do
    # VmRSS is current resident set size, VmHWM is the high-water mark since start
    rss_kb=$(awk '/^VmRSS:/ {print $2}' "/proc/$PROBE_PID/status" 2>/dev/null || echo 0)
    hwm_kb=$(awk '/^VmHWM:/ {print $2}' "/proc/$PROBE_PID/status" 2>/dev/null || echo 0)
    rss_mb=$(awk -v k="$rss_kb" 'BEGIN {printf "%.2f", k/1024}')
    hwm_mb=$(awk -v k="$hwm_kb" 'BEGIN {printf "%.2f", k/1024}')
    ts=$(date +%H:%M:%S)
    echo "$ts $rss_kb $rss_mb $hwm_kb $hwm_mb" | tee -a "$LOG"
    sleep "$INTERVAL"
done
