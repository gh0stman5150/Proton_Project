#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_DIR="/usr/local/bin/proton"
ETC_PROTON_DIR="/etc/proton"
SYSTEMD_DIR="/etc/systemd/system"
WG_POOL_DIR="/etc/wireguard/proton-pool"
WG_RUNTIME_DIR="/etc/wireguard/proton-runtime"
QBT_COMPOSE_COMMON_DIR="/opt/qbittorrent-common"
INSTANCE_MANIFEST_SOURCE="${SCRIPT_DIR}/qbittorrent-instances.tsv"
FORCE_ENV=0
QBITTORRENT_URL_VALUE=""
QBITTORRENT_USER_VALUE=""
QBITTORRENT_PASS_VALUE=""
QBT_CONTAINER_NAME_VALUE=""
QBT_INTERNAL_PORT_VALUE=""
QBT_NETWORK_NAME_VALUE=""

SERVICES=(
	proton-killswitch.service
	proton-wg@.service
	proton-port-forward@.service
	proton-healthcheck@.service
)

OPTIONAL_SERVICES=(
	proton-docker-watch@.service
)

TRIGGERED_SERVICES=(
	proton-qbt-allocate@.service
)

LEGACY_SINGLETON_SERVICES=(
	proton-wg.service
	proton-port-forward.service
	proton-healthcheck.service
)

INSTANCES=()

SCRIPTS=(
	install-proton-systemd.sh
	proton-instance-common.sh
	proton-killswitch-dispatch.sh
	proton-killswitch-safe.sh
	proton-killswitch-nft.sh
	proton-killswitch-reset.sh
	proton-port-forward-healthcheck.sh
	proton-port-forward-safe.sh
	proton-qbittorrent-common.sh
	proton-qbittorrent-sync-safe.sh
	proton-qbt-allocate-and-sync.sh
	proton-qbt-dnat-cleanup.sh
	proton-docker-network-watcher.sh
	proton-server-manager.sh
	proton-wg-up-safe.sh
	proton-wg-down-safe.sh
	proton-healthcheck.sh
	proton-ipv6-rollout.sh
)

ENV_FILES=(
	proton-common.env
	proton-port-forward.env
	proton-healthcheck.env
)

QBT_FLEET_FILES=(
	qbittorrent-compose.common.yml
	qbittorrent-instances.tsv
)

PROTON_VPN_RELEASE_URL="https://repo.protonvpn.com/debian/dists/stable/main/binary-all/protonvpn-stable-release_1.0.8_all.deb"
PROTON_VPN_RELEASE_DEB="protonvpn-stable-release_1.0.8_all.deb"
PROTON_VPN_REQUIRED_PACKAGES=(
	proton-vpn-cli
	proton-vpn-daemon
	protonvpn-stable-release
	python3-proton-core
	python3-proton-keyring-linux
	python3-proton-vpn-api-core
	python3-proton-vpn-local-agent
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

package_installed() {
	local package="$1"
	local status

	status="$(dpkg-query -W -f='${Status}' "$package" 2>/dev/null || true)"
	[[ "$status" == "install ok installed" ]]
}

ensure_proton_vpn_packages() {
	local package release_deb
	local missing_packages=()
	local remaining_packages=()

	for package in "${PROTON_VPN_REQUIRED_PACKAGES[@]}"; do
		if ! package_installed "$package"; then
			missing_packages+=("$package")
		fi
	done

	if [[ "${#missing_packages[@]}" -eq 0 ]]; then
		log "All required Proton VPN packages are installed"
		return 0
	fi

	log "Missing Proton VPN packages: ${missing_packages[*]}"
	require_command apt-get
	require_command wget

	release_deb="/tmp/${PROTON_VPN_RELEASE_DEB}"
	log "Installing Proton VPN apt repository package from ${PROTON_VPN_RELEASE_URL}"
	wget -O "$release_deb" "$PROTON_VPN_RELEASE_URL"
	DEBIAN_FRONTEND=noninteractive apt-get install -y "$release_deb"
	apt-get update
	DEBIAN_FRONTEND=noninteractive apt-get install -y protonvpn

	for package in "${PROTON_VPN_REQUIRED_PACKAGES[@]}"; do
		if ! package_installed "$package"; then
			remaining_packages+=("$package")
		fi
	done

	if [[ "${#remaining_packages[@]}" -ne 0 ]]; then
		echo "ERROR: Proton VPN package installation completed but these packages are still missing: ${remaining_packages[*]}" >&2
		exit 1
	fi

	log "Installed required Proton VPN packages"
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
    ' "$source_file" >"$output_file"
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

	for name in "${TRIGGERED_SERVICES[@]}"; do
		ensure_source_file "${SCRIPT_DIR}/${name}"
	done

	for name in "${ENV_FILES[@]}"; do
		ensure_source_file "${SCRIPT_DIR}/${name}"
	done

	for name in "${QBT_FLEET_FILES[@]}"; do
		ensure_source_file "${SCRIPT_DIR}/${name}"
	done

	ensure_source_file "${SCRIPT_DIR}/tools/verify-qbittorrent-fleet.sh"
	validate_shell_syntax "${SCRIPT_DIR}/tools/verify-qbittorrent-fleet.sh"
	ensure_source_file "${SCRIPT_DIR}/tools/reconcile-qbittorrent-fleet.sh"
	validate_shell_syntax "${SCRIPT_DIR}/tools/reconcile-qbittorrent-fleet.sh"

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

	if [[ "$FORCE_ENV" -eq 0 &&
		-z "$QBITTORRENT_URL_VALUE" && -z "$QBITTORRENT_USER_VALUE" && -z "$QBITTORRENT_PASS_VALUE" &&
		-z "$QBT_CONTAINER_NAME_VALUE" && -z "$QBT_INTERNAL_PORT_VALUE" && -z "$QBT_NETWORK_NAME_VALUE" &&
		-f "${target_file}" ]]; then
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

	cat >"${tmp_file}" <<EOF
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

install_qbittorrent_compose_common() {
	mkdir -p "$QBT_COMPOSE_COMMON_DIR"
	chown root:root "$QBT_COMPOSE_COMMON_DIR"
	chmod 0755 "$QBT_COMPOSE_COMMON_DIR"

	install_normalized_file \
		"${SCRIPT_DIR}/qbittorrent-compose.common.yml" \
		"${QBT_COMPOSE_COMMON_DIR}/docker-compose.common.yml" 0644
	install_normalized_file \
		"${SCRIPT_DIR}/qbittorrent-instances.tsv" \
		"${QBT_COMPOSE_COMMON_DIR}/qbittorrent-instances.tsv" 0644
}

install_qbittorrent_fleet_verifier() {
	install_normalized_file \
		"${SCRIPT_DIR}/tools/verify-qbittorrent-fleet.sh" \
		"${BIN_DIR}/proton-qbt-fleet-verify.sh" 0755
	install_normalized_file \
		"${SCRIPT_DIR}/tools/reconcile-qbittorrent-fleet.sh" \
		"${BIN_DIR}/proton-qbt-fleet-reconcile.sh" 0755
}

load_instance_manifest() {
	mapfile -t INSTANCES < <(awk -F '\t' '$1 !~ /^#/ && $1 != "" { print $1 }' "$INSTANCE_MANIFEST_SOURCE")
	if [[ "${#INSTANCES[@]}" -ne 5 ]]; then
		echo "ERROR: $INSTANCE_MANIFEST_SOURCE must define exactly five qBittorrent instances." >&2
		exit 1
	fi
}

instance_manifest_value() {
	local instance="$1"
	local field="$2"
	local value=""

	value="$(awk -F '\t' -v instance="$instance" -v field="$field" '$1 == instance { print $field; exit }' "$INSTANCE_MANIFEST_SOURCE")"
	if [[ -z "$value" ]]; then
		echo "ERROR: Missing field $field for instance $instance in $INSTANCE_MANIFEST_SOURCE" >&2
		exit 1
	fi
	printf '%s\n' "$value"
}

instance_webui_port() {
	instance_manifest_value "$1" 2
}

instance_vpn_interface() {
	instance_manifest_value "$1" 5
}

instance_address_subnet() {
	instance_manifest_value "$1" 6
}

normalize_instance_qbittorrent_port_env() {
	local port_env="$1"
	local published_port=""
	local temp_file=""

	published_port="$(awk -F= '$1 == "QBT_PUBLISHED_PORT" { print $2; exit }' "$port_env")"
	if [[ ! "$published_port" =~ ^[0-9]+$ ]] || ((published_port < 1 || published_port > 65535)); then
		echo "ERROR: Cannot normalize $port_env: invalid or missing QBT_PUBLISHED_PORT." >&2
		exit 1
	fi

	temp_file="$(mktemp "${port_env}.XXXXXX")"
	{
		printf '# Managed by proton-qbittorrent-sync-safe.sh\n'
		printf 'QBT_PUBLISHED_PORT=%s\n' "$published_port"
	} >"$temp_file"
	chown root:root "$temp_file"
	chmod 0600 "$temp_file"
	mv -f "$temp_file" "$port_env"
}

install_instance_examples() {
	local instance instance_dir proton_example qb_example port_env webui_port vpn_if

	mkdir -p "${ETC_PROTON_DIR}/instances"
	chown root:root "${ETC_PROTON_DIR}/instances"
	chmod 0755 "${ETC_PROTON_DIR}/instances"

	for instance in "${INSTANCES[@]}"; do
		instance_dir="${ETC_PROTON_DIR}/instances/${instance}"
		proton_example="${instance_dir}/proton.env.example"
		qb_example="${instance_dir}/qbittorrent.env.example"
		port_env="${instance_dir}/qbittorrent-port.env"
		webui_port="$(instance_webui_port "$instance")"
		vpn_if="$(instance_vpn_interface "$instance")"
		address_subnet="$(instance_address_subnet "$instance")"
		vpn_table="$((51800 + address_subnet))"
		qbt_rule_priority="$((110 + address_subnet))"

		mkdir -p "$instance_dir"
		chown root:root "$instance_dir"
		chmod 0700 "$instance_dir"

		cat >"$proton_example" <<EOF
# Example Proton settings for the ${instance} instance.
# Copy to proton.env, set a unique WireGuard config, then keep mode 0600.

INSTANCE_NAME=${instance}
WG_PROFILE=${vpn_if}
VPN_INTERFACE=${vpn_if}
WG_CONFIG=${ETC_PROTON_DIR}/instances/${instance}/wireguard.conf
# Distinct Proton tunnel address subnet for this instance. Drives the runtime
# WireGuard Address (10.${address_subnet}.0.2/32), DNS and NAT-PMP gateway
# (10.${address_subnet}.0.1) so each instance receives its own forwarded port.
WG_ADDRESS_SUBNET=${address_subnet}
VPN_TABLE=${vpn_table}
QBT_VPN_RULE_PRIORITY=${qbt_rule_priority}
DOCKER_FALLBACK_VPN_RULE_PRIORITY=130
STATE_DIR=/run/proton/${instance}
SERVER_SELECTION_FILE=/run/proton/${instance}/current-server.env
SERVER_RESELECT_FILE=/run/proton/${instance}/reselect-server.flag
RECOVERY_LOCK_FILE=/run/proton/${instance}/recovery.lock
DOCKER_NETWORK_CIDR_STATE_FILE=/run/proton/${instance}/docker-network-cidr
DOCKER_CONFIG_DIR=/run/proton/${instance}/docker-config
EOF

		cat >"$qb_example" <<EOF
# Example qBittorrent settings for the ${instance} instance.
# Copy to qbittorrent.env, set real credentials, then keep mode 0600.

QBT_INSTANCE_NAME=${instance}
QBITTORRENT_URL=http://192.168.237.78:${webui_port}
QBITTORRENT_USER=change-me
QBITTORRENT_PASS=change-me

QBT_CONTAINER_NAME=qbittorrent-${instance}
QBT_COMPOSE_PROJECT_DIR=/opt/qbittorrent-${instance}
QBT_COMPOSE_SERVICE=qbittorrent-${instance}
QBT_PORT_APPLY_MODE=compose-recreate
QBT_INTERNAL_PORT=6881
QBT_PORT_ENV_FILE=${ETC_PROTON_DIR}/instances/${instance}/qbittorrent-port.env
QBT_NETWORK_NAME=starr_network
EOF

		chown root:root "$proton_example" "$qb_example"
		chmod 0600 "$proton_example" "$qb_example"

		if [[ -f "$port_env" ]]; then
			normalize_instance_qbittorrent_port_env "$port_env"
			log "Preserved and normalized ${port_env} to one QBT_PUBLISHED_PORT assignment"
		else
			install_normalized_file "${SCRIPT_DIR}/proton-qbittorrent-port.env" "$port_env" 0600
		fi

		for real_config in proton.env qbittorrent.env wireguard.conf; do
			if [[ -f "${instance_dir}/${real_config}" ]]; then
				chown root:root "${instance_dir}/${real_config}"
				chmod 0600 "${instance_dir}/${real_config}"
				log "Preserved ${instance_dir}/${real_config}"
			fi
		done
	done
}

path_dirname() {
	local path="$1"

	if [[ "$path" == */* ]]; then
		printf '%s\n' "${path%/*}"
	else
		printf '.\n'
	fi
}

stop_proton_services_for_redeploy() {
	log "Leaving existing Proton services running; start templated instances manually during migration"
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
	local recovery_lock_file port_state_file pf_incapable_file pf_incapable_strikes_file

	runtime_state_dir="${STATE_DIR:-/run/proton}"
	bad_server_file="${BAD_SERVER_FILE:-${runtime_state_dir}/bad-servers.tsv}"
	server_selection_file="${SERVER_SELECTION_FILE:-${runtime_state_dir}/current-server.env}"
	server_reselect_file="${SERVER_RESELECT_FILE:-${runtime_state_dir}/reselect-server.flag}"
	recovery_lock_file="${RECOVERY_LOCK_FILE:-${runtime_state_dir}/recovery.lock}"
	port_state_file="${STATE_FILE:-${runtime_state_dir}/proton-port.state}"
	pf_incapable_file="${PF_INCAPABLE_PROFILES_FILE:-${ETC_PROTON_DIR}/pf-incapable-profiles.tsv}"
	pf_incapable_strikes_file="${PF_INCAPABLE_STRIKES_FILE:-/run/proton/pf-incapable-strikes.tsv}"

	log "Resetting stale Proton runtime and failure state before service restart"

	rm -f \
		"$bad_server_file" \
		"$server_selection_file" \
		"$server_reselect_file" \
		"$recovery_lock_file" \
		"$port_state_file" \
		"$pf_incapable_file" \
		"$pf_incapable_strikes_file"
}

enable_and_start_services() {
	systemctl daemon-reload
	systemctl disable --now "${LEGACY_SINGLETON_SERVICES[@]}" >/dev/null 2>&1 || true
	systemctl reset-failed "${LEGACY_SINGLETON_SERVICES[@]}" >/dev/null 2>&1 || true
	systemctl enable proton-killswitch.service
	systemctl reset-failed "${OPTIONAL_SERVICES[@]}" "${SERVICES[@]}" >/dev/null 2>&1 || true
	systemctl restart proton-killswitch.service
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

for cmd in awk cat chmod chown dpkg-query find install mkdir mktemp mv readlink rm systemctl; do
	require_command "$cmd"
done

ensure_proton_vpn_packages
validate_bundle
load_instance_manifest
stop_proton_services_for_redeploy

mkdir -p "$BIN_DIR" "$ETC_PROTON_DIR" "$SYSTEMD_DIR" "$WG_POOL_DIR" "$QBT_COMPOSE_COMMON_DIR"
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

for service in "${TRIGGERED_SERVICES[@]}"; do
	install_service_file "$service"
done

for env_file in "${ENV_FILES[@]}"; do
	install_env_template "$env_file" 0644
done

install_qbittorrent_env
install_qbittorrent_port_env
install_qbittorrent_compose_common
install_qbittorrent_fleet_verifier
install_instance_examples
load_common_env
load_port_forward_env

enable_and_start_services

log "Installed Proton scripts to ${BIN_DIR}"
log "Installed Proton env files to ${ETC_PROTON_DIR}"
log "Installed shared qBittorrent Compose policy to ${QBT_COMPOSE_COMMON_DIR}"
log "Installed systemd units to ${SYSTEMD_DIR}"
log "Installed instance examples under ${ETC_PROTON_DIR}/instances"
log "Templated instance units installed; start one instance first, for example: systemctl start proton-wg@sonarr proton-port-forward@sonarr proton-healthcheck@sonarr"
log "If qBittorrent credentials already existed, review any *.new files under ${ETC_PROTON_DIR}"
