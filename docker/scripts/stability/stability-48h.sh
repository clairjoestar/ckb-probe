#!/usr/bin/env bash
# stability-48h.sh -- 48-hour stability test orchestrator for ckb-probe
# Metrics: S-1 (no crash), S-2 (RSS growth <= 5MB), S-3 (no BPF dmesg errors),
#          S-4 (process restart recovery at T+24h)
#
# Scope: CKB testnet only. Never run against mainnet.
set -euo pipefail

# ═══════════════════════════════════════════════════════════════════
# Configuration (override via environment)
# ═══════════════════════════════════════════════════════════════════
CKB_BIN="${CKB_BIN:-/root/ckb}"
CKB_RPC="${CKB_RPC:-http://127.0.0.1:8114}"
PROBE_BIN="${PROBE_BIN:-/root/ckb-probe/target/release/ckb-probe}"
DURATION_HOURS="${DURATION_HOURS:-48}"
SAMPLE_SECS="${SAMPLE_SECS:-10}"
WORK="${WORK:-/root/ckb-probe/scripts/stability}"

DURATION_SECS=$((DURATION_HOURS * 3600))
S4_TRIGGER_SECS=$((DURATION_SECS / 2))  # halfway point

# ═══════════════════════════════════════════════════════════════════
# Output directory
# ═══════════════════════════════════════════════════════════════════
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
OUTDIR="${WORK}/stability-${TIMESTAMP}"
mkdir -p "$OUTDIR"

# File paths
TS_FILE="$OUTDIR/timeseries.tsv"
EV_FILE="$OUTDIR/events.tsv"
PROBE_STDERR="$OUTDIR/probe-stderr.log"
PROBE_JSON="$OUTDIR/probe-json.log"
DMESG_START="$OUTDIR/dmesg-start.log"
DMESG_END="$OUTDIR/dmesg-end.log"
S4_LOG="$OUTDIR/s4-restart.log"
VERDICT_FILE="$OUTDIR/STABILITY-VERDICT.txt"

# Verdict tracking
S1_PASS=true
S2_PASS=true
S3_PASS=true
S4_PASS=true
S1_REASON=""
S2_REASON=""
S3_REASON=""
S4_REASON=""

# Background PIDs to clean up
BG_PIDS=()

cleanup() {
    echo "[$(date -Iseconds)] Cleaning up background processes..."
    for pid in "${BG_PIDS[@]}"; do
        if kill -0 "$pid" 2>/dev/null; then
            kill "$pid" 2>/dev/null || true
            wait "$pid" 2>/dev/null || true
        fi
    done
}
trap cleanup EXIT

log() {
    echo "[$(date -Iseconds)] $*"
}

die() {
    echo "FATAL: $*" >&2
    exit 1
}

# ═══════════════════════════════════════════════════════════════════
# Pre-flight checks
# ═══════════════════════════════════════════════════════════════════
log "Starting 48h stability test (duration=${DURATION_HOURS}h, sample=${SAMPLE_SECS}s)"
log "Output directory: $OUTDIR"

# ── Permission checks ────────────────────────────────────────
if [[ $(id -u) -ne 0 ]]; then
    die "Must run as root (eBPF requires CAP_BPF + CAP_SYS_ADMIN). Try: sudo $0"
fi
if [[ ! -d /sys/kernel/debug/tracing ]]; then
    die "debugfs not mounted. Mount with: mount -t debugfs none /sys/kernel/debug"
fi
if [[ ! -f /sys/kernel/btf/vmlinux ]]; then
    die "BTF not available at /sys/kernel/btf/vmlinux. Kernel >= 5.8 with BTF required."
fi
if ! bpf_test_fd=$(cat /proc/sys/kernel/unprivileged_bpf_disabled 2>/dev/null); then
    log "Note: cannot read bpf sysctl, proceeding (root should be fine)"
fi
log "Permissions: root=yes, debugfs=yes, BTF=yes"

# Auto-detect CKB PID
CKB_PID=$(pgrep -x ckb 2>/dev/null | head -1) || true
if [[ -z "$CKB_PID" ]]; then
    die "No running CKB process found. Start CKB testnet node first."
fi
log "Detected CKB PID: $CKB_PID"

# Validate testnet (never mainnet)
validate_testnet() {
    # Check via RPC chain info
    local chain_info
    chain_info=$(curl -s -X POST "$CKB_RPC" \
        -H 'Content-Type: application/json' \
        -d '{"id":1,"jsonrpc":"2.0","method":"get_blockchain_info","params":[]}' 2>/dev/null) || true
    if echo "$chain_info" | grep -qi '"chain"[[:space:]]*:[[:space:]]*"ckb"'; then
        # "ckb" means mainnet
        die "ABORT: Detected MAINNET. This tool is for testnet only."
    fi
    if echo "$chain_info" | grep -qi '"chain"[[:space:]]*:[[:space:]]*"ckb_testnet"'; then
        log "Confirmed: CKB testnet"
        return 0
    fi
    # Fallback: check CKB data directory for testnet indicators
    local ckb_cmdline
    ckb_cmdline=$(cat /proc/"$CKB_PID"/cmdline 2>/dev/null | tr '\0' ' ') || true
    if echo "$ckb_cmdline" | grep -qi "mainnet"; then
        die "ABORT: Detected mainnet in CKB command line. Testnet only."
    fi
    log "Warning: Could not confirm testnet via RPC, proceeding (non-mainnet assumed)"
}
validate_testnet

# Record system info
KERNEL_VER=$(uname -r)
CKB_VERSION=$("$CKB_BIN" --version 2>/dev/null || echo "unknown")
CPU_MODEL=$(grep -m1 'model name' /proc/cpuinfo | cut -d: -f2 | xargs)
CPU_CORES=$(nproc)
RAM_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
RAM_MB=$((RAM_KB / 1024))
START_TIME=$(date -Iseconds)
START_EPOCH=$(date +%s)

cat > "$OUTDIR/system-info.txt" <<EOF
Start time:   $START_TIME
Kernel:       $KERNEL_VER
CKB version:  $CKB_VERSION
CKB PID:      $CKB_PID
CKB binary:   $CKB_BIN
CPU model:    $CPU_MODEL
CPU cores:    $CPU_CORES
RAM:          ${RAM_MB} MB
Probe binary: $PROBE_BIN
Duration:     ${DURATION_HOURS}h
Sample rate:  ${SAMPLE_SECS}s
EOF

log "System: kernel=$KERNEL_VER, cpu=$CPU_MODEL ($CPU_CORES cores), ram=${RAM_MB}MB"
log "CKB version: $CKB_VERSION"

# Capture initial dmesg BPF state
dmesg 2>/dev/null | grep -iE "bpf|ebpf" > "$DMESG_START" || true
DMESG_START_LINES=$(wc -l < "$DMESG_START")
log "Initial BPF dmesg lines: $DMESG_START_LINES"

# ═══════════════════════════════════════════════════════════════════
# CPU% computation helpers (from /proc/<pid>/stat)
# ═══════════════════════════════════════════════════════════════════
CLK_TCK=$(getconf CLK_TCK)

# Returns total CPU ticks (utime + stime) for a PID
get_cpu_ticks() {
    local pid=$1
    local stat_line
    stat_line=$(cat /proc/"$pid"/stat 2>/dev/null) || echo ""
    if [[ -z "$stat_line" ]]; then
        echo "0"
        return
    fi
    # Fields: pid (comm) state ppid ... utime(14) stime(15)
    local utime stime
    utime=$(echo "$stat_line" | awk '{print $14}')
    stime=$(echo "$stat_line" | awk '{print $15}')
    echo $((utime + stime))
}

# Returns VmRSS in KB for a PID
get_rss_kb() {
    local pid=$1
    grep VmRSS /proc/"$pid"/status 2>/dev/null | awk '{print $2}' || echo "0"
}

# ═══════════════════════════════════════════════════════════════════
# Initialize TSV files
# ═══════════════════════════════════════════════════════════════════
echo -e "timestamp\tprobe_cpu_pct\tprobe_rss_kb\tckb_cpu_pct\tckb_rss_kb" > "$TS_FILE"
echo -e "timestamp\top\tqps\tavg_us\tp50_us\tp99_us\tbytes_per_sec" > "$EV_FILE"

# Additional data files
TIP_FILE="$OUTDIR/tip-sync.tsv"
LOSS_FILE="$OUTDIR/event-loss.tsv"
OP_COUNT_FILE="$OUTDIR/event-counts-by-op.tsv"
SLOW_LOG="$OUTDIR/slow-events.log"
HIST_LOG="$OUTDIR/histogram.log"
echo -e "timestamp\ttip_height\tdelta_blocks\tblocks_per_min" > "$TIP_FILE"
echo -e "timestamp\ttotal_events\tlost_events\tloss_pct" > "$LOSS_FILE"
echo -e "timestamp\top\tevent_count" > "$OP_COUNT_FILE"

# ═══════════════════════════════════════════════════════════════════
# Start ckb-probe instances
# ═══════════════════════════════════════════════════════════════════

# Instance 1: JSON mode (stats + anomalies + event counts)
# This is the PRIMARY instance — S-1/S-2 resource metrics track this PID only
log "Starting ckb-probe #1 (json, interval=${SAMPLE_SECS}s)..."
"$PROBE_BIN" rocksdb \
    --binary "$CKB_BIN" \
    --pid "$CKB_PID" \
    --json \
    --interval "$SAMPLE_SECS" \
    > "$PROBE_JSON" \
    2> "$PROBE_STDERR" &
PROBE_PID=$!
BG_PIDS+=("$PROBE_PID")
log "ckb-probe #1 (json) PID=$PROBE_PID  ← resource metrics track this one"

# Instance 2: Slow mode (captures individual slow operations + BPF event loss)
log "Starting ckb-probe #2 (slow, threshold=1000μs)..."
"$PROBE_BIN" rocksdb \
    --binary "$CKB_BIN" \
    --pid "$CKB_PID" \
    --slow --threshold 1000 --interval "$SAMPLE_SECS" \
    > "$SLOW_LOG" \
    2> "$OUTDIR/probe-slow-stderr.log" &
SLOW_PID=$!
BG_PIDS+=("$SLOW_PID")
log "ckb-probe #2 (slow) PID=$SLOW_PID  ← slow events + BPF loss counter"

# Instance 3: Histogram mode (captures LATENCY_HIST full distribution)
# Runs at lower frequency (30s) to reduce overhead
log "Starting ckb-probe #3 (histogram, interval=30s)..."
"$PROBE_BIN" rocksdb \
    --binary "$CKB_BIN" \
    --pid "$CKB_PID" \
    --histogram --interval 30 \
    > "$HIST_LOG" \
    2> "$OUTDIR/probe-hist-stderr.log" &
HIST_PID=$!
BG_PIDS+=("$HIST_PID")
log "ckb-probe #3 (histogram) PID=$HIST_PID  ← latency distribution"

# Helper: fetch CKB tip height (decimal)
fetch_tip_dec() {
    local hex
    hex=$(NO_PROXY=127.0.0.1 curl -s -X POST "$CKB_RPC" \
        -H 'Content-Type: application/json' \
        -d '{"id":1,"jsonrpc":"2.0","method":"get_tip_block_number","params":[]}' \
        | jq -r '.result // empty')
    [[ -n "$hex" ]] && printf '%d' "$hex" || echo "0"
}

# Initial tip for delta tracking
PREV_TIP=$(fetch_tip_dec)
PREV_TIP_TIME=$(date +%s)

# Give probe a moment to attach
sleep 2
if ! kill -0 "$PROBE_PID" 2>/dev/null; then
    die "ckb-probe exited immediately. Check $PROBE_STDERR"
fi

# ═══════════════════════════════════════════════════════════════════
# Main data collection loop
# ═══════════════════════════════════════════════════════════════════

# Initial CPU tick readings
PREV_PROBE_TICKS=$(get_cpu_ticks "$PROBE_PID")
PREV_CKB_TICKS=$(get_cpu_ticks "$CKB_PID")
PREV_TIME_NS=$(date +%s%N)

# RSS tracking for S-2
FIRST_HOUR_RSS_SUM=0
FIRST_HOUR_RSS_COUNT=0
LAST_HOUR_RSS_SUM=0
LAST_HOUR_RSS_COUNT=0
FIRST_HOUR_END=$((START_EPOCH + 3600))
LAST_HOUR_START=$((START_EPOCH + DURATION_SECS - 3600))

# S-4 tracking
S4_DONE=false
S4_TRIGGERED=false

# dmesg check interval
LAST_DMESG_CHECK=$START_EPOCH
DMESG_CHECK_INTERVAL=60

# JSON line tracking for events.tsv
LAST_JSON_LINES=0

log "Entering main collection loop (${DURATION_HOURS}h)..."

ITERATION=0
while true; do
    NOW_EPOCH=$(date +%s)
    ELAPSED=$((NOW_EPOCH - START_EPOCH))

    # Check if duration exceeded
    if [[ $ELAPSED -ge $DURATION_SECS ]]; then
        log "Duration reached (${DURATION_HOURS}h). Ending collection."
        break
    fi

    sleep "$SAMPLE_SECS"
    ITERATION=$((ITERATION + 1))
    NOW_EPOCH=$(date +%s)
    ELAPSED=$((NOW_EPOCH - START_EPOCH))
    NOW_TS=$(date -Iseconds)

    # ── S-1: Check primary probe is alive ────────────────────
    if ! kill -0 "$PROBE_PID" 2>/dev/null; then
        log "S-1 FAIL: ckb-probe #1 (PID $PROBE_PID) died at $NOW_TS"
        S1_PASS=false
        S1_REASON="ckb-probe #1 (json) exited unexpectedly at $NOW_TS (elapsed=${ELAPSED}s)"
        if grep -qiE "panic|SIGSEGV" "$PROBE_STDERR" 2>/dev/null; then
            S1_REASON="$S1_REASON; panic/SIGSEGV detected in stderr"
        fi
        break
    fi

    # Check stderr for panic/SIGSEGV (even while running)
    if grep -qiE "panic|SIGSEGV" "$PROBE_STDERR" 2>/dev/null; then
        log "S-1 WARNING: panic/SIGSEGV found in probe stderr"
        S1_PASS=false
        S1_REASON="panic/SIGSEGV detected in probe stderr at $NOW_TS"
    fi

    # Restart secondary probes if they died (non-critical, don't affect S-1)
    # Only restart if CKB_PID is valid (probes need a valid target)
    if [[ -n "$CKB_PID" ]] && [[ -d "/proc/$CKB_PID" ]]; then
        if ! kill -0 "$SLOW_PID" 2>/dev/null; then
            log "WARNING: ckb-probe #2 (slow) died, restarting with CKB PID=$CKB_PID..."
            "$PROBE_BIN" rocksdb --binary "$CKB_BIN" --pid "$CKB_PID" \
                --slow --threshold 1000 --interval "$SAMPLE_SECS" \
                >> "$SLOW_LOG" 2>> "$OUTDIR/probe-slow-stderr.log" &
            SLOW_PID=$!; BG_PIDS+=("$SLOW_PID")
        fi
        if ! kill -0 "$HIST_PID" 2>/dev/null; then
            log "WARNING: ckb-probe #3 (histogram) died, restarting with CKB PID=$CKB_PID..."
            "$PROBE_BIN" rocksdb --binary "$CKB_BIN" --pid "$CKB_PID" \
                --histogram --interval 30 \
                >> "$HIST_LOG" 2>> "$OUTDIR/probe-hist-stderr.log" &
            HIST_PID=$!; BG_PIDS+=("$HIST_PID")
        fi
    fi

    # ── Resource metrics ───────────────────────────────────────
    NOW_NS=$(date +%s%N)
    CUR_PROBE_TICKS=$(get_cpu_ticks "$PROBE_PID")

    DELTA_NS=$((NOW_NS - PREV_TIME_NS))
    if [[ $DELTA_NS -gt 0 ]]; then
        DELTA_PROBE=$((CUR_PROBE_TICKS - PREV_PROBE_TICKS))
        PROBE_CPU=$(awk "BEGIN {printf \"%.2f\", $DELTA_PROBE * 100.0 / $CLK_TCK / ($DELTA_NS / 1000000000.0)}")
    else
        PROBE_CPU="0.00"
    fi
    PROBE_RSS=$(get_rss_kb "$PROBE_PID")

    # CKB metrics: validate PID is alive; if not, try to re-find it
    if [[ -n "$CKB_PID" ]] && [[ -d "/proc/$CKB_PID" ]]; then
        CUR_CKB_TICKS=$(get_cpu_ticks "$CKB_PID")
        if [[ $DELTA_NS -gt 0 ]]; then
            DELTA_CKB=$((CUR_CKB_TICKS - PREV_CKB_TICKS))
            # Clamp negative delta (happens on PID change)
            if [[ $DELTA_CKB -lt 0 ]]; then DELTA_CKB=0; fi
            CKB_CPU=$(awk "BEGIN {printf \"%.2f\", $DELTA_CKB * 100.0 / $CLK_TCK / ($DELTA_NS / 1000000000.0)}")
        else
            CKB_CPU="0.00"
        fi
        CKB_RSS=$(get_rss_kb "$CKB_PID")
    else
        # CKB process not found — try to re-detect
        CKB_PID=$(pgrep -x ckb 2>/dev/null | head -1) || true
        if [[ -n "$CKB_PID" ]] && [[ -d "/proc/$CKB_PID" ]]; then
            log "Re-detected CKB PID: $CKB_PID"
            CUR_CKB_TICKS=$(get_cpu_ticks "$CKB_PID")
            PREV_CKB_TICKS=$CUR_CKB_TICKS
            CKB_CPU="0.00"
            CKB_RSS=$(get_rss_kb "$CKB_PID")
        else
            CUR_CKB_TICKS=0
            CKB_CPU="0.00"
            CKB_RSS="0"
        fi
    fi

    echo -e "${NOW_TS}\t${PROBE_CPU}\t${PROBE_RSS}\t${CKB_CPU}\t${CKB_RSS}" >> "$TS_FILE"

    PREV_PROBE_TICKS=$CUR_PROBE_TICKS
    PREV_CKB_TICKS=$CUR_CKB_TICKS
    PREV_TIME_NS=$NOW_NS

    # ── S-2: RSS tracking ──────────────────────────────────────
    if [[ $NOW_EPOCH -le $FIRST_HOUR_END ]]; then
        FIRST_HOUR_RSS_SUM=$((FIRST_HOUR_RSS_SUM + PROBE_RSS))
        FIRST_HOUR_RSS_COUNT=$((FIRST_HOUR_RSS_COUNT + 1))
    fi
    if [[ $NOW_EPOCH -ge $LAST_HOUR_START ]]; then
        LAST_HOUR_RSS_SUM=$((LAST_HOUR_RSS_SUM + PROBE_RSS))
        LAST_HOUR_RSS_COUNT=$((LAST_HOUR_RSS_COUNT + 1))
    fi

    # ── Parse JSON output for events.tsv ───────────────────────
    # Count current lines in probe-json.log and extract new complete JSON objects
    CUR_JSON_LINES=$(wc -l < "$PROBE_JSON" 2>/dev/null || echo "0")
    if [[ $CUR_JSON_LINES -gt $LAST_JSON_LINES ]]; then
        # Extract new content and parse JSON blocks for per-op metrics
        tail -n +$((LAST_JSON_LINES + 1)) "$PROBE_JSON" 2>/dev/null | \
        python3 -c "
import sys, json

buf = ''
depth = 0
for line in sys.stdin:
    buf += line
    depth += line.count('{') - line.count('}')
    if depth == 0 and buf.strip():
        try:
            obj = json.loads(buf)
            ts = obj.get('timestamp', '')
            ops = obj.get('operations', {})
            for op_name, vals in ops.items():
                qps = vals.get('qps', 0)
                avg_us = vals.get('avg_us', 0)
                p50_us = vals.get('p50_us', 0)
                p99_us = vals.get('p99_us', 0)
                bps = vals.get('bytes_per_sec')
                bps_str = str(bps) if bps is not None else '0'
                print(f'{ts}\t{op_name}\t{qps}\t{avg_us}\t{p50_us}\t{p99_us}\t{bps_str}')
        except json.JSONDecodeError:
            pass
        buf = ''
" >> "$EV_FILE" 2>/dev/null || true
        LAST_JSON_LINES=$CUR_JSON_LINES
    fi

    # ── CKB tip sync speed (every 60s) ───────────────────────
    if [[ $((NOW_EPOCH - PREV_TIP_TIME)) -ge 60 ]]; then
        CUR_TIP=$(fetch_tip_dec)
        TIP_DELTA=$((CUR_TIP - PREV_TIP))
        TIP_DT=$((NOW_EPOCH - PREV_TIP_TIME))
        TIP_BPM=$(awk -v d="$TIP_DELTA" -v t="$TIP_DT" 'BEGIN{if(t>0) printf "%.1f",d/(t/60); else print "0"}')
        echo -e "${NOW_TS}\t${CUR_TIP}\t${TIP_DELTA}\t${TIP_BPM}" >> "$TIP_FILE"
        PREV_TIP=$CUR_TIP
        PREV_TIP_TIME=$NOW_EPOCH
    fi

    # ── BPF event loss tracking (from slow mode footer) ──────
    LOSS_LINE=$(grep -a "BPF event loss" "$SLOW_LOG" 2>/dev/null | tail -1 || true)
    if [[ -n "$LOSS_LINE" ]]; then
        EV_TOTAL=$(echo "$LOSS_LINE" | grep -oP '\d+(?= attempted)' || echo "0")
        EV_LOST=$(echo "$LOSS_LINE" | grep -oP 'loss: \K\d+' || echo "0")
        EV_PCT=$(echo "$LOSS_LINE" | grep -oP '\(\K[0-9.]+(?=%)' || echo "0")
        echo -e "${NOW_TS}\t${EV_TOTAL}\t${EV_LOST}\t${EV_PCT}" >> "$LOSS_FILE"
    fi

    # ── Per-op event counts (from latest JSON cycle) ───────────
    LAST_JSON_BLOCK=$(awk '/^{/{buf=""}{buf=buf $0 "\n"}/^}/{print buf}' "$PROBE_JSON" 2>/dev/null | tail -1 || true)
    if [[ -n "$LAST_JSON_BLOCK" ]]; then
        for _op in GET PUT WRITE ITER_NEW TXN_COMMIT; do
            _qps=$(echo "$LAST_JSON_BLOCK" | python3 -c "
import sys,json
try:
    obj=json.load(sys.stdin)
    print(obj.get('operations',{}).get('$_op',{}).get('qps',0))
except: print(0)" 2>/dev/null || echo "0")
            echo -e "${NOW_TS}\t${_op}\t${_qps}" >> "$OP_COUNT_FILE"
        done
    fi

    # ── S-3: Periodic dmesg BPF check ─────────────────────────
    if [[ $((NOW_EPOCH - LAST_DMESG_CHECK)) -ge $DMESG_CHECK_INTERVAL ]]; then
        LAST_DMESG_CHECK=$NOW_EPOCH
        NEW_BPF_MSGS=$(dmesg 2>/dev/null | grep -iE "bpf|ebpf" | wc -l || true)
        if [[ $NEW_BPF_MSGS -gt $DMESG_START_LINES ]]; then
            DIFF_COUNT=$((NEW_BPF_MSGS - DMESG_START_LINES))
            log "S-3 WARNING: $DIFF_COUNT new BPF-related dmesg messages detected"
        fi
    fi

    # ── S-4: Restart test at halfway point ─────────────────────
    if [[ "$S4_DONE" == "false" && $ELAPSED -ge $S4_TRIGGER_SECS ]]; then
        S4_DONE=true
        log "S-4: Triggering CKB restart test at T+${ELAPSED}s"
        {
            echo "=== S-4 CKB Restart Test ==="
            echo "Trigger time: $(date -Iseconds)"
            echo "Elapsed: ${ELAPSED}s"
            echo ""

            # Step 1: Kill CKB
            echo "Step 1: Sending SIGTERM to CKB (PID $CKB_PID)..."
            kill -TERM "$CKB_PID" 2>/dev/null || true
            echo "SIGTERM sent at $(date -Iseconds)"

            # Step 2: Wait 10s
            echo "Step 2: Waiting 10s..."
            sleep 10

            # Verify CKB is down
            if kill -0 "$CKB_PID" 2>/dev/null; then
                echo "WARNING: CKB still alive after SIGTERM, sending SIGKILL"
                kill -9 "$CKB_PID" 2>/dev/null || true
                sleep 2
            fi
            echo "CKB stopped at $(date -Iseconds)"

            # Step 3: Restart CKB
            echo "Step 3: Restarting CKB..."
            RESTART_START=$(date +%s)
            cd /root && nohup ./ckb run > /dev/null 2>&1 &
            NEW_CKB_PID=$!
            echo "New CKB PID: $NEW_CKB_PID"

            # Step 4: Watch for reconnection within 60s
            echo "Step 4: Waiting for ckb-probe to detect restart (up to 60s)..."
            RECONNECTED=false
            for i in $(seq 1 60); do
                sleep 1
                # Check if probe is still running
                if ! kill -0 "$PROBE_PID" 2>/dev/null; then
                    echo "FAIL: ckb-probe died during restart test"
                    break
                fi
                # Check probe output for reconnection indicators
                if tail -20 "$PROBE_JSON" 2>/dev/null | grep -q "\"pid\""; then
                    RECONNECT_SECS=$i
                    RECONNECTED=true
                    echo "Reconnection detected at T+${i}s"
                    break
                fi
            done

            if [[ "$RECONNECTED" == "true" ]]; then
                echo ""
                echo "RESULT: PASS - ckb-probe reattached in ${RECONNECT_SECS}s"
                echo "Time-to-reconnect: ${RECONNECT_SECS}s"
            else
                echo ""
                echo "RESULT: FAIL - ckb-probe did not reattach within 60s"
            fi

            echo ""
            echo "=== End S-4 Test ==="
        } > "$S4_LOG" 2>&1

        # Evaluate S-4 result
        if grep -q "RESULT: PASS" "$S4_LOG" 2>/dev/null; then
            S4_PASS=true
            log "S-4: PASS"
        else
            S4_PASS=false
            S4_REASON="ckb-probe did not reattach to restarted CKB within 60s"
            log "S-4: FAIL - $S4_REASON"
        fi

        # Update CKB_PID for continued monitoring (retry up to 30s)
        CKB_PID=""
        for _retry in $(seq 1 30); do
            sleep 1
            CKB_PID=$(pgrep -x ckb 2>/dev/null | head -1) || true
            if [[ -n "$CKB_PID" ]] && [[ -d "/proc/$CKB_PID" ]]; then
                break
            fi
            CKB_PID=""
        done
        if [[ -z "$CKB_PID" ]]; then
            log "WARNING: Cannot find new CKB PID after restart (tried 30s)"
        else
            log "New CKB PID: $CKB_PID (found after ${_retry}s)"
            PREV_CKB_TICKS=$(get_cpu_ticks "$CKB_PID")
            PREV_TIME_NS=$(date +%s%N)
        fi
    fi

    # Progress logging every 5 minutes
    if [[ $((ITERATION % (300 / SAMPLE_SECS))) -eq 0 ]]; then
        HOURS_DONE=$(awk "BEGIN {printf \"%.1f\", $ELAPSED / 3600.0}")
        log "Progress: ${HOURS_DONE}h / ${DURATION_HOURS}h | probe_rss=${PROBE_RSS}KB cpu=${PROBE_CPU}%"
    fi
done

# ═══════════════════════════════════════════════════════════════════
# Post-collection analysis
# ═══════════════════════════════════════════════════════════════════
END_TIME=$(date -Iseconds)
log "Collection complete. Running post-analysis..."

# ── S-2 final verdict ─────────────────────────────────────────
if [[ $FIRST_HOUR_RSS_COUNT -gt 0 && $LAST_HOUR_RSS_COUNT -gt 0 ]]; then
    FIRST_AVG_RSS=$((FIRST_HOUR_RSS_SUM / FIRST_HOUR_RSS_COUNT))
    LAST_AVG_RSS=$((LAST_HOUR_RSS_SUM / LAST_HOUR_RSS_COUNT))
    RSS_GROWTH_KB=$((LAST_AVG_RSS - FIRST_AVG_RSS))
    RSS_GROWTH_MB=$(awk "BEGIN {printf \"%.2f\", $RSS_GROWTH_KB / 1024.0}")
    log "S-2: RSS growth = ${RSS_GROWTH_MB} MB (first_hour_avg=${FIRST_AVG_RSS}KB, last_hour_avg=${LAST_AVG_RSS}KB)"
    # 5 MB = 5120 KB
    if [[ $RSS_GROWTH_KB -gt 5120 ]]; then
        S2_PASS=false
        S2_REASON="RSS growth ${RSS_GROWTH_MB}MB exceeds 5MB budget (first_hour=${FIRST_AVG_RSS}KB, last_hour=${LAST_AVG_RSS}KB)"
    fi
else
    RSS_GROWTH_MB="N/A"
    log "S-2: Insufficient data (first_hour_count=$FIRST_HOUR_RSS_COUNT, last_hour_count=$LAST_HOUR_RSS_COUNT)"
    S2_REASON="Insufficient data to compute RSS growth"
fi

# ── S-3 final verdict ─────────────────────────────────────────
dmesg 2>/dev/null | grep -iE "bpf|ebpf" > "$DMESG_END" || true
DMESG_END_LINES=$(wc -l < "$DMESG_END")
DMESG_NEW=$((DMESG_END_LINES - DMESG_START_LINES))
if [[ $DMESG_NEW -gt 0 ]]; then
    S3_PASS=false
    S3_REASON="$DMESG_NEW new BPF-related dmesg messages during test"
    log "S-3: FAIL - $S3_REASON"
    # Show the new messages
    diff <(cat "$DMESG_START") <(cat "$DMESG_END") >> "$S4_LOG" 2>/dev/null || true
else
    log "S-3: PASS - zero new BPF dmesg messages"
fi

# ── S-4: check if test was run ─────────────────────────────────
if [[ "$S4_DONE" == "false" ]]; then
    S4_PASS=false
    S4_REASON="S-4 restart test never triggered (test ended before halfway point)"
    log "S-4: NOT RUN - $S4_REASON"
fi

# ═══════════════════════════════════════════════════════════════════
# Write verdict file
# ═══════════════════════════════════════════════════════════════════
s_result() {
    if [[ "$1" == "true" ]]; then echo "PASS"; else echo "FAIL"; fi
}

cat > "$VERDICT_FILE" <<EOF
========================================
  CKB-PROBE STABILITY TEST VERDICT
  (testnet only)
========================================

Duration:    ${DURATION_HOURS}h
Start:       $START_TIME
End:         $END_TIME
CKB version: $CKB_VERSION
Kernel:      $KERNEL_VER

────────────────────────────────────────
S-1  No crash             $(s_result $S1_PASS)
S-2  RSS growth <= 5MB    $(s_result $S2_PASS)
S-3  No BPF dmesg errors  $(s_result $S3_PASS)
S-4  Restart recovery     $(s_result $S4_PASS)
────────────────────────────────────────

Overall: $(if $S1_PASS && $S2_PASS && $S3_PASS && $S4_PASS; then echo "ALL PASS"; else echo "SOME FAILURES"; fi)

EOF

if [[ "$S1_PASS" == "false" ]]; then echo "S-1 detail: $S1_REASON" >> "$VERDICT_FILE"; fi
if [[ "$S2_PASS" == "false" ]]; then echo "S-2 detail: $S2_REASON" >> "$VERDICT_FILE"; fi
if [[ "$S2_PASS" == "true" ]]; then echo "S-2 detail: RSS growth = ${RSS_GROWTH_MB} MB" >> "$VERDICT_FILE"; fi
if [[ "$S3_PASS" == "false" ]]; then echo "S-3 detail: $S3_REASON" >> "$VERDICT_FILE"; fi
if [[ "$S4_PASS" == "false" ]]; then echo "S-4 detail: $S4_REASON" >> "$VERDICT_FILE"; fi

log "Verdict written to $VERDICT_FILE"
log "Output directory: $OUTDIR"
cat "$VERDICT_FILE"
