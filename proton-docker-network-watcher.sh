#!/usr/bin/env bash
set -euo pipefail

# Proton Docker Network Watcher
# Watches Docker network/container events and idempotently re-applies
# Docker -> VPN policy routing and refreshes the qBittorrent DNAT mapping.

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTANCE_COMMON_SCRIPT="${PROTON_INSTANCE_COMMON_SCRIPT:-${DIR}/proton-instance-common.sh}"
if [[ ! -f "$INSTANCE_COMMON_SCRIPT" ]]; then
	echo "ERROR: Proton instance helper not found: $INSTANCE_COMMON_SCRIPT" >&2
	exit 1
fi
# shellcheck disable=SC1090
source "$INSTANCE_COMMON_SCRIPT"
proton_instance_init "${1:-}"

LOGTAG="proton-docker-watch"
log() { echo "$(date '+%F %T') | $*" | systemd-cat -t "$LOGTAG"; }

DEBOUNCE_SECONDS="${DEBOUNCE_SECONDS:-5}"
POLL_INTERVAL="${POLL_INTERVAL:-60}"
VPN_INTERFACE="${VPN_INTERFACE:-proton}"
VPN_TABLE="${VPN_TABLE:-51820}"
RULE_PRIORITY="${RULE_PRIORITY:-110}"
LAN_IF="${LAN_IF:-}"
LAN_CIDR="${LAN_CIDR:-}"
QBT_CONTAINER_NAME="${QBT_CONTAINER_NAME:-}"
QBT_NETWORK_NAME="${QBT_NETWORK_NAME:-}"
QBT_CONTAINER_IP_STATE_FILE="${QBT_CONTAINER_IP_STATE_FILE:-${STATE_DIR}/qbt-container-ip}"
QBT_CONTAINER_IP6_STATE_FILE="${QBT_CONTAINER_IP6_STATE_FILE:-${STATE_DIR}/qbt-container-ip6}"
DOCKER_NETWORK_CIDR6="${DOCKER_NETWORK_CIDR6:-}"
DOCKER_LOCAL_RULE_PRIORITY="${DOCKER_LOCAL_RULE_PRIORITY:-108}"
DOCKER_LAN_RULE_PRIORITY="${DOCKER_LAN_RULE_PRIORITY:-109}"
DOCKER_VPN_RULE_PRIORITY="${DOCKER_VPN_RULE_PRIORITY:-$RULE_PRIORITY}"
QBT_VPN_RULE_PRIORITY="${QBT_VPN_RULE_PRIORITY:-$DOCKER_VPN_RULE_PRIORITY}"
DOCKER_FALLBACK_VPN_RULE_PRIORITY="${DOCKER_FALLBACK_VPN_RULE_PRIORITY:-130}"
DOCKER_FALLBACK_VPN_ROUTING="${DOCKER_FALLBACK_VPN_ROUTING:-on}"
DOCKER_IPV6_FALLBACK_INSTANCE="${DOCKER_IPV6_FALLBACK_INSTANCE:-sonarr}"
LAST_FILE="${LAST_FILE:-/run/proton/docker-network-watcher.last}"
LAST6_FILE="${LAST6_FILE:-${STATE_DIR}/docker-network-watcher6.last}"
QBT_SYNC_SCRIPT="${QBT_SYNC_SCRIPT:-$DIR/proton-qbittorrent-sync-safe.sh}"
QBITTORRENT_ENV_FILE="${QBITTORRENT_ENV_FILE:-/etc/proton/qbittorrent.env}"
STATE_DIR="${STATE_DIR:-/run/proton}"
SERVER_SELECTION_FILE="${SERVER_SELECTION_FILE:-${STATE_DIR}/current-server.env}"
DOCKER_NETWORK_CIDR_STATE_FILE="${DOCKER_NETWORK_CIDR_STATE_FILE:-${STATE_DIR}/docker-network-cidr}"
KILLSWITCH_SCRIPT="${KILLSWITCH_SCRIPT:-$DIR/proton-killswitch-dispatch.sh}"

mkdir -p "$STATE_DIR"
chmod 700 "$STATE_DIR" 2>/dev/null || true
touch "$LAST_FILE" 2>/dev/null || true

load_selected_server() {
	if [[ -f "$SERVER_SELECTION_FILE" ]]; then
		# shellcheck disable=SC1090
		source "$SERVER_SELECTION_FILE"
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
		cidr=$(docker network inspect -f '{{range .IPAM.Config}}{{println .Subnet}}{{end}}' "$QBT_NETWORK_NAME" 2>/dev/null | awk '!/:/ {print; exit}' || true)
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
		cidr=$(docker network inspect -f '{{range .IPAM.Config}}{{println .Subnet}}{{end}}' "$candidate" 2>/dev/null | awk '!/:/ {print; exit}' || true)
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
			cidr=$(docker network inspect -f '{{range .IPAM.Config}}{{println .Subnet}}{{end}}' "$net" 2>/dev/null | awk '!/:/ {print; exit}' || true)
			[[ -n "$cidr" ]] && {
				echo "$cidr"
				return 0
			}
		fi
	fi

	echo ""
}

find_network_cidr6() {
	local cidr=""
	local network="${QBT_NETWORK_NAME:-}"

	command -v docker >/dev/null 2>&1 || {
		echo ""
		return 0
	}
	if [[ -z "$network" ]]; then
		network="$(docker network ls --format '{{.Name}}' | grep -i starr | head -n1 || true)"
	fi
	if [[ -n "$network" ]]; then
		cidr="$(docker network inspect -f '{{range .IPAM.Config}}{{println .Subnet}}{{end}}' "$network" 2>/dev/null | awk '/:/ {print; exit}' || true)"
	fi
	printf '%s\n' "$cidr"
}

trim_field() {
	local value="$1"
	value="${value#"${value%%[![:space:]]*}"}"
	value="${value%"${value##*[![:space:]]}"}"
	printf '%s\n' "$value"
}

is_ipv4_address() {
	local value="$1"
	local octet
	local -a octets=()

	[[ "$value" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
	IFS='.' read -r -a octets <<<"$value"
	[[ "${#octets[@]}" -eq 4 ]] || return 1

	for octet in "${octets[@]}"; do
		[[ "$octet" =~ ^[0-9]+$ ]] || return 1
		((10#$octet <= 255)) || return 1
	done
}

normalize_ipv4_rule_source() {
	local value="$1"
	local addr=""
	local prefix=""

	value="$(trim_field "$value")"
	[[ -n "$value" ]] || return 1
	if [[ "$value" == */* ]]; then
		addr="${value%%/*}"
		prefix="${value#*/}"
		is_ipv4_address "$addr" || return 1
		[[ "$prefix" =~ ^[0-9]+$ ]] || return 1
		((prefix >= 0 && prefix <= 32)) || return 1
		printf '%s/%s\n' "$addr" "$prefix"
	else
		is_ipv4_address "$value" || return 1
		printf '%s/32\n' "$value"
	fi
}

normalize_ipv6_rule_source() {
	local value="$1"

	value="$(trim_field "$value")"
	[[ "$value" == *:* ]] || return 1
	printf '%s/128\n' "${value%%/*}"
}

docker_fallback_vpn_routing_enabled() {
	case "$DOCKER_FALLBACK_VPN_ROUTING" in
	1 | true | yes | on)
		return 0
		;;
	*)
		return 1
		;;
	esac
}

resolve_qbt_container_ip() {
	local networks=""
	local ip=""

	[[ -n "$QBT_CONTAINER_NAME" ]] || return 1
	command -v docker >/dev/null 2>&1 || return 1

	networks="$(docker inspect -f '{{range $name, $network := .NetworkSettings.Networks}}{{printf "%s=%s\n" $name $network.IPAddress}}{{end}}' "$QBT_CONTAINER_NAME" 2>/dev/null || true)"
	[[ -n "$networks" ]] || return 1

	if [[ -n "$QBT_NETWORK_NAME" ]]; then
		ip="$(awk -F= -v target="$QBT_NETWORK_NAME" '$1 == target && $2 != "" {print $2; exit}' <<<"$networks")"
	fi

	if [[ -z "$ip" ]]; then
		ip="$(awk -F= '$2 != "" {print $2; exit}' <<<"$networks")"
	fi

	[[ -n "$ip" ]] || return 1
	printf '%s\n' "$ip"
}

resolve_qbt_container_ipv6() {
	local networks=""
	local ip=""

	[[ -n "$QBT_CONTAINER_NAME" ]] || return 1
	command -v docker >/dev/null 2>&1 || return 1
	networks="$(docker inspect -f '{{range $name, $network := .NetworkSettings.Networks}}{{printf "%s=%s\n" $name $network.GlobalIPv6Address}}{{end}}' "$QBT_CONTAINER_NAME" 2>/dev/null || true)"
	[[ -n "$networks" ]] || return 1
	if [[ -n "$QBT_NETWORK_NAME" ]]; then
		ip="$(awk -F= -v target="$QBT_NETWORK_NAME" '$1 == target && $2 != "" {print $2; exit}' <<<"$networks")"
	fi
	[[ -n "$ip" ]] || ip="$(awk -F= '$2 != "" {print $2; exit}' <<<"$networks")"
	[[ -n "$ip" ]] || return 1
	printf '%s\n' "$ip"
}

read_cached_qbt_container_ip() {
	[[ -f "$QBT_CONTAINER_IP_STATE_FILE" ]] || return 1
	cat "$QBT_CONTAINER_IP_STATE_FILE" 2>/dev/null || true
}

persist_qbt_container_ip() {
	local value="${1:-}"

	if [[ -n "$value" ]]; then
		umask 077
		printf '%s' "$value" >"$QBT_CONTAINER_IP_STATE_FILE" || true
	else
		rm -f "$QBT_CONTAINER_IP_STATE_FILE" 2>/dev/null || true
	fi
}

read_cached_qbt_container_ipv6() {
	[[ -f "$QBT_CONTAINER_IP6_STATE_FILE" ]] || return 1
	cat "$QBT_CONTAINER_IP6_STATE_FILE" 2>/dev/null || true
}

persist_qbt_container_ipv6() {
	local value="${1:-}"
	if [[ -n "$value" ]]; then
		umask 077
		printf '%s' "$value" >"$QBT_CONTAINER_IP6_STATE_FILE" || true
	else
		rm -f "$QBT_CONTAINER_IP6_STATE_FILE" 2>/dev/null || true
	fi
}

docker_ipv6_fallback_enabled() {
	docker_fallback_vpn_routing_enabled && [[ "$INSTANCE" == "$DOCKER_IPV6_FALLBACK_INSTANCE" ]]
}

reapply_routes() {
	local new_cidr="$1"
	local new_cidr6="${2:-}"
	local old_cidr=""
	local new_qbt_ip=""
	local old_qbt_ip=""
	local new_qbt_rule_source=""
	local old_qbt_rule_source=""
	local old_cidr6=""
	local new_qbt_ipv6=""
	local old_qbt_ipv6=""
	local new_qbt_ipv6_rule_source=""
	local old_qbt_ipv6_rule_source=""

	load_selected_server
	if [[ -f "$LAST_FILE" ]]; then
		old_cidr="$(cat "$LAST_FILE" 2>/dev/null || true)"
	fi
	old_qbt_ip="$(read_cached_qbt_container_ip || true)"
	new_qbt_ip="$(resolve_qbt_container_ip || true)"
	new_qbt_rule_source="$(normalize_ipv4_rule_source "$new_qbt_ip" || true)"
	old_qbt_rule_source="$(normalize_ipv4_rule_source "$old_qbt_ip" || true)"
	[[ -f "$LAST6_FILE" ]] && old_cidr6="$(cat "$LAST6_FILE" 2>/dev/null || true)"
	old_qbt_ipv6="$(read_cached_qbt_container_ipv6 || true)"
	new_qbt_ipv6="$(resolve_qbt_container_ipv6 || true)"
	new_qbt_ipv6_rule_source="$(normalize_ipv6_rule_source "$new_qbt_ipv6" || true)"
	old_qbt_ipv6_rule_source="$(normalize_ipv6_rule_source "$old_qbt_ipv6" || true)"

	if [[ -n "$old_cidr" || -n "$new_cidr" ]]; then
		detect_lan_cidr
	fi

	if [[ -n "$old_cidr" && "$old_cidr" != "$new_cidr" ]]; then
		log "Removing old Docker policy rules for $old_cidr"
		ip rule del from "$old_cidr" to "$old_cidr" lookup main priority "$DOCKER_LOCAL_RULE_PRIORITY" 2>/dev/null || true
		if [[ -n "$LAN_CIDR" ]]; then
			ip rule del from "$old_cidr" to "$LAN_CIDR" lookup main priority "$DOCKER_LAN_RULE_PRIORITY" 2>/dev/null || true
		fi
		ip rule del from "$old_cidr" lookup "$VPN_TABLE" priority "$DOCKER_VPN_RULE_PRIORITY" 2>/dev/null || true
		ip rule del from "$old_cidr" lookup "$VPN_TABLE" priority "$DOCKER_FALLBACK_VPN_RULE_PRIORITY" 2>/dev/null || true
		if command -v iptables >/dev/null 2>&1; then
			iptables -t raw -D PREROUTING -i "$VPN_INTERFACE" -d "$old_cidr" -j ACCEPT 2>/dev/null || true
		fi
	fi

	if [[ -n "$new_cidr" ]]; then
		log "Applying Docker policy routing for $INSTANCE on $new_cidr via table $VPN_TABLE and $VPN_INTERFACE"
		ip rule add from "$new_cidr" to "$new_cidr" lookup main priority "$DOCKER_LOCAL_RULE_PRIORITY" 2>/dev/null || true
		if [[ -n "$LAN_CIDR" ]]; then
			ip rule add from "$new_cidr" to "$LAN_CIDR" lookup main priority "$DOCKER_LAN_RULE_PRIORITY" 2>/dev/null || true
		fi
		ip rule del from "$new_cidr" lookup 51820 priority "$DOCKER_VPN_RULE_PRIORITY" 2>/dev/null || true
		ip rule del from "$new_cidr" lookup "$VPN_TABLE" priority "$DOCKER_VPN_RULE_PRIORITY" 2>/dev/null || true
		ip rule del from "$new_cidr" lookup "$VPN_TABLE" priority "$DOCKER_FALLBACK_VPN_RULE_PRIORITY" 2>/dev/null || true
		if docker_fallback_vpn_routing_enabled; then
			ip rule add from "$new_cidr" lookup "$VPN_TABLE" priority "$DOCKER_FALLBACK_VPN_RULE_PRIORITY" 2>/dev/null || true
		fi
		if command -v iptables >/dev/null 2>&1; then
			iptables -t raw -D PREROUTING -i "$VPN_INTERFACE" -d "$new_cidr" -j ACCEPT 2>/dev/null || true
			iptables -t raw -I PREROUTING 1 -i "$VPN_INTERFACE" -d "$new_cidr" -j ACCEPT 2>/dev/null || true
		fi
	else
		log "No docker network detected; docker->VPN source rule removed"
	fi

	if [[ -n "$old_qbt_rule_source" ]]; then
		ip rule del from "$old_qbt_rule_source" lookup "$VPN_TABLE" priority "$QBT_VPN_RULE_PRIORITY" 2>/dev/null || true
	fi

	if [[ -n "$new_qbt_rule_source" ]]; then
		ip rule del from "$new_qbt_rule_source" lookup "$VPN_TABLE" priority "$QBT_VPN_RULE_PRIORITY" 2>/dev/null || true
		ip rule add from "$new_qbt_rule_source" lookup "$VPN_TABLE" priority "$QBT_VPN_RULE_PRIORITY" 2>/dev/null || true
		persist_qbt_container_ip "$new_qbt_ip"
		log "qBittorrent policy routing refreshed: source $new_qbt_rule_source -> table $VPN_TABLE via $VPN_INTERFACE"
	else
		persist_qbt_container_ip ""
		if [[ -n "$QBT_CONTAINER_NAME" ]]; then
			log "WARNING: Could not resolve an IPv4 address for $QBT_CONTAINER_NAME; qBittorrent remains on Docker fallback routing"
		fi
	fi

	if [[ -n "$old_qbt_ipv6_rule_source" ]]; then
		ip -6 rule del from "$old_qbt_ipv6_rule_source" lookup "$VPN_TABLE" priority "$QBT_VPN_RULE_PRIORITY" 2>/dev/null || true
	fi
	if [[ -n "$old_cidr6" && "$old_cidr6" != "$new_cidr6" ]]; then
		ip -6 rule del from "$old_cidr6" to "$old_cidr6" lookup main priority "$DOCKER_LOCAL_RULE_PRIORITY" 2>/dev/null || true
		ip -6 rule del from "$old_cidr6" lookup "$VPN_TABLE" priority "$DOCKER_FALLBACK_VPN_RULE_PRIORITY" 2>/dev/null || true
	fi
	if [[ -n "$new_cidr6" ]]; then
		ip -6 rule del from "$new_cidr6" to "$new_cidr6" lookup main priority "$DOCKER_LOCAL_RULE_PRIORITY" 2>/dev/null || true
		ip -6 rule add from "$new_cidr6" to "$new_cidr6" lookup main priority "$DOCKER_LOCAL_RULE_PRIORITY" 2>/dev/null || true
		ip -6 rule del from "$new_cidr6" lookup "$VPN_TABLE" priority "$DOCKER_FALLBACK_VPN_RULE_PRIORITY" 2>/dev/null || true
		if docker_ipv6_fallback_enabled; then
			ip -6 rule add from "$new_cidr6" lookup "$VPN_TABLE" priority "$DOCKER_FALLBACK_VPN_RULE_PRIORITY" 2>/dev/null || true
		fi
	fi
	if [[ -n "$new_qbt_ipv6_rule_source" ]]; then
		ip -6 rule del from "$new_qbt_ipv6_rule_source" lookup "$VPN_TABLE" priority "$QBT_VPN_RULE_PRIORITY" 2>/dev/null || true
		ip -6 rule add from "$new_qbt_ipv6_rule_source" lookup "$VPN_TABLE" priority "$QBT_VPN_RULE_PRIORITY" 2>/dev/null || true
		persist_qbt_container_ipv6 "$new_qbt_ipv6"
		log "qBittorrent IPv6 policy routing refreshed: source $new_qbt_ipv6_rule_source -> table $VPN_TABLE via $VPN_INTERFACE"
	else
		persist_qbt_container_ipv6 ""
	fi

	printf "%s" "$new_cidr" >"$LAST_FILE" || true
	if [[ -n "$new_cidr" ]]; then
		umask 077
		printf "%s" "$new_cidr" >"$DOCKER_NETWORK_CIDR_STATE_FILE" || true
	else
		rm -f "$DOCKER_NETWORK_CIDR_STATE_FILE" 2>/dev/null || true
	fi
	printf "%s" "$new_cidr6" >"$LAST6_FILE" || true
}

reapply_killswitch() {
	if [[ -x "$KILLSWITCH_SCRIPT" ]]; then
		log "Reapplying Docker kill-switch state via $KILLSWITCH_SCRIPT"
		"$KILLSWITCH_SCRIPT" || log "Warning: kill-switch script exited with non-zero status"
	else
		log "Kill-switch script not found at $KILLSWITCH_SCRIPT; skipping firewall reconciliation"
	fi
}

refresh_qb_state() {
	# Prefer triggering the systemd allocator which serializes port allocation
	if command -v systemctl >/dev/null 2>&1; then
		log "Triggering systemd allocator: proton-qbt-allocate@${INSTANCE}"
		if ! systemctl start "proton-qbt-allocate@${INSTANCE}"; then
			log "Warning: systemd allocator failed for ${INSTANCE}; falling back to direct sync"
			if [[ -x "$QBT_SYNC_SCRIPT" ]]; then
				log "Refreshing qBittorrent state via $QBT_SYNC_SCRIPT"
				"$QBT_SYNC_SCRIPT" "$INSTANCE" || log "Warning: qB sync script exited with non-zero status"
			else
				log "qB sync script not found at $QBT_SYNC_SCRIPT; skipping qBittorrent reconciliation"
			fi
		fi
	else
		if [[ -x "$QBT_SYNC_SCRIPT" ]]; then
			log "Refreshing qBittorrent state via $QBT_SYNC_SCRIPT"
			"$QBT_SYNC_SCRIPT" "$INSTANCE" || log "Warning: qB sync script exited with non-zero status"
		else
			log "qB sync script not found at $QBT_SYNC_SCRIPT; skipping qBittorrent reconciliation"
		fi
	fi
}

graceful_shutdown() {
	log "Shutting down"
	exit 0
}
trap graceful_shutdown INT TERM

main() {
	local cidr cidr6
	cidr=$(find_network_cidr)
	cidr6=$(find_network_cidr6)
	reapply_routes "$cidr" "$cidr6"
	reapply_killswitch
	refresh_qb_state

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
						cidr6=$(find_network_cidr6)
						reapply_routes "$cidr" "$cidr6"
						reapply_killswitch
						refresh_qb_state
						;;
					*) ;;
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
			cidr6=$(find_network_cidr6)
			reapply_routes "$cidr" "$cidr6"
			reapply_killswitch
			refresh_qb_state
		done
	fi
}

if [[ "${PROTON_WATCHER_SOURCE_ONLY:-0}" != 1 ]]; then
	main
fi
