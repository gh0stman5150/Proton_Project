#!/usr/bin/env bash
set -euo pipefail

WG_PROFILE="${WG_PROFILE:-proton}"
VPN_IF="${VPN_IF:-${VPN_INTERFACE:-$WG_PROFILE}}"
DOCKER_NETWORK_CIDR="${DOCKER_NETWORK_CIDR:-}"
DOCKER_FORWARD_CHAIN="${DOCKER_FORWARD_CHAIN:-PROTON_DOCKER_FORWARD}"
NAT_CHAIN="${NAT_CHAIN:-PROTON_POSTROUTING}"
STATE_DIR="${STATE_DIR:-/run/proton}"
DOCKER_NETWORK_CIDR_STATE_FILE="${DOCKER_NETWORK_CIDR_STATE_FILE:-${STATE_DIR}/docker-network-cidr}"
SERVER_SELECTION_FILE="${SERVER_SELECTION_FILE:-${STATE_DIR}/current-server.env}"
SERVER_RESELECT_FILE="${SERVER_RESELECT_FILE:-${STATE_DIR}/reselect-server.flag}"
SERVER_POOL_ENABLED="${SERVER_POOL_ENABLED:-auto}"
SERVER_MANAGER_SCRIPT="${SERVER_MANAGER_SCRIPT:-/usr/local/bin/proton/proton-server-manager.sh}"
WG_POOL_DIR="${WG_POOL_DIR:-/etc/wireguard/proton-pool}"

log() {
    echo "$(date '+%F %T') | $*" | systemd-cat -t proton-killswitch
}

if [[ -z "${LAN_IF:-}" ]]; then
    for _i in 1 2 3 4 5 6; do
        LAN_IF="$(ip route | awk '/default/ {print $5; exit}')"
        [[ -n "$LAN_IF" ]] && break
        log "Waiting for default route (attempt $_i/6)..."
        sleep 5
    done
fi
LAN_IF="${LAN_IF:-}"
LAN_CIDR="${LAN_CIDR:-}"
if [[ -n "$LAN_IF" && -z "$LAN_CIDR" ]]; then
    LAN_CIDR="$(ip -4 route show dev "$LAN_IF" | awk '$1 ~ /^[0-9]/ && $1 != "default" {print $1; exit}')"
fi

require_command() {
    local cmd="$1"

    if ! command -v "$cmd" >/dev/null 2>&1; then
        log "ERROR: Required command '$cmd' is not installed."
        exit 1
    fi
}

for cmd in awk cat chmod ip iptables mkdir systemd-cat tr; do
    require_command "$cmd"
done

mkdir -p "$STATE_DIR"
chmod 700 "$STATE_DIR"

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

add_docker_local_rules() {
    local source_cidr target_cidr

    for source_cidr in ${DOCKER_NETWORK_CIDR//,/ }; do
        source_cidr="$(trim_field "$source_cidr")"
        [[ -n "$source_cidr" ]] || continue

        for target_cidr in ${DOCKER_NETWORK_CIDR//,/ }; do
            target_cidr="$(trim_field "$target_cidr")"
            [[ -n "$target_cidr" ]] || continue
            iptables -A "$DOCKER_FORWARD_CHAIN" -s "$source_cidr" -d "$target_cidr" -j ACCEPT
        done
    done
}

add_lan_to_docker_rules() {
    local cidr

    for cidr in ${DOCKER_NETWORK_CIDR//,/ }; do
        cidr="$(trim_field "$cidr")"
        [[ -n "$cidr" ]] || continue
        iptables -A "$DOCKER_FORWARD_CHAIN" -i "$LAN_IF" -s "$LAN_CIDR" -d "$cidr" -j ACCEPT
    done
}

add_vpn_to_docker_rules() {
    local cidr

    for cidr in ${DOCKER_NETWORK_CIDR//,/ }; do
        cidr="$(trim_field "$cidr")"
        [[ -n "$cidr" ]] || continue
        iptables -A "$DOCKER_FORWARD_CHAIN" -i "$VPN_IF" -d "$cidr" -j ACCEPT
    done
}

add_docker_to_lan_rules() {
    local cidr

    for cidr in ${DOCKER_NETWORK_CIDR//,/ }; do
        cidr="$(trim_field "$cidr")"
        [[ -n "$cidr" ]] || continue
        iptables -A "$DOCKER_FORWARD_CHAIN" -s "$cidr" -o "$LAN_IF" -d "$LAN_CIDR" -p tcp --dport 53 -j DROP
        iptables -A "$DOCKER_FORWARD_CHAIN" -s "$cidr" -o "$LAN_IF" -d "$LAN_CIDR" -p udp --dport 53 -j DROP
        iptables -A "$DOCKER_FORWARD_CHAIN" -s "$cidr" -o "$LAN_IF" -d "$LAN_CIDR" -j ACCEPT
    done
}

add_docker_to_vpn_rules() {
    local cidr

    for cidr in ${DOCKER_NETWORK_CIDR//,/ }; do
        cidr="$(trim_field "$cidr")"
        [[ -n "$cidr" ]] || continue
        iptables -A "$DOCKER_FORWARD_CHAIN" -s "$cidr" -o "$VPN_IF" -j ACCEPT
    done
}

add_docker_drop_rules() {
    local cidr

    for cidr in ${DOCKER_NETWORK_CIDR//,/ }; do
        cidr="$(trim_field "$cidr")"
        [[ -n "$cidr" ]] || continue
        iptables -A "$DOCKER_FORWARD_CHAIN" -s "$cidr" -j DROP
        iptables -A "$DOCKER_FORWARD_CHAIN" -d "$cidr" -j DROP
    done
}

ensure_chain() {
    local chain="$1"

    iptables -N "$chain" 2>/dev/null || true
    iptables -F "$chain"
}

ensure_jump_rule() {
    local parent="$1"
    local chain="$2"

    iptables -D "$parent" -j "$chain" 2>/dev/null || true
    iptables -I "$parent" 1 -j "$chain"
}

ensure_nat_chain() {
    iptables -t nat -N "$NAT_CHAIN" 2>/dev/null || true
    iptables -t nat -F "$NAT_CHAIN"
    iptables -t nat -D POSTROUTING -j "$NAT_CHAIN" 2>/dev/null || true
    iptables -t nat -I POSTROUTING 1 -j "$NAT_CHAIN"
}

load_selected_server

require_value "LAN_IF" "$LAN_IF"
require_value "LAN_CIDR" "$LAN_CIDR"

ensure_chain "$DOCKER_FORWARD_CHAIN"
ensure_nat_chain
ensure_jump_rule FORWARD "$DOCKER_FORWARD_CHAIN"

iptables -A "$DOCKER_FORWARD_CHAIN" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

if [[ -n "$DOCKER_NETWORK_CIDR" ]]; then
    add_docker_local_rules
    add_lan_to_docker_rules
    add_vpn_to_docker_rules
    add_docker_to_lan_rules
    add_docker_to_vpn_rules
    add_docker_drop_rules
else
    log "WARNING: DOCKER_NETWORK_CIDR is empty; Docker leak-prevention rules were not installed"
fi

iptables -A "$DOCKER_FORWARD_CHAIN" -j RETURN
iptables -A "$NAT_CHAIN" -o "$VPN_IF" -j MASQUERADE

if [[ -n "$DOCKER_NETWORK_CIDR" ]]; then
    log "iptables Docker kill switch applied for [$DOCKER_NETWORK_CIDR] on $LAN_IF -> $VPN_IF; DNS to LAN is blocked and non-Docker host traffic is untouched"
else
    log "iptables Docker kill switch applied without Docker CIDR state; non-Docker host traffic is untouched"
fi

