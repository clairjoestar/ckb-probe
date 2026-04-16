#!/usr/bin/env bash
#
# p1-cpu.sh — measure CKB process CPU% over a window for the P-1 constraint:
#   附加 CPU 使用率 ≤ 3% (1h-window mean %CPU diff with vs without ckb-probe).
#
# Usage:
#   ./p1-cpu.sh baseline   [duration_seconds] [interval_seconds]
#   ./p1-cpu.sh with-probe [duration_seconds] [interval_seconds]
#   ./p1-cpu.sh compare
#
# Workflow:
#   1) Run on bare CKB (no ckb-probe attached):
#        ./p1-cpu.sh baseline
#   2) Start ckb-probe rocksdb in another terminal, then run:
#        ./p1-cpu.sh with-probe
#   3) Diff:
#        ./p1-cpu.sh compare
#
# Defaults: duration=3600s (1h), interval=10s
#
# Output files (in /tmp):
#   p1-cpu-baseline.log    raw pidstat output
#   p1-cpu-with-probe.log  raw pidstat output

set -euo pipefail

DURATION="${2:-3600}"
INTERVAL="${3:-10}"
SAMPLES=$((DURATION / INTERVAL))
LOG_DIR="/tmp"

require_pidstat() {
    if ! command -v pidstat >/dev/null 2>&1; then
        echo "ERROR: pidstat not installed. Install with: sudo apt-get install sysstat" >&2
        exit 1
    fi
}

find_ckb_pid() {
    local pid
    pid=$(pgrep -x ckb | head -n 1 || true)
    if [[ -z "$pid" ]]; then
        echo "ERROR: no running ckb process found (pgrep -x ckb returned nothing)" >&2
        exit 1
    fi
    echo "$pid"
}

run_sample() {
    local label="$1"
    local logfile="$LOG_DIR/p1-cpu-${label}.log"
    require_pidstat
    local pid
    pid=$(find_ckb_pid)
    echo "[p1-cpu] label=$label pid=$pid duration=${DURATION}s interval=${INTERVAL}s samples=$SAMPLES"
    echo "[p1-cpu] writing to $logfile"
    # -u CPU stats, -h human header, -p PID
    pidstat -u -h -p "$pid" "$INTERVAL" "$SAMPLES" > "$logfile"
    echo "[p1-cpu] done."
    summarise "$logfile"
}

summarise() {
    local logfile="$1"
    # pidstat -h emits: #      Time   UID       PID    %usr %system  %guest   %wait    %CPU   CPU  Command
    # Skip header lines starting with '#' and the first line.
    awk '
        /^#/ { next }
        NF >= 9 {
            sum_cpu += $8
            n++
        }
        END {
            if (n == 0) { print "[p1-cpu] no samples found in", FILENAME; exit 1 }
            printf "[p1-cpu] %s -> samples=%d  mean %%CPU=%.3f\n", FILENAME, n, sum_cpu / n
        }
    ' "$logfile"
}

cmd_compare() {
    local base="$LOG_DIR/p1-cpu-baseline.log"
    local with="$LOG_DIR/p1-cpu-with-probe.log"
    if [[ ! -f "$base" || ! -f "$with" ]]; then
        echo "ERROR: missing one of $base / $with — run baseline and with-probe first." >&2
        exit 1
    fi
    local b w diff
    b=$(awk '/^#/ {next} NF>=9 {s+=$8; n++} END {printf "%.3f", s/n}' "$base")
    w=$(awk '/^#/ {next} NF>=9 {s+=$8; n++} END {printf "%.3f", s/n}' "$with")
    diff=$(awk -v a="$b" -v c="$w" 'BEGIN {printf "%.3f", c - a}')
    echo
    echo "===== P-1 result ====="
    echo "  baseline mean %CPU      : $b"
    echo "  with-probe mean %CPU    : $w"
    echo "  delta (with - baseline) : $diff"
    echo "  P-1 budget              : <= 3.000"
    awk -v d="$diff" 'BEGIN {
        if (d <= 3.0)  { print "  status                  : ✅ within budget" }
        else           { print "  status                  : ❌ EXCEEDS budget" }
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
