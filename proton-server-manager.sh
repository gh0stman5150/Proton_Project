#!/usr/bin/env bash
set -euo pipefail

COMMON_ENV_FILE="${PROTON_COMMON_ENV_FILE:-/etc/proton/proton-common.env}"
if [[ -f "$COMMON_ENV_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$COMMON_ENV_FILE"
fi

LOG_TAG="${LOG_TAG:-proton-server}"
STATE_DIR="${STATE_DIR:-/run/proton}"
SERVER_SELECTION_FILE="${SERVER_SELECTION_FILE:-${STATE_DIR}/current-server.env}"
BAD_SERVER_FILE="${BAD_SERVER_FILE:-${STATE_DIR}/bad-servers.tsv}"
SERVER_RESELECT_FILE="${SERVER_RESELECT_FILE:-${STATE_DIR}/reselect-server.flag}"
WG_PROFILE="${WG_PROFILE:-proton}"
WG_POOL_DIR="${WG_POOL_DIR:-/etc/wireguard/proton-pool}"
BAD_SERVER_COOLDOWN="${BAD_SERVER_COOLDOWN:-900}"
PING_TIMEOUT_SECONDS="${PING_TIMEOUT_SECONDS:-1}"
PING_COUNT="${PING_COUNT:-1}"
SERVER_SWITCH_MIN_IMPROVEMENT_MS="${SERVER_SWITCH_MIN_IMPROVEMENT_MS:-10}"
SERVER_SWITCH_DEGRADED_LATENCY_MS="${SERVER_SWITCH_DEGRADED_LATENCY_MS:-75}"
SERVER_POOL_STRICT_LINT="${SERVER_POOL_STRICT_LINT:-on}"
WG_EXPECTED_DNS="${WG_EXPECTED_DNS:-10.2.0.1}"
WG_LINT_ALLOW_MISSING_DNS="${WG_LINT_ALLOW_MISSING_DNS:-off}"

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

require_common_tools() {
    local cmd

    for cmd in awk chmod date grep mkdir mv paste rm systemd-cat tr; do
        require_command "$cmd"
    done
}

require_selection_tools() {
    local cmd

    for cmd in basename getent ping; do
        require_command "$cmd"
    done
}

require_common_tools

mkdir -p "$STATE_DIR"
chmod 700 "$STATE_DIR"

candidate_configs() {
    if compgen -G "$WG_POOL_DIR/*.conf" >/dev/null; then
        printf '%s\n' "$WG_POOL_DIR"/*.conf
        return 0
    fi

    printf '%s\n' "/etc/wireguard/${WG_PROFILE}.conf"
}

config_profile() {
    basename "$1" .conf
}

config_endpoint_value() {
    awk -F '=' '/^[[:space:]]*Endpoint[[:space:]]*=/ {gsub(/^[[:space:]]+|[[:space:]]+$/, "", $2); print $2; exit}' "$1"
}

config_endpoint_host() {
    local endpoint
    endpoint="$(config_endpoint_value "$1")"
    endpoint="${endpoint%:*}"
    endpoint="${endpoint#[}"
    endpoint="${endpoint%]}"
    echo "$endpoint"
}

config_endpoint_port() {
    local endpoint
    endpoint="$(config_endpoint_value "$1")"
    echo "${endpoint##*:}"
}

config_dns_value() {
    awk -F '=' '/^[[:space:]]*DNS[[:space:]]*=/ {gsub(/^[[:space:]]+|[[:space:]]+$/, "", $2); print $2; exit}' "$1"
}

normalize_csv() {
    printf '%s' "$1" | tr ',' '\n' | awk '
        {
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", $0)
            if ($0 != "") {
                print tolower($0)
            }
        }
    ' | paste -sd, -
}

strict_lint_enabled() {
    [[ "$SERVER_POOL_STRICT_LINT" =~ ^(1|true|yes|on)$ ]]
}

allow_missing_dns() {
    [[ "$WG_LINT_ALLOW_MISSING_DNS" =~ ^(1|true|yes|on)$ ]]
}

lint_config() {
    local config="$1"
    local dns_value expected_dns

    strict_lint_enabled || return 0

    if grep -qiE '^[[:space:]]*(PreUp|PostUp|PreDown|PostDown|SaveConfig)[[:space:]]*=' "$config"; then
        log "Skipping $(config_profile "$config") because it contains disallowed WireGuard hooks or SaveConfig"
        return 1
    fi

    dns_value="$(normalize_csv "$(config_dns_value "$config")")"
    expected_dns="$(normalize_csv "$WG_EXPECTED_DNS")"

    if [[ -z "$dns_value" ]]; then
        if allow_missing_dns; then
            return 0
        fi
        log "Skipping $(config_profile "$config") because it is missing DNS"
        return 1
    fi

    if [[ -n "$expected_dns" && "$dns_value" != "$expected_dns" ]]; then
        log "Skipping $(config_profile "$config") because its DNS does not match WG_EXPECTED_DNS"
        return 1
    fi
}

resolve_endpoint_ip() {
    local host="$1"

    if [[ "$host" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo "$host"
        return 0
    fi

    getent ahostsv4 "$host" | awk 'NR == 1 {print $1}'
}

cleanup_bad_servers() {
    local now tmp_file
    now="$(date +%s)"
    tmp_file="${STATE_DIR}/bad-servers.tmp"

    if [[ -f "$BAD_SERVER_FILE" ]]; then
        awk -F '\t' -v now="$now" 'NF >= 2 && $2 > now {print $0}' "$BAD_SERVER_FILE" > "$tmp_file"
        mv "$tmp_file" "$BAD_SERVER_FILE"
    else
        : > "$BAD_SERVER_FILE"
    fi

    chmod 600 "$BAD_SERVER_FILE"
}

server_is_bad() {
    local profile="$1"
    local now
    now="$(date +%s)"

    [[ -f "$BAD_SERVER_FILE" ]] || return 1

    awk -F '\t' -v profile="$profile" -v now="$now" '
        $1 == profile && $2 > now { found = 1 }
        END { exit found ? 0 : 1 }
    ' "$BAD_SERVER_FILE"
}

measure_latency_ms() {
    local endpoint_ip="$1"

    ping -c "$PING_COUNT" -W "$PING_TIMEOUT_SECONDS" "$endpoint_ip" 2>/dev/null \
        | awk -F '=' '
            /rtt|round-trip/ {
                gsub(/ ms/, "", $2)
                split($2, parts, "/")
                printf "%.0f\n", parts[2]
                exit
            }
        '
}

save_selection() {
    local profile="$1"
    local config="$2"
    local endpoint_host="$3"
    local endpoint_ip="$4"
    local endpoint_port="$5"
    local latency_ms="$6"

    umask 077
    {
        echo "SELECTED_WG_PROFILE=$profile"
        echo "SELECTED_VPN_INTERFACE=$profile"
        echo "SELECTED_CONFIG=$config"
        echo "SELECTED_ENDPOINT_HOST=$endpoint_host"
        echo "SELECTED_ENDPOINT_IP=$endpoint_ip"
        echo "SELECTED_ENDPOINT_PORT=$endpoint_port"
        echo "SELECTED_LATENCY_MS=$latency_ms"
        echo "SELECTED_AT=$(date +%s)"
    } > "$SERVER_SELECTION_FILE"
}

select_best_server() {
    local allow_bad="${1:-0}"
    local best_profile=""
    local best_config=""
    local best_endpoint_host=""
    local best_endpoint_ip=""
    local best_endpoint_port=""
    local best_latency_ms=""
    local current_profile_name=""
    local current_config=""
    local current_endpoint_host=""
    local current_endpoint_ip=""
    local current_endpoint_port=""
    local current_latency_ms=""
    local config

    require_selection_tools
    cleanup_bad_servers
    current_profile_name="$(current_profile)"

    while IFS= read -r config; do
        local profile endpoint_host endpoint_ip endpoint_port latency_ms

        [[ -f "$config" ]] || continue
        profile="$(config_profile "$config")"

        if [[ "$allow_bad" != "1" ]] && server_is_bad "$profile"; then
            log "Skipping cooling-down server $profile"
            continue
        fi

        if ! lint_config "$config"; then
            continue
        fi

        endpoint_host="$(config_endpoint_host "$config")"
        endpoint_port="$(config_endpoint_port "$config")"
        endpoint_ip="$(resolve_endpoint_ip "$endpoint_host" || true)"

        if [[ -z "$endpoint_host" || -z "$endpoint_port" || -z "$endpoint_ip" ]]; then
            log "Skipping $profile because its endpoint could not be resolved"
            continue
        fi

        latency_ms="$(measure_latency_ms "$endpoint_ip" || true)"
        if [[ -z "$latency_ms" ]]; then
            latency_ms=999999
            log "Latency probe failed for $profile, treating it as a fallback candidate"
        fi

        if [[ -z "$best_latency_ms" || "$latency_ms" -lt "$best_latency_ms" ]]; then
            best_profile="$profile"
            best_config="$config"
            best_endpoint_host="$endpoint_host"
            best_endpoint_ip="$endpoint_ip"
            best_endpoint_port="$endpoint_port"
            best_latency_ms="$latency_ms"
        fi

        if [[ "$profile" == "$current_profile_name" ]]; then
            current_config="$config"
            current_endpoint_host="$endpoint_host"
            current_endpoint_ip="$endpoint_ip"
            current_endpoint_port="$endpoint_port"
            current_latency_ms="$latency_ms"
        fi
    done < <(candidate_configs)

    if [[ -z "$best_profile" && "$allow_bad" != "1" ]]; then
        log "No healthy server candidates were available; retrying with cooling-down nodes"
        select_best_server 1
        return $?
    fi

    if [[ -z "$best_profile" ]]; then
        log "No pools available even with cooling-down nodes; aborting"
        log "ERROR: No WireGuard profiles were available for selection."
        exit 1
    fi

    if [[ -f "$SERVER_SELECTION_FILE" && -n "$current_config" && "$best_profile" != "$current_profile_name" && ! server_is_bad "$current_profile_name" ]]; then
        local improvement_ms
        improvement_ms=$((current_latency_ms - best_latency_ms))

        if (( current_latency_ms < SERVER_SWITCH_DEGRADED_LATENCY_MS && improvement_ms < SERVER_SWITCH_MIN_IMPROVEMENT_MS )); then
            log "Keeping current server $current_profile_name (${current_latency_ms}ms); best candidate $best_profile improves latency by only ${improvement_ms}ms"
            best_profile="$current_profile_name"
            best_config="$current_config"
            best_endpoint_host="$current_endpoint_host"
            best_endpoint_ip="$current_endpoint_ip"
            best_endpoint_port="$current_endpoint_port"
            best_latency_ms="$current_latency_ms"
        fi
    fi

    save_selection \
        "$best_profile" \
        "$best_config" \
        "$best_endpoint_host" \
        "$best_endpoint_ip" \
        "$best_endpoint_port" \
        "$best_latency_ms"

    rm -f "$SERVER_RESELECT_FILE"
    log "Selected server $best_profile (${best_endpoint_host}/${best_endpoint_ip}) with latency ${best_latency_ms}ms"
    cat "$SERVER_SELECTION_FILE"
}

current_profile() {
    if [[ -f "$SERVER_SELECTION_FILE" ]]; then
        awk -F '=' '/^SELECTED_WG_PROFILE=/ {print $2; exit}' "$SERVER_SELECTION_FILE"
        return 0
    fi

    echo "$WG_PROFILE"
}

mark_server_bad() {
    local profile="${1:-}"
    local reason="${2:-manual}"
    local expiry now tmp_file

    cleanup_bad_servers

    if [[ -z "$profile" ]]; then
        profile="$(current_profile)"
    fi

    now="$(date +%s)"
    expiry="$((now + BAD_SERVER_COOLDOWN))"
    tmp_file="${STATE_DIR}/bad-servers.tmp"

    awk -F '\t' -v profile="$profile" '$1 != profile {print $0}' "$BAD_SERVER_FILE" 2>/dev/null > "$tmp_file"
    printf '%s\t%s\t%s\n' "$profile" "$expiry" "$reason" >> "$tmp_file"
    mv "$tmp_file" "$BAD_SERVER_FILE"
    chmod 600 "$BAD_SERVER_FILE"
    : > "$SERVER_RESELECT_FILE"
    chmod 600 "$SERVER_RESELECT_FILE"

    log "Marked server $profile bad for ${BAD_SERVER_COOLDOWN}s ($reason)"
}

show_bad_servers() {
    cleanup_bad_servers
    cat "$BAD_SERVER_FILE"
}

reset_bad_servers() {
    rm -f "$BAD_SERVER_FILE"
    rm -f "$SERVER_RESELECT_FILE"
    log "Cleared bad-server cooldown state"
}

case "${1:-select}" in
    select)
        select_best_server "${2:-0}"
        ;;
    current)
        if [[ -f "$SERVER_SELECTION_FILE" ]]; then
            cat "$SERVER_SELECTION_FILE"
        else
            select_best_server 0
        fi
        ;;
    mark-bad)
        mark_server_bad "${2:-}" "${3:-manual}"
        ;;
    show-bad)
        show_bad_servers
        ;;
    reset-bad)
        reset_bad_servers
        ;;
    *)
        echo "Usage: $0 {select|current|mark-bad|show-bad|reset-bad}" >&2
        exit 1
        ;;
esac
