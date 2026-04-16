#!/usr/bin/env bash
#
# start-ckb.sh — idempotent CKB startup. Returns when RPC is ready.

set -euo pipefail

CKB_BIN="${CKB_BIN:-/usr/local/bin/ckb}"
CKB_DATA="${CKB_DATA:-/data}"
CKB_RPC="${CKB_RPC:-http://127.0.0.1:8124}"

if pgrep -x ckb >/dev/null; then
    echo "[start-ckb] already running, pid=$(pgrep -x ckb)"
    exit 0
fi

if [[ ! -d "$CKB_DATA" ]]; then
    echo "[start-ckb] FATAL: CKB_DATA=$CKB_DATA does not exist" >&2
    echo "                   mount it with -v /host/ckb-data:$CKB_DATA" >&2
    exit 1
fi

# Initialise config if missing
if [[ ! -f "$CKB_DATA/ckb.toml" ]]; then
    echo "[start-ckb] no ckb.toml found, running ckb init --chain testnet"
    "$CKB_BIN" init --chain testnet -C "$CKB_DATA"
fi

echo "[start-ckb] starting ckb..."
nohup "$CKB_BIN" run -C "$CKB_DATA" > /var/log/ckb.log 2>&1 &
disown

# Wait for RPC
for _ in {1..60}; do
    if curl -sf -X POST "$CKB_RPC" \
        -H 'Content-Type: application/json' \
        -d '{"id":1,"jsonrpc":"2.0","method":"get_tip_block_number","params":[]}' \
        >/dev/null 2>&1; then
        echo "[start-ckb] RPC ready, pid=$(pgrep -x ckb)"
        exit 0
    fi
    sleep 2
done

echo "[start-ckb] FATAL: CKB RPC did not come up within 120s" >&2
tail -30 /var/log/ckb.log >&2 || true
exit 1
