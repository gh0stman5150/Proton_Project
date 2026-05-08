#!/usr/bin/env bash
set -euo pipefail

# Reset kill-switch state. Respect configured backend when possible so we
# don't involuntarily mix nftables and iptables cleanup on systems using one.
KILLSWITCH_BACKEND="${KILLSWITCH_BACKEND:-auto}"

cleanup_iptables() {
	if ! command -v iptables >/dev/null 2>&1; then
		return 0
	fi

	iptables -D INPUT -j PROTON_INPUT 2>/dev/null || true
	iptables -D OUTPUT -j PROTON_OUTPUT 2>/dev/null || true
	iptables -D FORWARD -j PROTON_DOCKER_FORWARD 2>/dev/null || true
	iptables -F PROTON_INPUT 2>/dev/null || true
	iptables -F PROTON_OUTPUT 2>/dev/null || true
	iptables -F PROTON_DOCKER_FORWARD 2>/dev/null || true
	iptables -X PROTON_INPUT 2>/dev/null || true
	iptables -X PROTON_OUTPUT 2>/dev/null || true
	iptables -X PROTON_DOCKER_FORWARD 2>/dev/null || true

	iptables -P OUTPUT ACCEPT 2>/dev/null || true
	iptables -P INPUT ACCEPT 2>/dev/null || true
	iptables -P FORWARD ACCEPT 2>/dev/null || true

	iptables -t nat -D POSTROUTING -j PROTON_POSTROUTING 2>/dev/null || true
	iptables -t nat -F PROTON_POSTROUTING 2>/dev/null || true
	iptables -t nat -X PROTON_POSTROUTING 2>/dev/null || true
}

cleanup_nft() {
	if ! command -v nft >/dev/null 2>&1; then
		return 0
	fi

	nft delete table inet proton 2>/dev/null || true
	nft delete table ip proton_nat 2>/dev/null || true
}

case "$KILLSWITCH_BACKEND" in
	iptables)
		cleanup_iptables
		;;
	nft|nftables)
		cleanup_nft
		;;
	auto)
		if command -v nft >/dev/null 2>&1; then
			cleanup_nft
		elif command -v iptables >/dev/null 2>&1; then
			cleanup_iptables
		else
			# Best-effort on systems without either tool
			cleanup_nft || true
			cleanup_iptables || true
		fi
		;;
	*)
		# Unknown value: best-effort cleanup for both backends
		cleanup_nft || true
		cleanup_iptables || true
		;;
esac
