#!/usr/bin/env bash
#
# demo-check.sh — runs `ckb-probe check` and `ckb-probe symbols` for an
# environment health check + symbol report. Read-only, no eBPF attach.

set -euo pipefail

CKB_BIN="${CKB_BIN:-/usr/local/bin/ckb}"
PROBE_BIN="${PROBE_BIN:-/usr/local/bin/ckb-probe}"
OUTPUT_DIR="${OUTPUT_DIR:-/tmp/perf-run}/demo"
mkdir -p "$OUTPUT_DIR"

CHECK_OUT=$OUTPUT_DIR/demo-check.txt
SYMBOLS_OUT=$OUTPUT_DIR/demo-symbols.txt
SYMBOLS_JSON=$OUTPUT_DIR/demo-symbols.json

echo "════════════════════════════════════════════════════════════════"
echo "  demo-check — environment + symbol report"
echo "════════════════════════════════════════════════════════════════"
echo

# ── ckb-probe check ────────────────────────────────────────────
echo "[1/3] running: ckb-probe check"
echo
CKB_PID=$(pgrep -x ckb | head -n1 || true)
if [[ -n "$CKB_PID" ]]; then
    "$PROBE_BIN" check --binary "$CKB_BIN" --pid "$CKB_PID" | tee "$CHECK_OUT"
else
    echo "  (ckb not running, doing static check only)"
    "$PROBE_BIN" check --binary "$CKB_BIN" | tee "$CHECK_OUT"
fi
echo
echo "  -> saved to $CHECK_OUT"
echo

# ── ckb-probe symbols (human-readable) ─────────────────────────
echo "[2/3] running: ckb-probe symbols (human-readable)"
echo
"$PROBE_BIN" symbols "$CKB_BIN" | tee "$SYMBOLS_OUT"
echo
echo "  -> saved to $SYMBOLS_OUT"
echo

# ── ckb-probe symbols --json (machine-readable) ────────────────
echo "[3/3] running: ckb-probe symbols --json"
"$PROBE_BIN" symbols "$CKB_BIN" --json > "$SYMBOLS_JSON"
echo
echo "  -> saved to $SYMBOLS_JSON ($(wc -c < "$SYMBOLS_JSON") bytes)"
echo "  summary:"
jq '{
    binary: .binary_path,
    rocksdb_linkage: .rocksdb_linkage,
    tier1_found: .summary.tier1_found,
    tier1_tracked: .summary.tier1_tracked,
    tier2_found: .summary.tier2_found,
    recommendation: .summary.recommendation
}' "$SYMBOLS_JSON"

echo
echo "════════════════════════════════════════════════════════════════"
echo "  demo-check complete"
echo "════════════════════════════════════════════════════════════════"
