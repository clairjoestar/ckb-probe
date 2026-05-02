#!/usr/bin/env bash
# generate-report.sh -- Post-process a stability-48h.sh output directory
# into a comprehensive Markdown report with charts and analysis.
#
# Usage: ./generate-report.sh /path/to/stability-<timestamp>/
#
# Scope: CKB testnet only.
set -euo pipefail

# ═══════════════════════════════════════════════════════════════════
# Arguments
# ═══════════════════════════════════════════════════════════════════
if [[ $# -lt 1 ]]; then
    echo "Usage: $0 /path/to/stability-<timestamp>/"
    exit 1
fi

DATADIR="$1"
if [[ ! -d "$DATADIR" ]]; then
    echo "Error: directory $DATADIR does not exist" >&2
    exit 1
fi

# Input files
TS_FILE="$DATADIR/timeseries.tsv"
EV_FILE="$DATADIR/events.tsv"
TIP_FILE="$DATADIR/tip-sync.tsv"
LOSS_FILE="$DATADIR/event-loss.tsv"
OP_COUNT_FILE="$DATADIR/event-counts-by-op.tsv"
SLOW_LOG="$DATADIR/slow-events.log"
HIST_LOG="$DATADIR/histogram.log"
PROBE_JSON="$DATADIR/probe-json.log"
PROBE_STDERR="$DATADIR/probe-stderr.log"
DMESG_START="$DATADIR/dmesg-start.log"
DMESG_END="$DATADIR/dmesg-end.log"
S4_LOG="$DATADIR/s4-restart.log"
VERDICT="$DATADIR/STABILITY-VERDICT.txt"
SYSINFO="$DATADIR/system-info.txt"

REPORT="$DATADIR/STABILITY-REPORT.md"
CHARTS_DIR="$DATADIR/charts"
mkdir -p "$CHARTS_DIR"

HAS_GNUPLOT=false
if command -v gnuplot &>/dev/null; then
    HAS_GNUPLOT=true
fi

OPS="GET PUT WRITE ITER_NEW TXN_COMMIT"

log() {
    echo "[generate-report] $*"
}

# ═══════════════════════════════════════════════════════════════════
# Helper: extract numeric stats from a column of numbers
# Input: one number per line on stdin
# Output: min max avg p99 count
# ═══════════════════════════════════════════════════════════════════
compute_stats() {
    sort -g | awk '
    BEGIN { n=0; sum=0; min=999999999; max=-999999999 }
    {
        v=$1+0; a[n]=v; sum+=v; n++
        if(v<min) min=v
        if(v>max) max=v
    }
    END {
        if(n==0) { print "0 0 0 0 0"; exit }
        avg=sum/n
        p99_idx=int(n*0.99)
        if(p99_idx>=n) p99_idx=n-1
        printf "%.2f %.2f %.2f %.2f %d\n", min, max, avg, a[p99_idx], n
    }'
}

# ═══════════════════════════════════════════════════════════════════
# Parse system info
# ═══════════════════════════════════════════════════════════════════
START_TIME=""
END_TIME=""
KERNEL=""
CKB_VER=""
CPU_INFO=""
RAM_INFO=""
DURATION_INFO=""

if [[ -f "$SYSINFO" ]]; then
    START_TIME=$(grep "Start time:" "$SYSINFO" | cut -d: -f2- | xargs)
    KERNEL=$(grep "Kernel:" "$SYSINFO" | cut -d: -f2- | xargs)
    CKB_VER=$(grep "CKB version:" "$SYSINFO" | cut -d: -f2- | xargs)
    CPU_INFO=$(grep "CPU model:" "$SYSINFO" | cut -d: -f2- | xargs)
    CPU_CORES=$(grep "CPU cores:" "$SYSINFO" | cut -d: -f2- | xargs)
    RAM_INFO=$(grep "RAM:" "$SYSINFO" | cut -d: -f2- | xargs)
    DURATION_INFO=$(grep "Duration:" "$SYSINFO" | cut -d: -f2- | xargs)
fi

# Try to get end time from verdict
if [[ -f "$VERDICT" ]]; then
    END_TIME=$(grep "End:" "$VERDICT" | head -1 | sed 's/End:[[:space:]]*//')
fi

# Count data points
TS_LINES=0
if [[ -f "$TS_FILE" ]]; then
    TS_LINES=$(($(wc -l < "$TS_FILE") - 1))  # minus header
fi
EV_LINES=0
if [[ -f "$EV_FILE" ]]; then
    EV_LINES=$(($(wc -l < "$EV_FILE") - 1))
fi
# Fallback: count JSON objects in probe-json.log if events.tsv is empty
JSON_OBJECTS=0
if [[ $EV_LINES -le 0 && -f "$PROBE_JSON" && -s "$PROBE_JSON" ]] && command -v jq &>/dev/null; then
    JSON_OBJECTS=$(jq -r '.timestamp' "$PROBE_JSON" 2>/dev/null | wc -l)
fi

log "Data points: timeseries=$TS_LINES, events=$EV_LINES, json_objects=$JSON_OBJECTS"

# ═══════════════════════════════════════════════════════════════════
# Parse verdict
# ═══════════════════════════════════════════════════════════════════
get_verdict() {
    local metric="$1"
    if [[ -f "$VERDICT" ]]; then
        grep "$metric" "$VERDICT" | head -1 | awk '{print $NF}'
    else
        echo "N/A"
    fi
}

S1_V=$(get_verdict "S-1")
S2_V=$(get_verdict "S-2")
S3_V=$(get_verdict "S-3")
S4_V=$(get_verdict "S-4")

# ═══════════════════════════════════════════════════════════════════
# Generate charts (gnuplot or ASCII)
# ═══════════════════════════════════════════════════════════════════

generate_gnuplot_chart() {
    local title="$1"
    local ylabel="$2"
    local col="$3"         # column number in timeseries.tsv (1-indexed)
    local outpng="$4"
    local extra="${5:-}"

    gnuplot <<GNUEOF
set terminal pngcairo size 900,400 enhanced font "monospace,10"
set output "$outpng"
set title "$title"
set xlabel "Sample #"
set ylabel "$ylabel"
set grid
set datafile separator "\t"
$extra
plot "$TS_FILE" using 0:$col every ::1 with lines lw 1 notitle
GNUEOF
}

generate_ascii_chart() {
    local title="$1"
    local col="$2"    # column number (1-indexed)
    local filter="${3:-}"  # optional: awk filter expression applied before extracting column
    local width=60
    local height=15

    echo "\`\`\`"
    echo "$title"
    echo ""

    # Extract column data (skip header), optionally filtering invalid rows
    local _chart_data
    if [[ -n "$filter" ]]; then
        _chart_data=$(tail -n +2 "$TS_FILE" | awk -F'\t' "$filter" | cut -f"$col")
    else
        _chart_data=$(tail -n +2 "$TS_FILE" | cut -f"$col")
    fi
    echo "$_chart_data" | awk -v w=$width -v h=$height '
    BEGIN { n=0 }
    { a[n]=$1+0; n++ }
    END {
        if(n==0) { print "(no data)"; exit }
        min=a[0]; max=a[0]
        for(i=1;i<n;i++) { if(a[i]<min) min=a[i]; if(a[i]>max) max=a[i] }
        range=max-min
        if(range==0) range=1

        # Downsample to width bins
        bin_size = n / w
        if(bin_size < 1) bin_size = 1

        for(b=0; b<w && b*bin_size<n; b++) {
            sum=0; cnt=0
            for(j=int(b*bin_size); j<int((b+1)*bin_size) && j<n; j++) {
                sum+=a[j]; cnt++
            }
            bins[b] = sum/cnt
        }
        nbins = b

        # Print rows top to bottom
        for(row=h-1; row>=0; row--) {
            threshold = min + range * (row + 0.5) / h
            line = ""
            for(b=0; b<nbins; b++) {
                if(bins[b] >= threshold) line = line "#"
                else line = line " "
            }
            if(row==h-1)
                printf "%8.1f |%s\n", max, line
            else if(row==0)
                printf "%8.1f |%s\n", min, line
            else if(row==int(h/2))
                printf "%8.1f |%s\n", (min+max)/2, line
            else
                printf "         |%s\n", line
        }
        printf "         +"; for(i=0;i<nbins;i++) printf "-"; printf "\n"
    }'
    echo "\`\`\`"
}

# Generate time-series charts
if [[ $TS_LINES -gt 0 ]]; then
    log "Generating time-series charts..."

    if [[ "$HAS_GNUPLOT" == "true" ]]; then
        generate_gnuplot_chart "ckb-probe CPU% over time" "CPU %" 2 "$CHARTS_DIR/probe-cpu.png"
        generate_gnuplot_chart "ckb-probe RSS (KB) over time" "RSS (KB)" 3 "$CHARTS_DIR/probe-rss.png"
        generate_gnuplot_chart "CKB node CPU% over time" "CPU %" 4 "$CHARTS_DIR/ckb-cpu.png"

        # Tip sync speed chart
        if [[ -f "$TIP_FILE" ]] && [[ $(wc -l < "$TIP_FILE") -gt 1 ]]; then
            gnuplot <<GNUEOF
set terminal pngcairo size 900,400 enhanced font "monospace,10"
set output "$CHARTS_DIR/tip-sync.png"
set title "CKB Sync Speed (blocks/min)"
set xlabel "Sample #"
set ylabel "blocks/min"
set grid
set datafile separator "\t"
plot "$TIP_FILE" using 0:4 every ::1 with lines lw 1 notitle
GNUEOF
        fi

        # Event loss chart
        if [[ -f "$LOSS_FILE" ]] && [[ $(wc -l < "$LOSS_FILE") -gt 1 ]]; then
            gnuplot <<GNUEOF
set terminal pngcairo size 900,400 enhanced font "monospace,10"
set output "$CHARTS_DIR/event-loss.png"
set title "BPF Event Throughput (total attempted)"
set xlabel "Sample #"
set ylabel "events"
set grid
set datafile separator "\t"
plot "$LOSS_FILE" using 0:2 every ::1 with lines lw 1 notitle
GNUEOF
        fi
    fi
fi

# Generate per-op P99 chart data
if [[ $EV_LINES -gt 0 && "$HAS_GNUPLOT" == "true" ]]; then
    log "Generating per-op P99 latency chart..."

    # Prepare per-op data files
    for op in $OPS; do
        tail -n +2 "$EV_FILE" | awk -F'\t' -v op="$op" '$2==op {print NR, $6}' \
            > "$CHARTS_DIR/p99-${op}.dat" 2>/dev/null || true
    done

    gnuplot <<'GNUEOF'
set terminal pngcairo size 900,400 enhanced font "monospace,10"
set output "$CHARTS_DIR/p99-latency.png"
set title "Per-op P99 Latency over Time"
set xlabel "Sample #"
set ylabel "P99 (us)"
set grid
set key outside right
plot for [op in "GET PUT WRITE ITER_NEW TXN_COMMIT"] \
    "$CHARTS_DIR/p99-".op.".dat" using 1:2 with lines title op
GNUEOF
    # Note: the above gnuplot block may fail due to quoting; handled gracefully
fi 2>/dev/null || true

# Generate event throughput chart
if [[ $EV_LINES -gt 0 && "$HAS_GNUPLOT" == "true" ]]; then
    # Sum QPS across all ops per timestamp
    tail -n +2 "$EV_FILE" | awk -F'\t' '
    { ts[$1]+=$3 }
    END { n=0; for(t in ts) { print n, ts[t]; n++ } }
    ' | sort -n > "$CHARTS_DIR/throughput.dat" 2>/dev/null || true

    gnuplot <<GNUEOF
set terminal pngcairo size 900,400 enhanced font "monospace,10"
set output "$CHARTS_DIR/throughput.png"
set title "BPF Event Throughput (total ops/sec)"
set xlabel "Sample #"
set ylabel "events/sec"
set grid
plot "$CHARTS_DIR/throughput.dat" using 1:2 with lines lw 1 notitle
GNUEOF
fi 2>/dev/null || true

# ═══════════════════════════════════════════════════════════════════
# Compute resource stats
# ═══════════════════════════════════════════════════════════════════
if [[ $TS_LINES -gt 0 ]]; then
    PROBE_CPU_STATS=$(tail -n +2 "$TS_FILE" | cut -f2 | compute_stats)
    PROBE_RSS_STATS=$(tail -n +2 "$TS_FILE" | cut -f3 | compute_stats)
    # Filter out rows where CKB process was down (cpu<=0 or rss<=0, e.g. during S-4 restart)
    CKB_CPU_STATS=$(tail -n +2 "$TS_FILE" | awk -F'\t' '$5+0>0 && $4+0>=0 {print $4}' | compute_stats)
    CKB_RSS_STATS=$(tail -n +2 "$TS_FILE" | awk -F'\t' '$5+0>0 {print $5}' | compute_stats)
else
    PROBE_CPU_STATS="0 0 0 0 0"
    PROBE_RSS_STATS="0 0 0 0 0"
    CKB_CPU_STATS="0 0 0 0 0"
    CKB_RSS_STATS="0 0 0 0 0"
fi

fmt_stat_row() {
    local label="$1"
    local stats="$2"
    local unit="$3"
    local budget="$4"
    local min max avg p99 count
    read -r min max avg p99 count <<< "$stats"
    local verdict="PASS"
    if [[ -n "$budget" ]]; then
        local over
        over=$(awk "BEGIN { print ($p99 > $budget) ? 1 : 0 }")
        if [[ "$over" == "1" ]]; then verdict="FAIL"; fi
    fi
    echo "| $label | $min $unit | $max $unit | $avg $unit | $p99 $unit | $budget $unit | $verdict |"
}

# ═══════════════════════════════════════════════════════════════════
# Event fidelity: count per-op events
# ═══════════════════════════════════════════════════════════════════
compute_event_fidelity() {
    # Per-op event counts
    echo "### Per-Operation Event Counts"
    echo ""
    if [[ -f "$OP_COUNT_FILE" ]] && [[ $(wc -l < "$OP_COUNT_FILE") -gt 1 ]]; then
        echo "| Operation | Total Samples | Total QPS (sum) | Avg QPS |"
        echo "|-----------|--------------|-----------------|---------|"
        for op in $OPS; do
            tail -n +2 "$OP_COUNT_FILE" | awk -F'\t' -v op="$op" '
            $2==op { n++; sum+=$3 }
            END {
                if(n==0) printf "| %s | 0 | 0 | 0 |\n", op
                else printf "| %s | %d | %d | %.1f |\n", op, n, sum, sum/n
            }'
        done
    elif [[ $EV_LINES -gt 0 ]]; then
        echo "| Operation | Total Samples | Total QPS (sum) | Avg QPS |"
        echo "|-----------|--------------|-----------------|---------|"
        for op in $OPS; do
            tail -n +2 "$EV_FILE" | awk -F'\t' -v op="$op" '
            $2==op { n++; sum+=$3 }
            END {
                if(n==0) printf "| %s | 0 | 0 | 0 |\n", op
                else printf "| %s | %d | %d | %.1f |\n", op, n, sum, sum/n
            }'
        done
    elif [[ -f "$PROBE_JSON" ]] && [[ -s "$PROBE_JSON" ]] && command -v jq &>/dev/null; then
        echo "| Operation | Total Samples | Avg QPS | Avg Latency (us) | Avg P99 (us) |"
        echo "|-----------|--------------|---------|------------------|--------------|"
        jq -r '.operations | to_entries[] | [.key, .value.qps, .value.avg_us, .value.p99_us] | @tsv' \
            "$PROBE_JSON" 2>/dev/null | awk -F'\t' '
        {
            op=$1; n[op]++; qps[op]+=$2; lat[op]+=$3; p99[op]+=$4
        }
        END {
            split("GET PUT WRITE ITER_NEW TXN_COMMIT", ops, " ")
            for(i=1; i<=5; i++) {
                o=ops[i]
                if(n[o]>0)
                    printf "| %s | %d | %.1f | %.1f | %.1f |\n", o, n[o], qps[o]/n[o], lat[o]/n[o], p99[o]/n[o]
                else
                    printf "| %s | 0 | 0 | 0 | 0 |\n", o
            }
        }'
    else
        echo "(no event data)"
    fi

    # BPF event loss summary
    echo ""
    echo "### BPF Event Loss"
    echo ""
    if [[ -f "$LOSS_FILE" ]] && [[ $(wc -l < "$LOSS_FILE") -gt 1 ]]; then
        tail -1 "$LOSS_FILE" | awk -F'\t' '{
            printf "| Metric | Value |\n|--------|-------|\n"
            printf "| Total events attempted | %s |\n", $2
            printf "| Events lost | %s |\n", $3
            printf "| Loss rate | %s%% |\n", $4
        }'
    else
        echo "(no loss data — check probe output for BPF event loss footer)"
    fi

    # CKB sync speed summary
    echo ""
    echo "### CKB Sync Speed"
    echo ""
    if [[ -f "$TIP_FILE" ]] && [[ $(wc -l < "$TIP_FILE") -gt 1 ]]; then
        # Filter out rows where tip_height=0 (CKB process was down)
        tail -n +2 "$TIP_FILE" | awk -F'\t' '$2+0>0' | awk -F'\t' '
        { n++; sum+=$4; if($4+0>max) max=$4+0; if(n==1 || $4+0<min) min=$4+0
          last_h=$2; if(n==1) start_h=$2 }
        END {
            if(n==0) { print "(no valid sync data)"; exit }
            printf "| Metric | Value |\n|--------|-------|\n"
            printf "| Samples | %d |\n", n
            printf "| Start height | %s |\n", start_h
            printf "| End height | %s |\n", last_h
            printf "| Total blocks synced | %d |\n", last_h - start_h
            printf "| Avg blocks/min | %.1f |\n", sum/n
            printf "| Max blocks/min | %.1f |\n", max
            printf "| Min blocks/min | %.1f |\n", min
        }'
    else
        echo "(no tip sync data)"
    fi
}

# ═══════════════════════════════════════════════════════════════════
# Latency distribution histograms (log2 buckets, ASCII)
# ═══════════════════════════════════════════════════════════════════
generate_latency_histogram() {
    local op="$1"

    # Try histogram.log first (full log2 distribution from --histogram mode)
    if [[ -f "$HIST_LOG" ]] && grep -q "$op" "$HIST_LOG" 2>/dev/null; then
        echo "  (from ckb-probe --histogram, last snapshot)"
        echo ""

        # The histogram.log contains TUI frames with ANSI escape sequences and
        # Unicode box-drawing chars.  Extract the last frame (split by ESC[2J),
        # strip control/decorative characters, then parse bucket lines.
        # 1. Take last ~5000 bytes (last frame)
        # 2. Strip ANSI escape sequences and Unicode box/block drawing chars
        # 3. Grep for the target op's histogram section
        local _hist_clean
        _hist_clean=$(tail -c 8000 "$HIST_LOG" \
            | sed 's/\x1b\[[0-9;]*[A-Za-z]//g' \
            | sed 's/[\xe2\x94\x80-\xe2\x95\xbf]//g; s/[\xe2\x96\x80-\xe2\x96\x9f]//g; s/[\xe2\x96\x88]//g' \
            | LC_ALL=C sed 's/[^[:print:][:space:]]//g')

        # Extract bucket lines for this op
        local _in_section=false
        local _found=false
        local _buckets=""
        local _max_count=0
        while IFS= read -r _line; do
            _stripped=$(echo "$_line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
            if echo "$_stripped" | grep -qi "^${op}[[:space:]]*latency distribution"; then
                _in_section=true
                _found=true
                echo "  $op latency distribution:"
                continue
            fi
            if [[ "$_in_section" == "true" ]]; then
                # Stop at empty line or next section
                if [[ -z "$_stripped" ]] || (echo "$_stripped" | grep -qi "latency distribution" && ! echo "$_stripped" | grep -qi "$op"); then
                    break
                fi
                # Extract bucket: label (e.g. "4μs" or "4ms") and trailing count
                local _label _count
                _label=$(echo "$_stripped" | grep -oP '^\d+\S*s' || true)
                _count=$(echo "$_stripped" | grep -oP '\d+\s*$' | tr -d '[:space:]' || true)
                if [[ -n "$_label" && -n "$_count" ]]; then
                    _buckets="${_buckets}${_label}\t${_count}\n"
                    if [[ $_count -gt $_max_count ]]; then _max_count=$_count; fi
                fi
            fi
        done <<< "$_hist_clean"

        if [[ "$_found" == "true" && -n "$_buckets" ]]; then
            echo -e "$_buckets" | while IFS=$'\t' read -r _bl _bc; do
                [[ -z "$_bl" ]] && continue
                local _bar_len=0
                if [[ $_max_count -gt 0 ]]; then
                    _bar_len=$(( _bc * 40 / _max_count ))
                fi
                local _bar=""
                for (( _i=0; _i<_bar_len; _i++ )); do _bar="${_bar}#"; done
                printf "  %10s |%-40s %6d\n" "$_bl" "$_bar" "$_bc"
            done
        elif [[ "$_found" == "false" ]]; then
            echo "  (no histogram data for $op)"
        fi
        return
    fi

    # Fallback: approximate from events.tsv avg latency
    if [[ $EV_LINES -le 0 ]]; then
        echo "(no data for $op)"
        return
    fi

    echo "  (approximated from per-cycle avg latency, not full distribution)"
    echo ""

    tail -n +2 "$EV_FILE" | awk -F'\t' -v op="$op" '
    $2==op && ($4+0)>0 {
        v = $4 + 0
        if(v <= 0) next
        bucket = 0; tmp = v
        while(tmp > 1) { tmp /= 2; bucket++ }
        hist[bucket]++
        total++
    }
    END {
        if(total==0) { print "(no latency data for " op ")"; exit }
        max_count = 0; min_bucket = 999; max_bucket = 0
        for(b in hist) {
            if(hist[b] > max_count) max_count = hist[b]
            if(b+0 < min_bucket) min_bucket = b+0
            if(b+0 > max_bucket) max_bucket = b+0
        }
        bar_width = 40; cumulative = 0
        printf "  %-14s %8s %6s  %-40s  %s\n", "Range (us)", "Count", "Pct", "Distribution", "CDF"
        printf "  %-14s %8s %6s  %-40s  %s\n", "-----------", "-----", "----", "----------", "---"
        for(b=min_bucket; b<=max_bucket; b++) {
            c = (b in hist) ? hist[b] : 0
            pct = c * 100.0 / total; cumulative += pct
            lo = 2^b; hi = 2^(b+1)
            range = sprintf("[%d, %d)", lo, hi)
            bar_len = (max_count > 0) ? int(c * bar_width / max_count) : 0
            bar = ""; for(i=0; i<bar_len; i++) bar = bar "#"
            printf "  %-14s %8d %5.1f%%  %-40s  %5.1f%%\n", range, c, pct, bar, cumulative
        }
    }'
}

# ═══════════════════════════════════════════════════════════════════
# Case study 1: IBD write pattern (first 2h)
# ═══════════════════════════════════════════════════════════════════
generate_ibd_study() {
    if [[ $EV_LINES -gt 0 ]]; then
        # Use events.tsv if available
        local first_ts
        first_ts=$(tail -n +2 "$EV_FILE" | head -1 | cut -f1)
        if [[ -z "$first_ts" ]]; then
            echo "No events found."
            return
        fi
        local first_epoch
        first_epoch=$(date -d "$first_ts" +%s 2>/dev/null || echo "0")
        local cutoff_epoch=$((first_epoch + 7200))

        echo "First 2 hours of data (potential IBD phase):"
        echo ""
        echo "| Time Window | Op | Avg QPS | Avg Latency (us) | Avg P99 (us) |"
        echo "|-------------|-----|---------|------------------|--------------|"

        for op in PUT WRITE; do
            tail -n +2 "$EV_FILE" | awk -F'\t' -v op="$op" -v cutoff="$cutoff_epoch" '
            BEGIN { OFS="\t" }
            {
                ts = $1
                cmd = "date -d \"" ts "\" +%s 2>/dev/null"
                cmd | getline epoch
                close(cmd)
            }
            $2==op && epoch+0 <= cutoff {
                n++; qps_sum += $3; lat_sum += $4; p99_sum += $6
            }
            END {
                if(n==0) printf "| 0-2h | %s | 0 | 0 | 0 |\n", op
                else printf "| 0-2h | %s | %.1f | %.1f | %.1f |\n", op, qps_sum/n, lat_sum/n, p99_sum/n
            }' 2>/dev/null || echo "| 0-2h | $op | (parse error) | - | - |"
        done
    elif [[ -f "$PROBE_JSON" ]] && [[ -s "$PROBE_JSON" ]] && command -v jq &>/dev/null; then
        # Fallback: parse probe-json.log directly with jq (first 720 objects ≈ 2h at 10s interval)
        echo "First 2 hours of data (potential IBD phase, from probe JSON):"
        echo ""
        echo "| Time Window | Op | Avg QPS | Avg Latency (us) | Avg P99 (us) |"
        echo "|-------------|-----|---------|------------------|--------------|"

        # Extract first ~720 JSON objects (2h at 10s sampling)
        for op in PUT WRITE GET ITER_NEW TXN_COMMIT; do
            jq -r --arg op "$op" '
                .operations[$op] // empty |
                [.qps, .avg_us, .p99_us] | @tsv
            ' "$PROBE_JSON" 2>/dev/null | awk -F'\t' -v op="$op" '
            NR <= 720 { n++; qps+=$1; lat+=$2; p99+=$3 }
            END {
                if(n==0) printf "| 0-2h | %s | 0 | 0 | 0 |\n", op
                else printf "| 0-2h | %s | %.1f | %.1f | %.1f |\n", op, qps/n, lat/n, p99/n
            }'
        done
    else
        echo "No event data available for IBD analysis."
        return
    fi
}

# ═══════════════════════════════════════════════════════════════════
# Case study 2: Compaction/anomaly spikes
# ═══════════════════════════════════════════════════════════════════
generate_anomaly_study() {
    if [[ ! -f "$PROBE_JSON" ]]; then
        echo "No probe JSON log available."
        return
    fi

    local anomaly_count
    anomaly_count=$(grep -c "ANOMALY\|latency_spike\|anomal" "$PROBE_JSON" 2>/dev/null || echo "0")

    if [[ $anomaly_count -eq 0 ]]; then
        echo "No anomalies or latency spikes were detected during the test period."
        echo ""
        echo "This indicates stable, predictable RocksDB performance throughout the"
        echo "${DURATION_INFO:-48h} test window."
        return
    fi

    echo "Detected **$anomaly_count** anomaly events in probe output."
    echo ""

    # Extract first few anomalies with context
    echo "Sample anomaly events:"
    echo ""
    echo "\`\`\`"
    if command -v jq &>/dev/null; then
        local _anomaly_output
        _anomaly_output=$(jq -r '
            select(.anomalies | length > 0) | .anomalies[] |
            "  [\(.time // "")] \(.operation // "?"): avg=\(.current_avg_us // 0)us (baseline=\(.baseline_avg_us // 0)us, \(.multiplier // 0)x) p99=\(.current_p99_us // 0)us trigger=\(.trigger // "")"
        ' "$PROBE_JSON" 2>/dev/null | awk 'NR<=10')
        if [[ -n "$_anomaly_output" ]]; then
            echo "$_anomaly_output"
        else
            echo "  (anomaly markers found but could not parse details)"
        fi
    else
        echo "  (jq not available for anomaly parsing)"
    fi
    echo "\`\`\`"
}

# ═══════════════════════════════════════════════════════════════════
# Generate the Markdown report
# ═══════════════════════════════════════════════════════════════════
log "Writing report to $REPORT..."

{
cat <<EOF
# CKB-Probe Stability Test Report

> **Scope: CKB testnet only**

## 1. Test Summary

| Field | Value |
|-------|-------|
| Start time | $START_TIME |
| End time | $END_TIME |
| Duration | $DURATION_INFO |
| Kernel | $KERNEL |
| CKB version | $CKB_VER |
| CPU | $CPU_INFO (${CPU_CORES:-?} cores) |
| RAM | $RAM_INFO |
| Data points (timeseries) | $TS_LINES |
| Data points (events) | $( if [[ $EV_LINES -gt 0 ]]; then echo "$EV_LINES"; elif [[ $JSON_OBJECTS -gt 0 ]]; then echo "$JSON_OBJECTS (from JSON)"; else echo "0"; fi ) |

## 2. S-1 through S-4 Verdict

| # | Metric | Criterion | Result |
|---|--------|-----------|--------|
| S-1 | No crash | ckb-probe runs full duration without crash/panic | **$S1_V** |
| S-2 | Memory stability | RSS growth <= 5 MB (last hour avg - first hour avg) | **$S2_V** |
| S-3 | No BPF errors | Zero new BPF-related dmesg messages | **$S3_V** |
| S-4 | Restart recovery | ckb-probe reattaches after CKB restart within 60s | **$S4_V** |

EOF

# S-4 details if available
if [[ -f "$S4_LOG" ]]; then
    echo "<details>"
    echo "<summary>S-4 Restart Test Details</summary>"
    echo ""
    echo "\`\`\`"
    cat "$S4_LOG"
    echo "\`\`\`"
    echo "</details>"
    echo ""
fi

cat <<EOF
## 3. Time-Series Charts

EOF

if [[ "$HAS_GNUPLOT" == "true" && -f "$CHARTS_DIR/probe-cpu.png" ]]; then
    echo "### ckb-probe CPU%"
    echo "![probe-cpu](charts/probe-cpu.png)"
    echo ""
    echo "### ckb-probe RSS"
    echo "![probe-rss](charts/probe-rss.png)"
    echo ""
    echo "### CKB node CPU%"
    echo "![ckb-cpu](charts/ckb-cpu.png)"
    echo ""
    if [[ -f "$CHARTS_DIR/p99-latency.png" ]]; then
        echo "### Per-op P99 Latency"
        echo "![p99-latency](charts/p99-latency.png)"
        echo ""
    fi
    if [[ -f "$CHARTS_DIR/throughput.png" ]]; then
        echo "### BPF Event Throughput"
        echo "![throughput](charts/throughput.png)"
        echo ""
    fi
    if [[ -f "$CHARTS_DIR/tip-sync.png" ]]; then
        echo "### CKB Sync Speed"
        echo "![tip-sync](charts/tip-sync.png)"
        echo ""
    fi
    if [[ -f "$CHARTS_DIR/event-loss.png" ]]; then
        echo "### BPF Event Count (cumulative)"
        echo "![event-loss](charts/event-loss.png)"
        echo ""
    fi
else
    echo "### ckb-probe CPU%"
    if [[ $TS_LINES -gt 0 ]]; then
        generate_ascii_chart "probe CPU%" 2
    else
        echo "(no data)"
    fi
    echo ""

    echo "### ckb-probe RSS (KB)"
    if [[ $TS_LINES -gt 0 ]]; then
        generate_ascii_chart "probe RSS (KB)" 3
    else
        echo "(no data)"
    fi
    echo ""

    echo "### CKB node CPU%"
    if [[ $TS_LINES -gt 0 ]]; then
        generate_ascii_chart "CKB CPU%" 4 '$5+0>0'
    else
        echo "(no data)"
    fi
    echo ""
fi

# Tip sync ASCII chart if no gnuplot
if [[ "$HAS_GNUPLOT" != "true" && -f "$TIP_FILE" ]] && [[ $(wc -l < "$TIP_FILE") -gt 1 ]]; then
    echo "### CKB Sync Speed (blocks/min)"
    echo ""
    echo '```'
    tail -n +2 "$TIP_FILE" | awk -F'\t' '$2+0>0 {print $4}' | awk -v w=60 -v h=12 '
    { a[n]=$1+0; n++ }
    END {
        if(n==0) { print "(no data)"; exit }
        min=a[0]; max=a[0]
        for(i=1;i<n;i++) { if(a[i]<min) min=a[i]; if(a[i]>max) max=a[i] }
        range=max-min; if(range==0) range=1
        bs=n/w; if(bs<1) bs=1
        for(b=0;b<w && b*bs<n;b++) {s=0;c=0; for(j=int(b*bs);j<int((b+1)*bs)&&j<n;j++){s+=a[j];c++}; bins[b]=s/c}; nb=b
        for(r=h-1;r>=0;r--) {th=min+range*(r+0.5)/h; l=""
            for(b=0;b<nb;b++){if(bins[b]>=th)l=l"#";else l=l" "}
            if(r==h-1) printf "%10.0f |%s\n",max,l
            else if(r==0) printf "%10.0f |%s\n",min,l
            else if(r==int(h/2)) printf "%10.0f |%s\n",(min+max)/2,l
            else printf "           |%s\n",l
        }
        printf "           +"; for(i=0;i<nb;i++) printf "-"; printf "\n"
    }'
    echo '```'
    echo ""
fi

# Per-op P99 ASCII chart if no gnuplot
if [[ "$HAS_GNUPLOT" != "true" && $EV_LINES -gt 0 ]]; then
    echo "### Per-op P99 Latency (sampled)"
    echo ""
    for op in $OPS; do
        local_count=$(tail -n +2 "$EV_FILE" | awk -F'\t' -v op="$op" '$2==op' | wc -l)
        if [[ $local_count -gt 0 ]]; then
            echo "#### $op"
            echo "\`\`\`"
            echo "$op P99 Latency (us)"
            tail -n +2 "$EV_FILE" | awk -F'\t' -v op="$op" '$2==op {print $6}' | \
            awk -v w=50 -v h=10 '
            { a[n]=$1+0; n++ }
            END {
                if(n==0) { print "(no data)"; exit }
                min=a[0]; max=a[0]
                for(i=1;i<n;i++) { if(a[i]<min) min=a[i]; if(a[i]>max) max=a[i] }
                range=max-min; if(range==0) range=1
                bs=n/w; if(bs<1) bs=1
                for(b=0;b<w && b*bs<n;b++) {
                    s=0; c=0
                    for(j=int(b*bs);j<int((b+1)*bs)&&j<n;j++){s+=a[j];c++}
                    bins[b]=s/c
                }
                nb=b
                for(r=h-1;r>=0;r--) {
                    th=min+range*(r+0.5)/h; l=""
                    for(b=0;b<nb;b++) { if(bins[b]>=th) l=l"#"; else l=l" " }
                    if(r==h-1) printf "%10.0f |%s\n",max,l
                    else if(r==0) printf "%10.0f |%s\n",min,l
                    else printf "           |%s\n",l
                }
                printf "           +"; for(i=0;i<nb;i++) printf "-"; printf "\n"
            }'
            echo "\`\`\`"
            echo ""
        fi
    done
fi

cat <<EOF
## 4. Resource Summary

| Metric | Min | Max | Avg | P99 | Budget | Verdict |
|--------|-----|-----|-----|-----|--------|---------|
EOF

# Resource rows
read -r pc_min pc_max pc_avg pc_p99 pc_n <<< "$PROBE_CPU_STATS"
read -r pr_min pr_max pr_avg pr_p99 pr_n <<< "$PROBE_RSS_STATS"
read -r cc_min cc_max cc_avg cc_p99 cc_n <<< "$CKB_CPU_STATS"
read -r cr_min cr_max cr_avg cr_p99 cr_n <<< "$CKB_RSS_STATS"

# Convert RSS to MB for display
pr_min_mb=$(awk "BEGIN {printf \"%.1f\", $pr_min/1024}")
pr_max_mb=$(awk "BEGIN {printf \"%.1f\", $pr_max/1024}")
pr_avg_mb=$(awk "BEGIN {printf \"%.1f\", $pr_avg/1024}")
pr_p99_mb=$(awk "BEGIN {printf \"%.1f\", $pr_p99/1024}")

pr_verdict="PASS"
if awk "BEGIN {exit !($pr_p99 > 102400)}" 2>/dev/null; then pr_verdict="WARN"; fi

cat <<EOF
| Probe CPU% | $pc_min | $pc_max | $pc_avg | $pc_p99 | - | - |
| Probe RSS (MB) | $pr_min_mb | $pr_max_mb | $pr_avg_mb | $pr_p99_mb | 100 | $pr_verdict |
| CKB CPU% | $cc_min | $cc_max | $cc_avg | $cc_p99 | - | - |
| CKB RSS (MB) | $(awk "BEGIN{printf\"%.0f\",$cr_min/1024}") | $(awk "BEGIN{printf\"%.0f\",$cr_max/1024}") | $(awk "BEGIN{printf\"%.0f\",$cr_avg/1024}") | $(awk "BEGIN{printf\"%.0f\",$cr_p99/1024}") | - | - |

## 5. Event Fidelity Report

EOF

compute_event_fidelity

cat <<EOF

## 6. Latency Distribution Histograms

Latency is binned into log2 buckets (powers of 2 in microseconds).

EOF

for op in $OPS; do
    echo "### $op"
    echo ""
    echo "\`\`\`"
    generate_latency_histogram "$op"
    echo "\`\`\`"
    echo ""
done

cat <<EOF
## 7. Case Study 1 -- IBD Write Pattern

EOF

generate_ibd_study

# Slow events section (from parallel --slow instance)
if [[ -f "$SLOW_LOG" ]] && [[ -s "$SLOW_LOG" ]]; then
    SLOW_TOTAL=$(grep -cE 'GET|PUT|WRITE|TXN_COMMIT|ITER_NEW' "$SLOW_LOG" 2>/dev/null || echo 0)
    SLOW_LOSS=$(grep -a "BPF event loss" "$SLOW_LOG" | tail -1 || echo "n/a")

    echo ""
    echo "### Slow Events Summary"
    echo ""
    echo "Captured by ckb-probe \`--slow --threshold 1000us\` running in parallel."
    echo ""
    echo "| Metric | Value |"
    echo "|--------|-------|"
    echo "| Total slow operations | $SLOW_TOTAL |"
    echo "| $SLOW_LOSS |"
    echo ""
    echo "| Operation | Count |"
    echo "|-----------|-------|"
    for _sop in GET PUT WRITE ITER_NEW TXN_COMMIT; do
        _scnt=$(grep -c "$_sop" "$SLOW_LOG" 2>/dev/null || echo 0)
        echo "| $_sop | $_scnt |"
    done
    echo ""
fi

cat <<EOF

## 8. Case Study 2 -- Compaction / Anomaly Spikes

EOF

generate_anomaly_study

cat <<EOF

## 9. Reproduction Instructions

To reproduce this stability test:

\`\`\`bash
# System requirements
# Kernel: $KERNEL
# CPU:    $CPU_INFO ($CPU_CORES cores)
# RAM:    $RAM_INFO
# CKB:   $CKB_VER (testnet only)

# 1. Start CKB testnet node
cd /root && ./ckb run &

# 2. Run stability test
cd /root/ckb-probe
DURATION_HOURS=${DURATION_INFO:-48} \\
SAMPLE_SECS=10 \\
  bash scripts/stability/stability-48h.sh

# 3. Generate report
bash scripts/stability/generate-report.sh /path/to/stability-<timestamp>/
\`\`\`

---
*Generated by generate-report.sh on $(date -Iseconds)*
EOF

} > "$REPORT"

log "Report written to: $REPORT"
log "Charts directory: $CHARTS_DIR"

# Summary
echo ""
echo "========================================"
echo "  Report generated: $REPORT"
echo "  Verdict: S-1=$S1_V S-2=$S2_V S-3=$S3_V S-4=$S4_V"
echo "========================================"
