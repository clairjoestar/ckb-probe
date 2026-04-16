#!/usr/bin/env bash
# env-check.sh - Host prerequisite checker for ckb-probe
# Testnet only. Never use with mainnet.

set -euo pipefail

PASS=0
FAIL=0

check() {
    local label="$1"
    local ok="$2"
    if [ "$ok" -eq 1 ]; then
        printf "  [PASS] %s\n" "$label"
        PASS=$((PASS + 1))
    else
        printf "  [FAIL] %s\n" "$label"
        FAIL=$((FAIL + 1))
    fi
}

echo "=== ckb-probe environment check (testnet only) ==="
echo ""

# 1. Kernel >= 5.8
KVER=$(uname -r | grep -oP '^\d+\.\d+')
KMAJOR=$(echo "$KVER" | cut -d. -f1)
KMINOR=$(echo "$KVER" | cut -d. -f2)
if [ "$KMAJOR" -gt 5 ] || { [ "$KMAJOR" -eq 5 ] && [ "$KMINOR" -ge 8 ]; }; then
    check "Kernel >= 5.8 (found $(uname -r))" 1
else
    check "Kernel >= 5.8 (found $(uname -r))" 0
fi

# 2. Docker >= 20.10
if command -v docker &>/dev/null; then
    DVER=$(docker version --format '{{.Server.Version}}' 2>/dev/null || echo "0.0")
    DMAJOR=$(echo "$DVER" | cut -d. -f1)
    DMINOR=$(echo "$DVER" | cut -d. -f2)
    if [ "$DMAJOR" -gt 20 ] || { [ "$DMAJOR" -eq 20 ] && [ "$DMINOR" -ge 10 ]; }; then
        check "Docker >= 20.10 (found $DVER)" 1
    else
        check "Docker >= 20.10 (found $DVER)" 0
    fi
else
    check "Docker >= 20.10 (not installed)" 0
fi

# 3. (removed: docker compose no longer required — single container only)

# 4. RAM >= 4GB
MEM_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
MEM_GB=$((MEM_KB / 1024 / 1024))
if [ "$MEM_GB" -ge 4 ]; then
    check "RAM >= 4GB (found ${MEM_GB}GB)" 1
else
    check "RAM >= 4GB (found ${MEM_GB}GB)" 0
fi

# 5. Disk >= 20GB free
DISK_AVAIL_KB=$(df --output=avail . | tail -1 | tr -d ' ')
DISK_AVAIL_GB=$((DISK_AVAIL_KB / 1024 / 1024))
if [ "$DISK_AVAIL_GB" -ge 20 ]; then
    check "Disk >= 20GB free (found ${DISK_AVAIL_GB}GB)" 1
else
    check "Disk >= 20GB free (found ${DISK_AVAIL_GB}GB)" 0
fi

# 6. BTF support
if [ -f /sys/kernel/btf/vmlinux ]; then
    check "/sys/kernel/btf/vmlinux exists" 1
else
    check "/sys/kernel/btf/vmlinux exists" 0
fi

# 7. BPF config enabled
BPF_OK=0
if [ -f /proc/config.gz ]; then
    if zcat /proc/config.gz 2>/dev/null | grep -q 'CONFIG_BPF=y'; then
        BPF_OK=1
    fi
elif [ -f "/boot/config-$(uname -r)" ]; then
    if grep -q 'CONFIG_BPF=y' "/boot/config-$(uname -r)"; then
        BPF_OK=1
    fi
else
    # Fallback: check if bpf syscall works
    if bpftool version &>/dev/null 2>&1; then
        BPF_OK=1
    fi
fi
check "BPF config enabled" "$BPF_OK"

echo ""
echo "--- Result: $PASS passed, $FAIL failed ---"

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
exit 0
