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
    proton-docker-watch.service
    proton-healthcheck.service
)

SCRIPTS=(
    install-proton-systemd.sh
    proton-killswitch-dispatch.sh
    proton-killswitch-safe.sh
    proton-killswitch-nft.sh
    proton-killswitch-reset.sh
    proton-port-forward-healthcheck.sh
    proton-port-forward-safe.sh
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
    --qb-container NAME Set QBT_CONTAINER_NAME in /etc/proton/qbittorrent.env (default: qbittorrent)
    --qb-int-port PORT  Set QBT_INTERNAL_PORT in /etc/proton/qbittorrent.env (default: 6881)
    --qb-network NAME   Set QBT_NETWORK_NAME in /etc/proton/qbittorrent.env (optional)
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
    done

    for name in "${SERVICES[@]}"; do
        ensure_source_file "${SCRIPT_DIR}/${name}"
    done

    for name in "${ENV_FILES[@]}"; do
        ensure_source_file "${SCRIPT_DIR}/${name}"
    done

    ensure_source_file "${SCRIPT_DIR}/proton-qbittorrent.env"
}

load_common_env() {
    local env_file="${ETC_PROTON_DIR}/proton-common.env"

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

    if [[ "$FORCE_ENV" -eq 0 && -z "$QBITTORRENT_URL_VALUE" && -z "$QBITTORRENT_USER_VALUE" && -z "$QBITTORRENT_PASS_VALUE" && -f "${target_file}" ]]; then
        install -o root -g root -m 0600 \
            "${source_file}" \
            "${target_file}.new"
        log "Preserved ${target_file}; wrote updated template to ${target_file}.new"
        chown root:root "${target_file}"
        chmod 0600 "${target_file}"
        return 0
    fi

    install -o root -g root -m 0600 \
        "${source_file}" \
        "${tmp_file}"

    current_url="$(awk -F= '/^QBITTORRENT_URL=/ {print $2; exit}' "${tmp_file}")"
    current_user="$(awk -F= '/^QBITTORRENT_USER=/ {print $2; exit}' "${tmp_file}")"
    current_pass="$(awk -F= '/^QBITTORRENT_PASS=/ {print $2; exit}' "${tmp_file}")"
    current_container="$(awk -F= '/^QBT_CONTAINER_NAME=/ {print $2; exit}' "${tmp_file}")"
    current_int_port="$(awk -F= '/^QBT_INTERNAL_PORT=/ {print $2; exit}' "${tmp_file}")"
    current_network="$(awk -F= '/^QBT_NETWORK_NAME=/ {print $2; exit}' "${tmp_file}")"

    current_url="${QBITTORRENT_URL_VALUE:-$current_url}"
    current_user="${QBITTORRENT_USER_VALUE:-$current_user}"
    current_pass="${QBITTORRENT_PASS_VALUE:-$current_pass}"
    current_container="${QBT_CONTAINER_NAME_VALUE:-${current_container:-qbittorrent}}"
    current_int_port="${QBT_INTERNAL_PORT_VALUE:-${current_int_port:-6881}}"
    current_network="${QBT_NETWORK_NAME_VALUE:-${current_network:-}}"

    cat > "${tmp_file}" <<EOF
# qBittorrent credentials for the host-side Proton services.
# These scripts run on the host, so point QBITTORRENT_URL at the host-published
# Web UI port rather than the Docker-internal starr_network address.

QBITTORRENT_URL=${current_url}
QBITTORRENT_USER=${current_user}
QBITTORRENT_PASS=${current_pass}
    QBT_CONTAINER_NAME=${current_container}
    QBT_INTERNAL_PORT=${current_int_port}
    # Optional: Docker network name where qBittorrent runs (used to lookup container IP). If blank, the first network IP will be used.
    QBT_NETWORK_NAME=${current_network}
EOF

    install -o root -g root -m 0600 \
        "${tmp_file}" \
        "${target_file}"
    rm -f "${tmp_file}"
}

enable_and_start_services() {
    systemctl daemon-reload
    systemctl enable "${SERVICES[@]}"
    systemctl restart proton-killswitch.service
    systemctl restart proton-wg.service
    systemctl restart proton-port-forward.service
    systemctl restart proton-healthcheck.service
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

for cmd in awk cat chmod chown find install mkdir mktemp mv rm systemctl; do
    require_command "$cmd"
done

validate_bundle

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

for env_file in "${ENV_FILES[@]}"; do
    install_env_template "$env_file" 0644
done

install_qbittorrent_env
load_common_env
validate_wireguard_config
secure_wireguard_config

enable_and_start_services

log "Installed Proton scripts to ${BIN_DIR}"
log "Installed Proton env files to ${ETC_PROTON_DIR}"
log "Installed systemd units to ${SYSTEMD_DIR}"
log "Services enabled and restarted: ${SERVICES[*]}"
log "If qBittorrent credentials already existed, review any *.new files under ${ETC_PROTON_DIR}"
