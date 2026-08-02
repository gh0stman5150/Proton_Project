#!/usr/bin/env bash
set -euo pipefail

WG_PROFILE="${WG_PROFILE:-proton}"
VPN_IF="${VPN_IF:-${VPN_INTERFACE:-$WG_PROFILE}}"
DOCKER_NETWORK_CIDR="${DOCKER_NETWORK_CIDR:-}"
DOCKER_NETWORK_CIDR6="${DOCKER_NETWORK_CIDR6:-}"
STATE_DIR="${STATE_DIR:-/run/proton}"
KILLSWITCH_LOCK_FILE="${KILLSWITCH_LOCK_FILE:-${STATE_DIR}/killswitch.lock}"
DOCKER_NETWORK_CIDR_STATE_FILE="${DOCKER_NETWORK_CIDR_STATE_FILE:-${STATE_DIR}/docker-network-cidr}"
SERVER_SELECTION_FILE="${SERVER_SELECTION_FILE:-${STATE_DIR}/current-server.env}"
SERVER_RESELECT_FILE="${SERVER_RESELECT_FILE:-${STATE_DIR}/reselect-server.flag}"
SERVER_POOL_ENABLED="${SERVER_POOL_ENABLED:-auto}"
SERVER_MANAGER_SCRIPT="${SERVER_MANAGER_SCRIPT:-/usr/local/bin/proton/proton-server-manager.sh}"
WG_POOL_DIR="${WG_POOL_DIR:-/etc/wireguard/proton-pool}"

log() {
	echo "$(date '+%F %T') | $*" | systemd-cat -t proton-killswitch
}

LAN_IF="${LAN_IF:-}"
LAN_CIDR="${LAN_CIDR:-}"
# Wait for BOTH the default-route interface and its connected subnet route.
# network-online.target can fire before DHCP has reinstalled the connected
# route (e.g. after a WAN IP change or reconnect), which previously left
# LAN_CIDR empty and failed the kill switch permanently. Retry both here.
if [[ -z "$LAN_IF" || -z "$LAN_CIDR" ]]; then
	for _i in 1 2 3 4 5 6 7 8 9 10; do
		if [[ -z "$LAN_IF" ]]; then
			LAN_IF="$(ip route | awk '/default/ {print $5; exit}')"
		fi
		if [[ -n "$LAN_IF" && -z "$LAN_CIDR" ]]; then
			LAN_CIDR="$(ip -4 route show dev "$LAN_IF" | awk '$1 ~ /^[0-9]/ && $1 != "default" {print $1; exit}')"
		fi
		[[ -n "$LAN_IF" && -n "$LAN_CIDR" ]] && break
		log "Waiting for LAN interface/subnet route (attempt $_i/10)..."
		sleep 3
	done
fi

require_command() {
	local cmd="$1"

	if ! command -v "$cmd" >/dev/null 2>&1; then
		log "ERROR: Required command '$cmd' is not installed."
		exit 1
	fi
}

for cmd in awk cat chmod flock ip mkdir nft systemd-cat; do
	require_command "$cmd"
done

ensure_directory() {
	local dir="$1"
	local mode="${2:-}"
	local created=0

	if [[ ! -d "$dir" ]]; then
		mkdir -p "$dir"
		created=1
	fi

	if ((created)) && [[ -n "$mode" ]]; then
		chmod "$mode" "$dir"
	fi
}

ensure_directory "$STATE_DIR" 700

exec 9>"$KILLSWITCH_LOCK_FILE"
if ! flock -w 30 9; then
	log "ERROR: Timed out waiting for kill-switch lock: $KILLSWITCH_LOCK_FILE"
	exit 1
fi

if [[ -z "$DOCKER_NETWORK_CIDR" && -f "$DOCKER_NETWORK_CIDR_STATE_FILE" ]]; then
	DOCKER_NETWORK_CIDR="$(cat "$DOCKER_NETWORK_CIDR_STATE_FILE" 2>/dev/null || true)"
fi

server_pool_requested() {
	case "$SERVER_POOL_ENABLED" in
	1 | true | yes | on)
		return 0
		;;
	auto)
		compgen -G "$WG_POOL_DIR/*.conf" >/dev/null
		;;
	*)
		return 1
		;;
	esac
}

load_selected_server() {
	if ! server_pool_requested; then
		return 0
	fi

	if [[ ! -x "$SERVER_MANAGER_SCRIPT" ]]; then
		log "ERROR: Server manager script is not executable: $SERVER_MANAGER_SCRIPT"
		exit 1
	fi

	if [[ -f "$SERVER_SELECTION_FILE" && ! -f "$SERVER_RESELECT_FILE" ]]; then
		# shellcheck disable=SC1090
		source "$SERVER_SELECTION_FILE"
	else
		"$SERVER_MANAGER_SCRIPT" select >/dev/null
	fi

	if [[ -f "$SERVER_SELECTION_FILE" ]]; then
		# shellcheck disable=SC1090
		source "$SERVER_SELECTION_FILE"
		VPN_IF="${SELECTED_VPN_INTERFACE:-$VPN_IF}"
	fi
}

require_value() {
	local name="$1"
	local value="$2"

	if [[ -z "$value" ]]; then
		log "ERROR: Missing required value for $name"
		exit 1
	fi
}

trim_field() {
	local value="$1"
	value="${value#"${value%%[![:space:]]*}"}"
	value="${value%"${value##*[![:space:]]}"}"
	printf '%s\n' "$value"
}

ensure_nat_postrouting_chain() {
	nft list table ip proton_nat >/dev/null 2>&1 || nft add table ip proton_nat
	nft list chain ip proton_nat postrouting >/dev/null 2>&1 ||
		nft 'add chain ip proton_nat postrouting { type nat hook postrouting priority srcnat; policy accept; }'
}

ensure_nat6_postrouting_chain() {
	[[ -n "$DOCKER_NETWORK_CIDR6" ]] || return 0
	nft list table ip6 proton_nat6 >/dev/null 2>&1 || nft add table ip6 proton_nat6
	nft list chain ip6 proton_nat6 postrouting >/dev/null 2>&1 ||
		nft 'add chain ip6 proton_nat6 postrouting { type nat hook postrouting priority srcnat; policy accept; }'
}

ensure_masquerade_rule() {
	local handles="" iface added=0

	for iface in $(vpn_interfaces); do
		[[ -n "$iface" ]] || continue
		ip link show "$iface" >/dev/null 2>&1 || continue

		handles="$(
			nft -a list chain ip proton_nat postrouting 2>/dev/null |
				awk -v vpn_if="$iface" '
                $0 ~ ("oifname \"" vpn_if "\"") && /masquerade/ {
                    for (i = 1; i <= NF; i++) {
                        if ($i == "handle") print $(i + 1)
                    }
                }
            '
		)"

		if [[ -n "$handles" ]]; then
			while read -r handle; do
				[[ -n "$handle" ]] || continue
				nft delete rule ip proton_nat postrouting handle "$handle" 2>/dev/null || true
			done <<<"$handles"
		fi

		nft add rule ip proton_nat postrouting oifname "$iface" masquerade comment "proton-wg-snat"
		added=1
	done

	if ((!added)); then
		log "INFO: no VPN interface up yet, skipping NAT setup"
	fi
}

ensure_masquerade6_rule() {
	local handles="" iface added=0

	[[ -n "$DOCKER_NETWORK_CIDR6" ]] || return 0
	for iface in $(vpn_interfaces); do
		[[ -n "$iface" ]] || continue
		ip link show "$iface" >/dev/null 2>&1 || continue

		handles="$(
			nft -a list chain ip6 proton_nat6 postrouting 2>/dev/null |
				awk -v vpn_if="$iface" '
                $0 ~ ("oifname \"" vpn_if "\"") && /masquerade/ {
                    for (i = 1; i <= NF; i++) {
                        if ($i == "handle") print $(i + 1)
                    }
                }
            '
		)"

		if [[ -n "$handles" ]]; then
			while read -r handle; do
				[[ -n "$handle" ]] || continue
				nft delete rule ip6 proton_nat6 postrouting handle "$handle" 2>/dev/null || true
			done <<<"$handles"
		fi

		nft add rule ip6 proton_nat6 postrouting ip6 saddr "$DOCKER_NETWORK_CIDR6" \
			oifname "$iface" masquerade comment "proton-wg-snat6"
		added=1
	done

	if ((!added)); then
		log "INFO: no VPN interface up yet, skipping IPv6 NAT setup"
	fi
}

render_docker_local_rules() {
	local source_cidr target_cidr

	for source_cidr in ${DOCKER_NETWORK_CIDR//,/ }; do
		source_cidr="$(trim_field "$source_cidr")"
		[[ -n "$source_cidr" ]] || continue

		for target_cidr in ${DOCKER_NETWORK_CIDR//,/ }; do
			target_cidr="$(trim_field "$target_cidr")"
			[[ -n "$target_cidr" ]] || continue
			printf '        ip saddr %s ip daddr %s accept\n' "$source_cidr" "$target_cidr"
		done
	done
}

render_lan_to_docker_rules() {
	local cidr

	for cidr in ${DOCKER_NETWORK_CIDR//,/ }; do
		cidr="$(trim_field "$cidr")"
		[[ -n "$cidr" ]] || continue
		printf '        iifname "%s" ip saddr %s ip daddr %s accept\n' "$LAN_IF" "$LAN_CIDR" "$cidr"
	done
}

# List every active Proton WireGuard interface. All WireGuard interfaces on
# this host are Proton tunnels, so Docker application egress is permitted via
# any of them. With per-instance tunnels (pvlidarr, pvradarr, ...) sharing one
# routing table, the interface that carries Docker egress can be any active
# tunnel, so the kill switch must accept egress through all of them rather than
# a single VPN_IF. Falls back to VPN_IF when no WireGuard interface is up yet.
vpn_interfaces() {
	local ifaces=""

	if command -v wg >/dev/null 2>&1; then
		ifaces="$(wg show interfaces 2>/dev/null || true)"
	fi

	if [[ -z "$ifaces" ]]; then
		ifaces="$VPN_IF"
	fi

	printf '%s\n' $ifaces
}

render_vpn_to_docker_rules() {
	local cidr iface

	for iface in $(vpn_interfaces); do
		[[ -n "$iface" ]] || continue
		for cidr in ${DOCKER_NETWORK_CIDR//,/ }; do
			cidr="$(trim_field "$cidr")"
			[[ -n "$cidr" ]] || continue
			printf '        iifname "%s" ip daddr %s accept\n' "$iface" "$cidr"
		done
	done
}

render_docker_to_lan_rules() {
	local cidr

	for cidr in ${DOCKER_NETWORK_CIDR//,/ }; do
		cidr="$(trim_field "$cidr")"
		[[ -n "$cidr" ]] || continue
		printf '        oifname "%s" ip saddr %s ip daddr %s tcp dport 53 drop\n' "$LAN_IF" "$cidr" "$LAN_CIDR"
		printf '        oifname "%s" ip saddr %s ip daddr %s udp dport 53 drop\n' "$LAN_IF" "$cidr" "$LAN_CIDR"
		printf '        oifname "%s" ip saddr %s ip daddr %s accept\n' "$LAN_IF" "$cidr" "$LAN_CIDR"
	done
}

render_docker_to_vpn_rules() {
	local cidr iface

	for iface in $(vpn_interfaces); do
		[[ -n "$iface" ]] || continue
		for cidr in ${DOCKER_NETWORK_CIDR//,/ }; do
			cidr="$(trim_field "$cidr")"
			[[ -n "$cidr" ]] || continue
			printf '        oifname "%s" ip saddr %s accept\n' "$iface" "$cidr"
		done
	done
}

render_docker_drop_rules() {
	local cidr

	for cidr in ${DOCKER_NETWORK_CIDR//,/ }; do
		cidr="$(trim_field "$cidr")"
		[[ -n "$cidr" ]] || continue
		printf '        ip saddr %s drop\n' "$cidr"
		printf '        ip daddr %s drop\n' "$cidr"
	done
}

render_docker6_local_rules() {
	local source_cidr target_cidr

	for source_cidr in ${DOCKER_NETWORK_CIDR6//,/ }; do
		source_cidr="$(trim_field "$source_cidr")"
		[[ -n "$source_cidr" ]] || continue
		for target_cidr in ${DOCKER_NETWORK_CIDR6//,/ }; do
			target_cidr="$(trim_field "$target_cidr")"
			[[ -n "$target_cidr" ]] || continue
			printf '        ip6 saddr %s ip6 daddr %s accept\n' "$source_cidr" "$target_cidr"
		done
	done
}

render_vpn_to_docker6_rules() {
	local cidr iface

	for iface in $(vpn_interfaces); do
		[[ -n "$iface" ]] || continue
		for cidr in ${DOCKER_NETWORK_CIDR6//,/ }; do
			cidr="$(trim_field "$cidr")"
			[[ -n "$cidr" ]] || continue
			printf '        iifname "%s" ip6 daddr %s accept\n' "$iface" "$cidr"
		done
	done
}

render_docker6_to_vpn_rules() {
	local cidr iface

	for iface in $(vpn_interfaces); do
		[[ -n "$iface" ]] || continue
		for cidr in ${DOCKER_NETWORK_CIDR6//,/ }; do
			cidr="$(trim_field "$cidr")"
			[[ -n "$cidr" ]] || continue
			printf '        oifname "%s" ip6 saddr %s accept\n' "$iface" "$cidr"
		done
	done
}

render_docker6_drop_rules() {
	local cidr

	for cidr in ${DOCKER_NETWORK_CIDR6//,/ }; do
		cidr="$(trim_field "$cidr")"
		[[ -n "$cidr" ]] || continue
		printf '        ip6 saddr %s drop\n' "$cidr"
		printf '        ip6 daddr %s drop\n' "$cidr"
	done
}

load_selected_server

require_value "LAN_IF" "$LAN_IF"
require_value "LAN_CIDR" "$LAN_CIDR"

ensure_nat_postrouting_chain
ensure_masquerade_rule
ensure_nat6_postrouting_chain
ensure_masquerade6_rule

FILTER_TABLE_DELETE=""
if nft list table inet proton >/dev/null 2>&1; then
	FILTER_TABLE_DELETE="delete table inet proton"
fi

nft -f - <<EOF
$FILTER_TABLE_DELETE
table inet proton {
    chain forward {
        type filter hook forward priority 0; policy accept;
        ct state established,related accept
$(render_docker_local_rules)
$(render_lan_to_docker_rules)
$(render_vpn_to_docker_rules)
$(render_docker_to_lan_rules)
$(render_docker_to_vpn_rules)
$(render_docker_drop_rules)
$(render_docker6_local_rules)
$(render_vpn_to_docker6_rules)
$(render_docker6_to_vpn_rules)
$(render_docker6_drop_rules)
    }
}
EOF

if [[ -n "$DOCKER_NETWORK_CIDR" || -n "$DOCKER_NETWORK_CIDR6" ]]; then
	log "nftables Docker kill switch applied for IPv4 [$DOCKER_NETWORK_CIDR] IPv6 [$DOCKER_NETWORK_CIDR6] on $LAN_IF -> $VPN_IF; DNS to LAN is blocked and non-Docker host traffic is untouched"
else
	log "nftables Docker kill switch applied without Docker CIDR state; non-Docker host traffic is untouched"
fi
