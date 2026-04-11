#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_DIR="/usr/local/bin/proton"
ETC_PROTON_DIR="/etc/proton"
SYSTEMD_DIR="/etc/systemd/system"
WG_POOL_DIR="/etc/wireguard/proton-pool"
WG_RUNTIME_DIR="/etc/wireguard/proton-runtime"
FORCE_ENV=0
QBITTORRENT_URL_VALUE=""
QBITTORRENT_USER_VALUE=""
QBITTORRENT_PASS_VALUE=""
QBT_CONTAINER_NAME_VALUE=""
QBT_INTERNAL_PORT_VALUE=""
QBT_NETWORK_NAME_VALUE=""

SERVICES=(
    proton-killswitch.service
    proton-wg.service
    proton-port-forward.service
    proton-healthcheck.service
)

OPTIONAL_SERVICES=(
    proton-docker-watch.service
)

SCRIPTS=(
    install-proton-systemd.sh
    proton-killswitch-dispatch.sh
    proton-killswitch-safe.sh
    proton-killswitch-nft.sh
    proton-killswitch-reset.sh
    proton-port-forward-healthcheck.sh
    proton-port-forward-safe.sh
    proton-qbittorrent-common.sh
    proton-qbittorrent-sync-safe.sh
    proton-qbt-dnat-cleanup.sh
    proton-docker-network-watcher.sh
    proton-server-manager.sh
    proton-wg-up-safe.sh
    proton-wg-down-safe.sh
    proton-healthcheck.sh
)

ENV_FILES=(
    proton-common.env
    proton-port-forward.env
    proton-healthcheck.env
)

log() {
    printf '%s\n' "$*"
}

usage() {
    cat <<'EOF'
Usage: install-proton-systemd.sh [options]

Options:
  --qb-url URL        Set QBITTORRENT_URL in /etc/proton/qbittorrent.env
  --qb-user USER      Set QBITTORRENT_USER in /etc/proton/qbittorrent.env
  --qb-pass PASS      Set QBITTORRENT_PASS in /etc/proton/qbittorrent.env
  --qb-container NAME Set QBT_CONTAINER_NAME in /etc/proton/qbittorrent.env
  --qb-int-port PORT  Set QBT_INTERNAL_PORT in /etc/proton/qbittorrent.env
  --qb-network NAME   Set QBT_NETWORK_NAME in /etc/proton/qbittorrent.env
  --force-env         Overwrite env files in /etc/proton instead of writing *.new
  --help              Show this help text
EOF
}

require_command() {
    local cmd="$1"

    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "ERROR: Required command '$cmd' is not installed." >&2
        exit 1
    fi
}

validate_shell_syntax() {
    local path="$1"

    if ! bash -n "$path"; then
        echo "ERROR: Shell syntax validation failed for $path" >&2
        exit 1
    fi
}

normalize_text_file() {
    local source_file="$1"
    local output_file="$2"
    local bom

    bom="$(printf '\357\273\277')"
    awk -v bom="$bom" '
        NR == 1 { sub("^" bom, "") }
        { sub(/\r$/, ""); print }
    ' "$source_file" > "$output_file"
}

install_normalized_file() {
    local source_file="$1"
    local target_file="$2"
    local mode="$3"
    local tmp_file

    tmp_file="$(mktemp)"
    normalize_text_file "$source_file" "$tmp_file"
    install -o root -g root -m "$mode" "$tmp_file" "$target_file"
    rm -f "$tmp_file"
}

ensure_source_file() {
    local path="$1"

    if [[ ! -f "$path" ]]; then
        echo "ERROR: Required source file not found: $path" >&2
        exit 1
    fi
}

validate_bundle() {
    local name

    for name in "${SCRIPTS[@]}"; do
        ensure_source_file "${SCRIPT_DIR}/${name}"
        validate_shell_syntax "${SCRIPT_DIR}/${name}"
    done

    validate_shell_syntax "${SCRIPT_DIR}/install-proton-systemd.sh"

    for name in "${SERVICES[@]}"; do
        ensure_source_file "${SCRIPT_DIR}/${name}"
    done

    for name in "${OPTIONAL_SERVICES[@]}"; do
        ensure_source_file "${SCRIPT_DIR}/${name}"
    done

    for name in "${ENV_FILES[@]}"; do
        ensure_source_file "${SCRIPT_DIR}/${name}"
    done

    ensure_source_file "${SCRIPT_DIR}/proton-qbittorrent.env"
    ensure_source_file "${SCRIPT_DIR}/proton-qbittorrent-port.env"
}

load_common_env() {
    local env_file="${ETC_PROTON_DIR}/proton-common.env"

    if [[ -f "$env_file" ]]; then
        # shellcheck disable=SC1090
        source "$env_file"
    fi
}

load_port_forward_env() {
    local env_file="${ETC_PROTON_DIR}/proton-port-forward.env"

    if [[ -f "$env_file" ]]; then
        # shellcheck disable=SC1090
        source "$env_file"
    fi
}

validate_wireguard_config() {
    local resolved_profile resolved_config available_configs

    resolved_profile="${WG_PROFILE:-proton}"
    resolved_config="${WG_CONFIG:-/etc/wireguard/${resolved_profile}.conf}"

    if [[ "${SERVER_POOL_ENABLED:-auto}" =~ ^(1|true|yes|on|auto)$ ]] && compgen -G "${WG_POOL_DIR:-/etc/wireguard/proton-pool}/*.conf" >/dev/null; then
        return 0
    fi

    if [[ -f "$resolved_config" ]]; then
        return 0
    fi

    available_configs="$(find /etc/wireguard -maxdepth 1 -type f -name '*.conf' -printf '  - %f\n' 2>/dev/null || true)"

    echo "ERROR: WireGuard config not found: ${resolved_config}" >&2
    echo "Update ${ETC_PROTON_DIR}/proton-common.env so WG_PROFILE/VPN_INTERFACE match your real WireGuard profile before starting the Proton services." >&2

    if [[ -n "$available_configs" ]]; then
        echo "Available WireGuard configs:" >&2
        printf '%s' "$available_configs" >&2
    fi

    exit 1
}

secure_wireguard_config() {
    local resolved_profile resolved_config

    resolved_profile="${WG_PROFILE:-proton}"
    resolved_config="${WG_CONFIG:-/etc/wireguard/${resolved_profile}.conf}"

    if [[ "${SERVER_POOL_ENABLED:-auto}" =~ ^(1|true|yes|on|auto)$ ]] && compgen -G "${WG_POOL_DIR:-/etc/wireguard/proton-pool}/*.conf" >/dev/null; then
        chown root:root "${WG_POOL_DIR:-/etc/wireguard/proton-pool}"/*.conf
        chmod 0600 "${WG_POOL_DIR:-/etc/wireguard/proton-pool}"/*.conf
        log "Secured pool configs under ${WG_POOL_DIR:-/etc/wireguard/proton-pool} with owner root:root and mode 0600"
        return 0
    fi

    chown root:root "$resolved_config"
    chmod 0600 "$resolved_config"
    log "Secured ${resolved_config} with owner root:root and mode 0600"
}

canonical_path() {
    local path="$1"
    local dir base

    dir="$(cd "$(dirname "$path")" && pwd -P)"
    base="$(basename "$path")"
    printf '%s/%s\n' "$dir" "$base"
}

same_path() {
    [[ "$(canonical_path "$1")" == "$(canonical_path "$2")" ]]
}

ensure_root() {
    if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
        echo "ERROR: Run this installer as root." >&2
        exit 1
    fi
}

install_service_file() {
    local name="$1"
    local source_file target_file

    source_file="${SCRIPT_DIR}/${name}"
    target_file="${SYSTEMD_DIR}/${name}"
    ensure_source_file "$source_file"

    if same_path "$source_file" "$target_file"; then
        install_normalized_file "$source_file" "$target_file" 0644
        log "Using existing ${target_file}"
        return 0
    fi

    install_normalized_file "$source_file" "$target_file" 0644
}

install_script_file() {
    local name="$1"
    local source_file target_file

    source_file="${SCRIPT_DIR}/${name}"
    target_file="${BIN_DIR}/${name}"
    ensure_source_file "$source_file"

    if same_path "$source_file" "$target_file"; then
        install_normalized_file "$source_file" "$target_file" 0755
        log "Using existing ${target_file}"
        return 0
    fi

    install_normalized_file "$source_file" "$target_file" 0755
}

install_env_template() {
    local name="$1"
    local mode="$2"
    local source_file target_file

    source_file="${SCRIPT_DIR}/${name}"
    target_file="${ETC_PROTON_DIR}/${name}"
    ensure_source_file "$source_file"

    if same_path "$source_file" "$target_file"; then
        install_normalized_file "$source_file" "$target_file" "$mode"
        log "Using existing ${target_file}"
        return 0
    fi

    if [[ "$FORCE_ENV" -eq 0 && -f "${target_file}" ]]; then
        install_normalized_file "${source_file}" "${target_file}.new" "$mode"
        log "Preserved ${target_file}; wrote updated template to ${target_file}.new"
        chown root:root "${target_file}"
        chmod "$mode" "${target_file}"
        return 0
    fi

    install_normalized_file "${source_file}" "${target_file}" "$mode"
}

install_qbittorrent_env() {
    local source_file target_file tmp_file current_url current_user current_pass
    local current_apply_mode current_compose_project_dir current_compose_service current_port_env
    local current_container current_internal_port current_network

    source_file="${SCRIPT_DIR}/proton-qbittorrent.env"
    target_file="${ETC_PROTON_DIR}/qbittorrent.env"
    tmp_file="${ETC_PROTON_DIR}/qbittorrent.env.tmp"
    ensure_source_file "$source_file"

    if same_path "$source_file" "$target_file"; then
        chown root:root "$target_file"
        chmod 0600 "$target_file"
        log "Using existing ${target_file}"
        return 0
    fi

    if [[ "$FORCE_ENV" -eq 0 \
        && -z "$QBITTORRENT_URL_VALUE" && -z "$QBITTORRENT_USER_VALUE" && -z "$QBITTORRENT_PASS_VALUE" \
        && -z "$QBT_CONTAINER_NAME_VALUE" && -z "$QBT_INTERNAL_PORT_VALUE" && -z "$QBT_NETWORK_NAME_VALUE" \
        && -f "${target_file}" ]]; then
        install -o root -g root -m 0600 "${source_file}" "${target_file}.new"
        log "Preserved ${target_file}; wrote updated template to ${target_file}.new"
        chown root:root "${target_file}"
        chmod 0600 "${target_file}"
        return 0
    fi

    install -o root -g root -m 0600 "${source_file}" "${tmp_file}"

    if [[ -f "$target_file" ]]; then
        current_url="$(awk -F= '/^QBITTORRENT_URL=/ {print $2; exit}' "${target_file}")"
        current_user="$(awk -F= '/^QBITTORRENT_USER=/ {print $2; exit}' "${target_file}")"
        current_pass="$(awk -F= '/^QBITTORRENT_PASS=/ {print $2; exit}' "${target_file}")"
        current_apply_mode="$(awk -F= '/^QBT_PORT_APPLY_MODE=/ {print $2; exit}' "${target_file}")"
        current_compose_project_dir="$(awk -F= '/^QBT_COMPOSE_PROJECT_DIR=/ {print $2; exit}' "${target_file}")"
        current_compose_service="$(awk -F= '/^QBT_COMPOSE_SERVICE=/ {print $2; exit}' "${target_file}")"
        current_port_env="$(awk -F= '/^QBT_PORT_ENV_FILE=/ {print $2; exit}' "${target_file}")"
        current_container="$(awk -F= '/^QBT_CONTAINER_NAME=/ {print $2; exit}' "${target_file}")"
        current_internal_port="$(awk -F= '/^QBT_INTERNAL_PORT=/ {print $2; exit}' "${target_file}")"
        current_network="$(awk -F= '/^QBT_NETWORK_NAME=/ {print $2; exit}' "${target_file}")"
    else
        current_url="$(awk -F= '/^QBITTORRENT_URL=/ {print $2; exit}' "${tmp_file}")"
        current_user="$(awk -F= '/^QBITTORRENT_USER=/ {print $2; exit}' "${tmp_file}")"
        current_pass="$(awk -F= '/^QBITTORRENT_PASS=/ {print $2; exit}' "${tmp_file}")"
        current_apply_mode="$(awk -F= '/^QBT_PORT_APPLY_MODE=/ {print $2; exit}' "${tmp_file}")"
        current_compose_project_dir="$(awk -F= '/^QBT_COMPOSE_PROJECT_DIR=/ {print $2; exit}' "${tmp_file}")"
        current_compose_service="$(awk -F= '/^QBT_COMPOSE_SERVICE=/ {print $2; exit}' "${tmp_file}")"
        current_port_env="$(awk -F= '/^QBT_PORT_ENV_FILE=/ {print $2; exit}' "${tmp_file}")"
        current_container="$(awk -F= '/^QBT_CONTAINER_NAME=/ {print $2; exit}' "${tmp_file}")"
        current_internal_port="$(awk -F= '/^QBT_INTERNAL_PORT=/ {print $2; exit}' "${tmp_file}")"
        current_network="$(awk -F= '/^QBT_NETWORK_NAME=/ {print $2; exit}' "${tmp_file}")"
    fi

    current_url="${QBITTORRENT_URL_VALUE:-$current_url}"
    current_user="${QBITTORRENT_USER_VALUE:-$current_user}"
    current_pass="${QBITTORRENT_PASS_VALUE:-$current_pass}"
    current_apply_mode="${current_apply_mode:-compose-recreate}"
    current_compose_project_dir="${current_compose_project_dir:-}"
    current_compose_service="${current_compose_service:-qbittorrent}"
    current_port_env="${current_port_env:-/etc/proton/qbittorrent-port.env}"
    current_container="${QBT_CONTAINER_NAME_VALUE:-${current_container:-qbittorrent}}"
    current_internal_port="${QBT_INTERNAL_PORT_VALUE:-${current_internal_port:-6881}}"
    current_network="${QBT_NETWORK_NAME_VALUE:-$current_network}"

    cat > "${tmp_file}" <<EOF
# qBittorrent credentials for the host-side Proton services.
# These scripts run on the host, so point QBITTORRENT_URL at the host-published
# Web UI port rather than the Docker-internal starr_network address.

QBITTORRENT_URL=${current_url}
QBITTORRENT_USER=${current_user}
QBITTORRENT_PASS=${current_pass}
# Default path: update qBittorrent's listen port, persist the published port,
# and recreate the Compose service only when the forwarded port changes.
QBT_PORT_APPLY_MODE=${current_apply_mode}
# Directory containing the qBittorrent docker-compose.yml / compose.yaml file.
QBT_COMPOSE_PROJECT_DIR=${current_compose_project_dir}
QBT_COMPOSE_SERVICE=${current_compose_service}
QBT_PORT_ENV_FILE=${current_port_env}
# Legacy DNAT mode only: container identity and container-network lookup.
QBT_CONTAINER_NAME=${current_container}
QBT_INTERNAL_PORT=${current_internal_port}
# Optional: Docker network name where qBittorrent runs (used to lookup container IP). If blank, the first network IP will be used.
QBT_NETWORK_NAME=${current_network}
EOF

    install -o root -g root -m 0600 "${tmp_file}" "${target_file}"
    rm -f "${tmp_file}"
}

install_qbittorrent_port_env() {
    local source_file target_file

    source_file="${SCRIPT_DIR}/proton-qbittorrent-port.env"
    target_file="${ETC_PROTON_DIR}/qbittorrent-port.env"
    ensure_source_file "$source_file"

    if same_path "$source_file" "$target_file"; then
        chown root:root "$target_file"
        chmod 0600 "$target_file"
        log "Using existing ${target_file}"
        return 0
    fi

    if [[ "$FORCE_ENV" -eq 0 && -f "${target_file}" ]]; then
        install -o root -g root -m 0600 "${source_file}" "${target_file}.new"
        log "Preserved ${target_file}; wrote updated template to ${target_file}.new"
        chown root:root "${target_file}"
        chmod 0600 "${target_file}"
        return 0
    fi

    install -o root -g root -m 0600 "${source_file}" "${target_file}"
}

path_dirname() {
    local path="$1"

    if [[ "$path" == */* ]]; then
        printf '%s\n' "${path%/*}"
    else
        printf '.\n'
    fi
}

resolve_rw_dir() {
    local path="$1"
    local path_dir resolved

    path_dir="$(path_dirname "$path")"

    if [[ -e "$path" ]]; then
        resolved="$(readlink -f "$path" 2>/dev/null || true)"
        if [[ -n "$resolved" ]]; then
            path_dir="$(path_dirname "$resolved")"
        fi
    elif [[ -d "$path_dir" ]]; then
        resolved="$(readlink -f "$path_dir" 2>/dev/null || true)"
        if [[ -n "$resolved" ]]; then
            path_dir="$resolved"
        fi
    fi

    printf '%s\n' "$path_dir"
}

install_qbittorrent_rw_dropin() {
    local service_name="$1"
    local base_paths="$2"
    local extra_path="$3"
    local dropin_dir dropin_file

    dropin_dir="${SYSTEMD_DIR}/${service_name}.d"
    dropin_file="${dropin_dir}/zz-qbittorrent-port-env.conf"

    if [[ -z "$extra_path" || "$extra_path" == "/run/proton" ]]; then
        rm -f "$dropin_file"
        return 0
    fi

    mkdir -p "$dropin_dir"
    cat > "$dropin_file" <<EOF
[Service]
ReadWritePaths=${base_paths} ${extra_path}
EOF
    chown root:root "$dropin_dir" "$dropin_file"
    chmod 0755 "$dropin_dir"
    chmod 0644 "$dropin_file"
}

install_qbittorrent_service_dropins() {
    local qb_env_file port_env_file port_env_dir

    qb_env_file="${ETC_PROTON_DIR}/qbittorrent.env"
    port_env_file="/etc/proton/qbittorrent-port.env"

    if [[ -f "$qb_env_file" ]]; then
        port_env_file="$(awk -F= '/^QBT_PORT_ENV_FILE=/ {print $2; exit}' "$qb_env_file")"
        port_env_file="${port_env_file:-/etc/proton/qbittorrent-port.env}"
    fi

    port_env_dir="$(resolve_rw_dir "$port_env_file")"

    install_qbittorrent_rw_dropin \
        "proton-port-forward.service" \
        "/run/proton /etc/wireguard/proton-runtime /etc/proton" \
        "$port_env_dir"
    install_qbittorrent_rw_dropin \
        "proton-healthcheck.service" \
        "/run/proton" \
        "$port_env_dir"
}

stop_proton_services_for_redeploy() {
    log "Stopping active Proton services before reinstall/redeploy"
    systemctl stop "${OPTIONAL_SERVICES[@]}" "${SERVICES[@]}" >/dev/null 2>&1 || true
}

restart_enabled_optional_services() {
    local service

    for service in "${OPTIONAL_SERVICES[@]}"; do
        if systemctl is-enabled --quiet "$service" >/dev/null 2>&1; then
            systemctl restart "$service"
        fi
    done
}

reset_runtime_state_for_redeploy() {
    local runtime_state_dir bad_server_file server_selection_file server_reselect_file
    local recovery_lock_file port_state_file pf_incapable_file

    runtime_state_dir="${STATE_DIR:-/run/proton}"
    bad_server_file="${BAD_SERVER_FILE:-${runtime_state_dir}/bad-servers.tsv}"
    server_selection_file="${SERVER_SELECTION_FILE:-${runtime_state_dir}/current-server.env}"
    server_reselect_file="${SERVER_RESELECT_FILE:-${runtime_state_dir}/reselect-server.flag}"
    recovery_lock_file="${RECOVERY_LOCK_FILE:-${runtime_state_dir}/recovery.lock}"
    port_state_file="${STATE_FILE:-${runtime_state_dir}/proton-port.state}"
    pf_incapable_file="${PF_INCAPABLE_PROFILES_FILE:-${ETC_PROTON_DIR}/pf-incapable-profiles.tsv}"

    log "Resetting stale Proton runtime and failure state before service restart"

    rm -f \
        "$bad_server_file" \
        "$server_selection_file" \
        "$server_reselect_file" \
        "$recovery_lock_file" \
        "$port_state_file" \
        "$pf_incapable_file"
}

enable_and_start_services() {
    systemctl daemon-reload
    systemctl enable "${SERVICES[@]}"
    systemctl reset-failed "${OPTIONAL_SERVICES[@]}" "${SERVICES[@]}" >/dev/null 2>&1 || true
    reset_runtime_state_for_redeploy
    systemctl restart proton-killswitch.service
    systemctl restart proton-wg.service
    systemctl restart proton-port-forward.service
    systemctl restart proton-healthcheck.service
    restart_enabled_optional_services
}

ensure_root

while [[ $# -gt 0 ]]; do
    case "$1" in
        --qb-url)
            QBITTORRENT_URL_VALUE="${2:?Missing value for --qb-url}"
            shift 2
            ;;
        --qb-user)
            QBITTORRENT_USER_VALUE="${2:?Missing value for --qb-user}"
            shift 2
            ;;
        --qb-pass)
            QBITTORRENT_PASS_VALUE="${2:?Missing value for --qb-pass}"
            shift 2
            ;;
        --qb-container)
            QBT_CONTAINER_NAME_VALUE="${2:?Missing value for --qb-container}"
            shift 2
            ;;
        --qb-int-port)
            QBT_INTERNAL_PORT_VALUE="${2:?Missing value for --qb-int-port}"
            shift 2
            ;;
        --qb-network)
            QBT_NETWORK_NAME_VALUE="${2:?Missing value for --qb-network}"
            shift 2
            ;;
        --force-env)
            FORCE_ENV=1
            shift
            ;;
        --help)
            usage
            exit 0
            ;;
        *)
            echo "ERROR: Unknown option: $1" >&2
            usage >&2
            exit 1
            ;;
    esac
done

for cmd in awk cat chmod chown find install mkdir mktemp mv readlink rm systemctl; do
    require_command "$cmd"
done

validate_bundle
stop_proton_services_for_redeploy

mkdir -p "$BIN_DIR" "$ETC_PROTON_DIR" "$SYSTEMD_DIR" "$WG_POOL_DIR"
mkdir -p "$WG_RUNTIME_DIR"
chmod 0755 "$BIN_DIR"
chmod 0755 "$ETC_PROTON_DIR"
chmod 0700 "$WG_POOL_DIR"
chmod 0700 "$WG_RUNTIME_DIR"
chown root:root "$BIN_DIR" "$ETC_PROTON_DIR" "$WG_POOL_DIR" "$WG_RUNTIME_DIR"

for script in "${SCRIPTS[@]}"; do
    install_script_file "$script"
done

for service in "${SERVICES[@]}"; do
    install_service_file "$service"
done

for service in "${OPTIONAL_SERVICES[@]}"; do
    install_service_file "$service"
done

for env_file in "${ENV_FILES[@]}"; do
    install_env_template "$env_file" 0644
done

install_qbittorrent_env
install_qbittorrent_port_env
install_qbittorrent_service_dropins
load_common_env
load_port_forward_env
validate_wireguard_config
secure_wireguard_config

enable_and_start_services

log "Installed Proton scripts to ${BIN_DIR}"
log "Installed Proton env files to ${ETC_PROTON_DIR}"
log "Installed systemd units to ${SYSTEMD_DIR}"
log "Cleared stale bad/incapable/runtime state before restarting Proton services"
log "Services enabled and restarted: ${SERVICES[*]}"
log "If qBittorrent credentials already existed, review any *.new files under ${ETC_PROTON_DIR}"
