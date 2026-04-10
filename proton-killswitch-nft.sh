#!/usr/bin/env bash
set -euo pipefail

WG_PROFILE="${WG_PROFILE:-proton}"
VPN_IF="${VPN_IF:-${VPN_INTERFACE:-$WG_PROFILE}}"
DOCKER_NETWORK_CIDR="${DOCKER_NETWORK_CIDR:-}"
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

for cmd in awk cat chmod ip mkdir nft systemd-cat; do
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

    if (( created )) && [[ -n "$mode" ]]; then
        chmod "$mode" "$dir"
    fi
}

ensure_directory "$STATE_DIR" 700

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
    nft list chain ip proton_nat postrouting >/dev/null 2>&1 || \
        nft 'add chain ip proton_nat postrouting { type nat hook postrouting priority srcnat; policy accept; }'
}

ensure_masquerade_rule() {
    local handles=""

    if ! ip link show "$VPN_IF" >/dev/null 2>&1; then
        log "INFO: VPN interface $VPN_IF not up yet, skipping NAT setup"
        return 0
    fi

    handles="$(
        nft -a list chain ip proton_nat postrouting 2>/dev/null | \
        awk -v vpn_if="$VPN_IF" '
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
        done <<< "$handles"
    fi

    nft add rule ip proton_nat postrouting oifname "$VPN_IF" masquerade comment "proton-wg-snat"
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

render_vpn_to_docker_rules() {
    local cidr

    for cidr in ${DOCKER_NETWORK_CIDR//,/ }; do
        cidr="$(trim_field "$cidr")"
        [[ -n "$cidr" ]] || continue
        printf '        iifname "%s" ip daddr %s accept\n' "$VPN_IF" "$cidr"
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
    local cidr

    for cidr in ${DOCKER_NETWORK_CIDR//,/ }; do
        cidr="$(trim_field "$cidr")"
        [[ -n "$cidr" ]] || continue
        printf '        oifname "%s" ip saddr %s accept\n' "$VPN_IF" "$cidr"
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

load_selected_server

require_value "LAN_IF" "$LAN_IF"
require_value "LAN_CIDR" "$LAN_CIDR"

nft delete table inet proton 2>/dev/null || true
ensure_nat_postrouting_chain
ensure_masquerade_rule

nft -f - <<EOF
table inet proton {
    chain forward {
        type filter hook forward priority 0; policy accept;
        ct state established,related accept
$(render_docker_local_rules)$(render_lan_to_docker_rules)$(render_vpn_to_docker_rules)$(render_docker_to_lan_rules)$(render_docker_to_vpn_rules)$(render_docker_drop_rules)
    }
}
EOF

if [[ -n "$DOCKER_NETWORK_CIDR" ]]; then
    log "nftables Docker kill switch applied for [$DOCKER_NETWORK_CIDR] on $LAN_IF -> $VPN_IF; DNS to LAN is blocked and non-Docker host traffic is untouched"
else
    log "nftables Docker kill switch applied without Docker CIDR state; non-Docker host traffic is untouched"
fi
