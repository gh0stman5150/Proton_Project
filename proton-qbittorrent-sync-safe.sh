#!/usr/bin/env bash
set -euo pipefail

ENV_FILE="${QBITTORRENT_ENV_FILE:-/etc/proton/qbittorrent.env}"
STATE_FILE="${STATE_FILE:-/run/proton/proton-port.state}"
CACHE_FILE="${CACHE_FILE:-/run/proton/qbt-port.cache}"
LOG_TAG="${LOG_TAG:-proton-qbt}"
CACHE_DIR="${CACHE_FILE%/*}"
VPN_INTERFACE="${VPN_INTERFACE:-proton}"
STATE_DIR="${STATE_DIR:-/run/proton}"
SERVER_SELECTION_FILE="${SERVER_SELECTION_FILE:-${STATE_DIR}/current-server.env}"

if [[ "$CACHE_DIR" == "$CACHE_FILE" ]]; then
	CACHE_DIR="."
fi

log() {
	echo "$(date '+%F %T') | $*" | systemd-cat -t "$LOG_TAG"
}

require_command() {
	local cmd="$1"

	if ! command -v "$cmd" >/dev/null 2>&1; then
		log "ERROR: Required command '$cmd' is not installed."
		exit 1
	fi
}

for cmd in awk cat chmod curl cut grep mkdir stat systemd-cat tr docker nft; do
	require_command "$cmd"
done

mkdir -p "$CACHE_DIR"
chmod 700 "$CACHE_DIR"

if [[ -f "$ENV_FILE" ]]; then
	ENV_MODE="$(stat -c '%a' "$ENV_FILE")"
	ENV_OWNER="$(stat -c '%u' "$ENV_FILE")"

	if [[ "$ENV_MODE" != "600" ]]; then
		log "ERROR: $ENV_FILE must have mode 600"
		exit 1
	fi

	if [[ "$ENV_OWNER" != "0" ]]; then
		log "ERROR: $ENV_FILE must be owned by root"
		exit 1
	fi

	# shellcheck disable=SC1090
	source "$ENV_FILE"
else
	log "ERROR: Env file not found: $ENV_FILE"
	exit 1
fi

: "${QBITTORRENT_URL:?Missing QBITTORRENT_URL}"
: "${QBITTORRENT_USER:?Missing QBITTORRENT_USER}"
: "${QBITTORRENT_PASS:?Missing QBITTORRENT_PASS}"

QBITTORRENT_URL="${QBITTORRENT_URL%/}"

if [[ -f "$SERVER_SELECTION_FILE" ]]; then
	# shellcheck disable=SC1090
	source "$SERVER_SELECTION_FILE"
	VPN_INTERFACE="${SELECTED_VPN_INTERFACE:-$VPN_INTERFACE}"
fi

PORT="$(awk -F= '/^CURRENT_PORT=/ {print $2; exit}' "$STATE_FILE" 2>/dev/null || true)"

if [[ -z "$PORT" ]]; then
	log "No port found, skipping"
	exit 0
fi

PORT_CHANGED=1
if [[ -f "$CACHE_FILE" ]]; then
	LAST_PORT="$(cat "$CACHE_FILE" 2>/dev/null || true)"
	if [[ "$PORT" == "$LAST_PORT" ]]; then
		PORT_CHANGED=0
	fi
fi

if ((PORT_CHANGED)); then
	log "Updating qBittorrent port -> $PORT"

	AUTH_RESPONSE="$(curl -fsS -i \
		--data "username=$QBITTORRENT_USER&password=$QBITTORRENT_PASS" \
		"$QBITTORRENT_URL/api/v2/auth/login" || true)"
	COOKIE="$(printf '%s' "$AUTH_RESPONSE" | grep -Fi set-cookie | cut -d' ' -f2 | tr -d '\r')"

	if [[ -z "$COOKIE" ]]; then
		log "ERROR: Authentication failed"
		exit 1
	fi

	curl -fsS --cookie "$COOKIE" \
		-X POST \
		--data "json={\"listen_port\":$PORT}" \
		"$QBITTORRENT_URL/api/v2/app/setPreferences" >/dev/null

	umask 077
	echo "$PORT" >"$CACHE_FILE"

	log "qBittorrent updated successfully"
else
	log "Port unchanged ($PORT), skipping qBittorrent API update but refreshing DNAT"
fi

QBT_CONTAINER_NAME="${QBT_CONTAINER_NAME:-qbittorrent}"
QBT_INTERNAL_PORT="${QBT_INTERNAL_PORT:-6881}"
NFT_TABLE="proton_nat"
NFT_CHAIN="prerouting"

ensure_nft_nat() {
	nft list table ip "$NFT_TABLE" >/dev/null 2>&1 || nft add table ip "$NFT_TABLE"
	nft list chain ip "$NFT_TABLE" "$NFT_CHAIN" >/dev/null 2>&1 ||
		nft add chain ip "$NFT_TABLE" "$NFT_CHAIN" '{ type nat hook prerouting priority dstnat ; }'
}

container_ip_for() {
	local name="$1"
	local network="${QBT_NETWORK_NAME:-}"

	if [[ -n "$network" ]]; then
		docker inspect -f "{{.NetworkSettings.Networks.$network.IPAddress}}" "$name" 2>/dev/null || true
		return
	fi

	docker inspect -f '{{range $k,$v := .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$name" 2>/dev/null || true
}

remove_existing_qbt_dnat() {
	if ! nft list chain ip "$NFT_TABLE" "$NFT_CHAIN" -a >/dev/null 2>&1; then
		return 0
	fi

	local handles
	handles=$(nft list chain ip "$NFT_TABLE" "$NFT_CHAIN" -a 2>/dev/null | awk '/qbt-dnat/ {for(i=1;i<=NF;i++) if($i=="handle") print $(i+1)}')
	if [[ -z "$handles" ]]; then
		return 0
	fi

	for h in $handles; do
		nft delete rule ip "$NFT_TABLE" "$NFT_CHAIN" handle "$h" 2>/dev/null || true
	done
}

add_qbt_dnat() {
	local pub_port="$1"
	local cip

	cip=$(container_ip_for "$QBT_CONTAINER_NAME")
	if [[ -z "$cip" ]]; then
		log "WARNING: qBittorrent container '$QBT_CONTAINER_NAME' IP not found; skipping DNAT"
		return 0
	fi

	ensure_nft_nat
	remove_existing_qbt_dnat

	nft add rule ip "$NFT_TABLE" "$NFT_CHAIN" iifname "$VPN_INTERFACE" tcp dport "$pub_port" dnat to "$cip":"$QBT_INTERNAL_PORT" comment "qbt-dnat" ||
		log "ERROR: Failed to add TCP DNAT rule for qBittorrent"
	nft add rule ip "$NFT_TABLE" "$NFT_CHAIN" iifname "$VPN_INTERFACE" udp dport "$pub_port" dnat to "$cip":"$QBT_INTERNAL_PORT" comment "qbt-dnat" ||
		log "ERROR: Failed to add UDP DNAT rule for qBittorrent"

	log "Installed DNAT: ${VPN_INTERFACE} public $pub_port -> $cip:$QBT_INTERNAL_PORT (tcp/udp)"
}

add_qbt_dnat "$PORT"
