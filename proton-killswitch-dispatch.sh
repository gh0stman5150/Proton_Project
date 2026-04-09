#!/usr/bin/env bash
set -euo pipefail

KILLSWITCH_BACKEND="${KILLSWITCH_BACKEND:-auto}"
IPTABLES_SCRIPT="${IPTABLES_SCRIPT:-/usr/local/bin/proton/proton-killswitch-safe.sh}"
NFTABLES_SCRIPT="${NFTABLES_SCRIPT:-/usr/local/bin/proton/proton-killswitch-nft.sh}"

case "$KILLSWITCH_BACKEND" in
    auto)
        if command -v nft >/dev/null 2>&1; then
            exec "$NFTABLES_SCRIPT"
        fi

        exec "$IPTABLES_SCRIPT"
        ;;
    nft|nftables)
        exec "$NFTABLES_SCRIPT"
        ;;
    iptables)
        exec "$IPTABLES_SCRIPT"
        ;;
    *)
        echo "ERROR: Unsupported KILLSWITCH_BACKEND: $KILLSWITCH_BACKEND" >&2
        exit 1
        ;;
esac
