#!/usr/bin/env bash
set -euo pipefail

# Proton Docker Network Watcher
# Watches Docker network/container events and idempotently re-applies
# Docker -> VPN policy routing and refreshes the qBittorrent DNAT mapping.

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOGTAG="proton-docker-watch"
log() { echo "$(date '+%F %T') | $*" | systemd-cat -t "$LOGTAG"; }

DEBOUNCE_SECONDS="${DEBOUNCE_SECONDS:-5}"
POLL_INTERVAL="${POLL_INTERVAL:-60}"
VPN_INTERFACE="${VPN_INTERFACE:-proton}"
VPN_TABLE="${VPN_TABLE:-51820}"
RULE_PRIORITY="${RULE_PRIORITY:-110}"
LAN_IF="${LAN_IF:-}"
LAN_CIDR="${LAN_CIDR:-}"
DOCKER_LOCAL_RULE_PRIORITY="${DOCKER_LOCAL_RULE_PRIORITY:-108}"
DOCKER_LAN_RULE_PRIORITY="${DOCKER_LAN_RULE_PRIORITY:-109}"
DOCKER_VPN_RULE_PRIORITY="${DOCKER_VPN_RULE_PRIORITY:-$RULE_PRIORITY}"
LAST_FILE="${LAST_FILE:-/run/proton/docker-network-watcher.last}"
QBT_SYNC_SCRIPT="${QBT_SYNC_SCRIPT:-$DIR/proton-qbittorrent-sync-safe.sh}"
QBITTORRENT_ENV_FILE="${QBITTORRENT_ENV_FILE:-/etc/proton/qbittorrent.env}"
STATE_DIR="${STATE_DIR:-/run/proton}"
SERVER_SELECTION_FILE="${SERVER_SELECTION_FILE:-${STATE_DIR}/current-server.env}"
DOCKER_NETWORK_CIDR_STATE_FILE="${DOCKER_NETWORK_CIDR_STATE_FILE:-${STATE_DIR}/docker-network-cidr}"

mkdir -p /run/proton
touch "$LAST_FILE" 2>/dev/null || true

# Optional environment files (installer places qB vars here)
if [[ -f "$QBITTORRENT_ENV_FILE" ]]; then
	# shellcheck disable=SC1090
	source "$QBITTORRENT_ENV_FILE"
fi
if [[ -f /etc/proton/proton-common.env ]]; then
	# shellcheck disable=SC1090
	source /etc/proton/proton-common.env
fi

load_selected_server() {
	if [[ -f "$SERVER_SELECTION_FILE" ]]; then
		# shellcheck disable=SC1090
		source "$SERVER_SELECTION_FILE"
		VPN_INTERFACE="${SELECTED_VPN_INTERFACE:-$VPN_INTERFACE}"
	fi
}

detect_lan_cidr() {
	if [[ -n "$LAN_CIDR" ]]; then
		return 0
	fi

	if [[ -z "$LAN_IF" ]]; then
		LAN_IF="$(ip route | awk '/default/ {print $5; exit}')"
	fi

	if [[ -n "$LAN_IF" ]]; then
		LAN_CIDR="$(ip -4 route show dev "$LAN_IF" | awk '$1 ~ /^[0-9]/ && $1 != "default" {print $1; exit}')"
	fi
}

find_network_cidr() {
	local cidr=""

	# If a specific network name is configured, prefer it
	if [[ -n "${QBT_NETWORK_NAME:-}" && -n "$(command -v docker 2>/dev/null)" ]]; then
		cidr=$(docker network inspect -f '{{range .IPAM.Config}}{{.Subnet}}{{end}}' "$QBT_NETWORK_NAME" 2>/dev/null || true)
		[[ -n "$cidr" ]] && {
			echo "$cidr"
			return 0
		}
	fi

	# If docker CLI not available, nothing to do
	if ! command -v docker >/dev/null 2>&1; then
		echo ""
		return 0
	fi

	# Auto-detect a network called 'starr' (case-insensitive)
	local candidate
	candidate=$(docker network ls --format '{{.Name}}' | grep -i starr | head -n1 || true)
	if [[ -n "$candidate" ]]; then
		cidr=$(docker network inspect -f '{{range .IPAM.Config}}{{.Subnet}}{{end}}' "$candidate" 2>/dev/null || true)
		[[ -n "$cidr" ]] && {
			echo "$cidr"
			return 0
		}
	fi

	# Fallback: inspect the qB container's first attached network
	if [[ -n "${QBT_CONTAINER_NAME:-}" ]]; then
		local nets
		nets=$(docker inspect -f '{{range $k,$v := .NetworkSettings.Networks}}{{$k}} {{end}}' "$QBT_CONTAINER_NAME" 2>/dev/null || true)
		if [[ -n "$nets" ]]; then
			local net
			net=$(awk '{print $1}' <<<"$nets")
			cidr=$(docker network inspect -f '{{range .IPAM.Config}}{{.Subnet}}{{end}}' "$net" 2>/dev/null || true)
			[[ -n "$cidr" ]] && {
				echo "$cidr"
				return 0
			}
		fi
	fi

	echo ""
}

reapply_routes() {
	local new_cidr="$1"
	local old_cidr=""

	load_selected_server
	if [[ -f "$LAST_FILE" ]]; then
		old_cidr="$(cat "$LAST_FILE" 2>/dev/null || true)"
	fi

	if [[ -n "$old_cidr" || -n "$new_cidr" ]]; then
		detect_lan_cidr
	fi

	# Nothing changed
	if [[ "$new_cidr" == "$old_cidr" ]]; then
		return 0
	fi

	if [[ -n "$old_cidr" ]]; then
		log "Removing old Docker policy rules for $old_cidr"
		ip rule del from "$old_cidr" to "$old_cidr" lookup main priority "$DOCKER_LOCAL_RULE_PRIORITY" 2>/dev/null || true
		if [[ -n "$LAN_CIDR" ]]; then
			ip rule del from "$old_cidr" to "$LAN_CIDR" lookup main priority "$DOCKER_LAN_RULE_PRIORITY" 2>/dev/null || true
		fi
		ip rule del from "$old_cidr" lookup "$VPN_TABLE" priority "$DOCKER_VPN_RULE_PRIORITY" 2>/dev/null || true
		if command -v iptables >/dev/null 2>&1; then
			iptables -t raw -D PREROUTING -i "$VPN_INTERFACE" -d "$old_cidr" -j ACCEPT 2>/dev/null || true
		fi
	fi

	if [[ -n "$new_cidr" ]]; then
		log "Applying Docker policy routing: $new_cidr -> table $VPN_TABLE via $VPN_INTERFACE while keeping local Docker/LAN traffic on main"
		ip rule add from "$new_cidr" to "$new_cidr" lookup main priority "$DOCKER_LOCAL_RULE_PRIORITY" 2>/dev/null || true
		if [[ -n "$LAN_CIDR" ]]; then
			ip rule add from "$new_cidr" to "$LAN_CIDR" lookup main priority "$DOCKER_LAN_RULE_PRIORITY" 2>/dev/null || true
		fi
		ip rule add from "$new_cidr" lookup "$VPN_TABLE" priority "$DOCKER_VPN_RULE_PRIORITY" 2>/dev/null || true
		if command -v iptables >/dev/null 2>&1; then
			iptables -t raw -D PREROUTING -i "$VPN_INTERFACE" -d "$new_cidr" -j ACCEPT 2>/dev/null || true
			iptables -t raw -I PREROUTING 1 -i "$VPN_INTERFACE" -d "$new_cidr" -j ACCEPT 2>/dev/null || true
		fi
	else
		log "No docker network detected; docker->VPN source rule removed"
	fi

	printf "%s" "$new_cidr" >"$LAST_FILE" || true
	if [[ -n "$new_cidr" ]]; then
		umask 077
		printf "%s" "$new_cidr" >"$DOCKER_NETWORK_CIDR_STATE_FILE" || true
	else
		rm -f "$DOCKER_NETWORK_CIDR_STATE_FILE" 2>/dev/null || true
	fi
}

refresh_qb_dnat() {
	if [[ -x "$QBT_SYNC_SCRIPT" ]]; then
		log "Refreshing qBittorrent sync/DNAT via $QBT_SYNC_SCRIPT"
		"$QBT_SYNC_SCRIPT" || log "Warning: qB sync script exited with non-zero status"
	else
		log "qB sync script not found at $QBT_SYNC_SCRIPT; skipping DNAT refresh"
	fi
}

graceful_shutdown() {
	log "Shutting down"
	exit 0
}
trap graceful_shutdown INT TERM

# Initial reconciliation
_initial() {
	local cidr
	cidr=$(find_network_cidr)
	reapply_routes "$cidr"
	refresh_qb_dnat
}

_initial

if command -v docker >/dev/null 2>&1; then
	log "Starting docker events watch (debounce ${DEBOUNCE_SECONDS}s)"
	while true; do
		# Listen to network/container events and debounce updates
		docker events \
			--filter 'type=network' --filter 'type=container' \
			--format '{{.Type}}:{{.Action}}:{{.Actor.Attributes.name}}' 2>/dev/null |
			while IFS= read -r ev; do
				case "$ev" in
				*:create:* | *:connect:* | *:disconnect:* | *:start:* | *:destroy:*)
					log "Docker event: $ev -- waiting ${DEBOUNCE_SECONDS}s"
					sleep "$DEBOUNCE_SECONDS"
					cidr=$(find_network_cidr)
					reapply_routes "$cidr"
					refresh_qb_dnat
					;;
				*)
					;;
				esac
			done

		log "docker events stream exited; retrying in 5s"
		sleep 5
	done
else
	log "docker CLI not present; running periodic check every ${POLL_INTERVAL}s"
	while true; do
		sleep "$POLL_INTERVAL"
		cidr=$(find_network_cidr)
		reapply_routes "$cidr"
		refresh_qb_dnat
	done
fi
