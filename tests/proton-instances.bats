#!/usr/bin/env bats

setup() {
  TEST_TMPDIR="${BATS_TEST_TMPDIR:-$BATS_TMPDIR}"
  export PROTON_INSTANCE_ROOT="$TEST_TMPDIR/instances"
  export PROTON_COMMON_ENV="$TEST_TMPDIR/proton-common.env"
  mkdir -p "$PROTON_INSTANCE_ROOT"

  cat > "$PROTON_COMMON_ENV" <<'EOF'
STATE_DIR=/run/proton
STATE_FILE=/run/proton/proton-port.state
CACHE_FILE=/run/proton/qbt-port.cache
RECOVERY_LOCK_FILE=/run/proton/recovery.lock
SERVER_SELECTION_FILE=/run/proton/current-server.env
SERVER_RESELECT_FILE=/run/proton/reselect-server.flag
DOCKER_NETWORK_CIDR_STATE_FILE=/run/proton/docker-network-cidr
DOCKER_CONFIG_DIR=/run/proton/docker-config
QBITTORRENT_ENV_FILE=/etc/proton/qbittorrent.env
EOF

  create_instance lidarr 8081 pvlidarr
  create_instance radarr 8083 pvradarr
  create_instance sonarr 8084 pvsonarr
  create_instance whisparr 8085 pvwhisparr
  create_instance prowlarr 8082 pvprowlarr
}

create_instance() {
  local instance="$1"
  local webui_port="$2"
  local vpn_if="$3"
  local instance_dir="$PROTON_INSTANCE_ROOT/$instance"

  mkdir -p "$instance_dir"

  cat > "$instance_dir/proton.env" <<EOF
INSTANCE_NAME=$instance
WG_PROFILE=$vpn_if
VPN_INTERFACE=$vpn_if
WG_CONFIG=/etc/proton/instances/$instance/wireguard.conf
EOF

  cat > "$instance_dir/qbittorrent.env" <<EOF
QBT_INSTANCE_NAME=$instance
QBITTORRENT_URL=http://127.0.0.1:$webui_port
QBT_CONTAINER_NAME=qbittorrent-$instance
QBT_PORT_ENV_FILE=/etc/proton/instances/$instance/qbittorrent-port.env
EOF
}

write_wireguard_config() {
  local instance="$1"
  local endpoint="$2"

  cat > "$PROTON_INSTANCE_ROOT/$instance/wireguard.conf" <<EOF
[Interface]
PrivateKey = test-private-key-$instance
Address = 10.2.0.2/32
DNS = 10.2.0.1

[Peer]
PublicKey = test-public-key
AllowedIPs = 0.0.0.0/0
Endpoint = $endpoint
EOF
}

@test "only approved instance names are accepted" {
  for instance in lidarr radarr sonarr whisparr prowlarr; do
    run bash -c 'source ./proton-instance-common.sh; proton_validate_instance_name "$1"' _ "$instance"
    [ "$status" -eq 0 ]
  done

  for instance in "" readarr "../sonarr" "sonarr.prod"; do
    run bash -c 'source ./proton-instance-common.sh; proton_validate_instance_name "$1"' _ "$instance"
    [ "$status" -ne 0 ]
  done
}

@test "each approved instance loads only its own config" {
  run bash -c 'source ./proton-instance-common.sh; proton_instance_init lidarr; printf "%s\n%s\n%s\n%s\n" "$INSTANCE" "$VPN_INTERFACE" "$STATE_DIR" "$QBITTORRENT_URL"'
  [ "$status" -eq 0 ]
  [[ "$output" == *"lidarr"* ]]
  [[ "$output" == *"pvlidarr"* ]]
  [[ "$output" == *"/run/proton/lidarr"* ]]
  [[ "$output" == *"http://127.0.0.1:8081"* ]]
  [[ "$output" != *"prowlarr"* ]]
  [[ "$output" != *"8085"* ]]

  run bash -c 'source ./proton-instance-common.sh; proton_instance_init prowlarr; printf "%s\n%s\n%s\n%s\n" "$INSTANCE" "$VPN_INTERFACE" "$STATE_DIR" "$QBITTORRENT_URL"'
  [ "$status" -eq 0 ]
  [[ "$output" == *"prowlarr"* ]]
  [[ "$output" == *"pvprowlarr"* ]]
  [[ "$output" == *"/run/proton/prowlarr"* ]]
  [[ "$output" == *"http://127.0.0.1:8082"* ]]
  [[ "$output" != *"sonarr"* ]]
  [[ "$output" != *"8084"* ]]
}

@test "legacy runtime paths are rebased per instance" {
  run bash -c 'source ./proton-instance-common.sh; proton_instance_init whisparr; printf "%s\n%s\n%s\n%s\n%s\n%s\n" "$STATE_FILE" "$CACHE_FILE" "$RECOVERY_LOCK_FILE" "$SERVER_SELECTION_FILE" "$DOCKER_CONFIG_DIR" "$QBT_SYNC_LOCK_FILE"'

  [ "$status" -eq 0 ]
  [[ "$output" == *"/run/proton/whisparr/proton-port.state"* ]]
  [[ "$output" == *"/run/proton/whisparr/qbt-port.cache"* ]]
  [[ "$output" == *"/run/proton/whisparr/recovery.lock"* ]]
  [[ "$output" == *"/run/proton/whisparr/current-server.env"* ]]
  [[ "$output" == *"/run/proton/whisparr/docker-config"* ]]
  [[ "$output" == *"/run/proton/whisparr/qbt-sync.lock"* ]]
  [[ "$output" != *"/run/proton/sonarr/"* ]]
  [[ "$output" != *"/run/proton/prowlarr/"* ]]
}

@test "same Proton server endpoint still keeps instance tunnels isolated" {
  write_wireguard_config lidarr "203.0.113.10:51820"
  write_wireguard_config radarr "203.0.113.10:51820"

  run bash -c 'source ./proton-instance-common.sh; proton_instance_init lidarr; printf "%s\n%s\n%s\n%s\n%s\n" "$WG_CONFIG" "$VPN_INTERFACE" "$STATE_FILE" "$QBT_PORT_ENV_FILE" "$(awk -F "= " "/^Endpoint/ {print \$2; exit}" "$PROTON_INSTANCE_ROOT/$INSTANCE/wireguard.conf")"'
  [ "$status" -eq 0 ]
  [[ "$output" == *"/lidarr/wireguard.conf"* ]]
  [[ "$output" == *"pvlidarr"* ]]
  [[ "$output" == *"/run/proton/lidarr/proton-port.state"* ]]
  [[ "$output" == *"/etc/proton/instances/lidarr/qbittorrent-port.env"* ]]
  [[ "$output" == *"203.0.113.10:51820"* ]]

  run bash -c 'source ./proton-instance-common.sh; proton_instance_init radarr; printf "%s\n%s\n%s\n%s\n%s\n" "$WG_CONFIG" "$VPN_INTERFACE" "$STATE_FILE" "$QBT_PORT_ENV_FILE" "$(awk -F "= " "/^Endpoint/ {print \$2; exit}" "$PROTON_INSTANCE_ROOT/$INSTANCE/wireguard.conf")"'
  [ "$status" -eq 0 ]
  [[ "$output" == *"/radarr/wireguard.conf"* ]]
  [[ "$output" == *"pvradarr"* ]]
  [[ "$output" == *"/run/proton/radarr/proton-port.state"* ]]
  [[ "$output" == *"/etc/proton/instances/radarr/qbittorrent-port.env"* ]]
  [[ "$output" == *"203.0.113.10:51820"* ]]
}

@test "missing required instance env files fail safely" {
  rm -f "$PROTON_INSTANCE_ROOT/radarr/proton.env"
  run bash -c 'source ./proton-instance-common.sh; proton_instance_init radarr 2>&1'
  [ "$status" -ne 0 ]
  [[ "$output" == *"Instance Proton env not found"* ]]

  rm -f "$PROTON_INSTANCE_ROOT/lidarr/qbittorrent.env"
  run bash -c 'source ./proton-instance-common.sh; proton_instance_init lidarr 2>&1'
  [ "$status" -ne 0 ]
  [[ "$output" == *"Instance qBittorrent env not found"* ]]
}

@test "generated port artifacts have one authoritative published-port value" {
  grep -Fq 'QBT_PUBLISHED_PORT=6881' proton-qbittorrent-port.env
  ! grep -Fq 'QBT_FORWARDED_PORT=' proton-qbittorrent-port.env
  ! grep -Fq 'QBT_FORWARDED_PORT=' proton-qbittorrent-sync-safe.sh
  [ "$(awk -F= '/^[A-Za-z_][A-Za-z0-9_]*=/ { count++ } END { print count + 0 }' proton-qbittorrent-port.env)" -eq 1 ]
}
