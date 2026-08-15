#!/usr/bin/env bats

setup() {
  TEST_TMPDIR="${BATS_TEST_TMPDIR:-$BATS_TMPDIR}"
  TMPBIN="$TEST_TMPDIR/bin"
  export PATH="$TMPBIN:$PATH"
  export PROTON_INSTANCE_ROOT="$TEST_TMPDIR/instances"
  export PROTON_COMMON_ENV="$TEST_TMPDIR/proton-common.env"
  export STATE_DIR="$TEST_TMPDIR/state"
  export IP_LOG="$TEST_TMPDIR/ip.log"
  export PROTON_WATCHER_SOURCE_ONLY=1
  mkdir -p "$TMPBIN" "$STATE_DIR" "$PROTON_INSTANCE_ROOT/sonarr" "$PROTON_INSTANCE_ROOT/radarr"
  : > "$IP_LOG"

  cat > "$PROTON_COMMON_ENV" <<EOF
DOCKER_NETWORK_CIDR6=fdca:6c19:2096::/64
DOCKER_IPV6_FALLBACK_INSTANCE=sonarr
DOCKER_FALLBACK_VPN_ROUTING=on
EOF

  for instance in sonarr radarr; do
    subnet=4
    port=8083
    [[ "$instance" == radarr ]] && { subnet=3; port=8082; }
    mkdir -p "$PROTON_INSTANCE_ROOT/$instance"
    cat > "$PROTON_INSTANCE_ROOT/$instance/proton.env" <<EOF
WG_ADDRESS_SUBNET=$subnet
VPN_INTERFACE=pv$instance
STATE_DIR=$STATE_DIR/$instance
EOF
    cat > "$PROTON_INSTANCE_ROOT/$instance/qbittorrent.env" <<EOF
QBITTORRENT_URL=http://127.0.0.1:$port
QBT_CONTAINER_NAME=qbittorrent-$instance
QBT_NETWORK_NAME=starr_network
EOF
  done

cat > "$TMPBIN/ip" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$IP_LOG"
if [[ "$*" == *"rule del"* || "$*" == *"rule del "* ]]; then
  exit 2
fi
EOF
  cat > "$TMPBIN/docker" <<'EOF'
#!/usr/bin/env bash
if [[ "$*" == *"GlobalIPv6Address"* ]]; then
  [[ "$*" == *"qbittorrent-sonarr"* ]] && printf 'starr_network=fdca:6c19:2096::17\n'
  [[ "$*" == *"qbittorrent-radarr"* ]] && printf 'starr_network=fdca:6c19:2096::16\n'
elif [[ "$1" == inspect ]]; then
  [[ "$*" == *"qbittorrent-sonarr"* ]] && printf 'starr_network=192.168.96.17\n'
  [[ "$*" == *"qbittorrent-radarr"* ]] && printf 'starr_network=192.168.96.16\n'
fi
EOF
  cat > "$TMPBIN/systemd-cat" <<'EOF'
#!/usr/bin/env bash
cat - >/dev/null
EOF
  chmod +x "$TMPBIN/ip" "$TMPBIN/docker" "$TMPBIN/systemd-cat"
}

@test "IPv6 fallback owner receives ULA fallback and qBittorrent owner rules" {
  run bash -c 'source ./proton-docker-network-watcher.sh sonarr; reapply_routes 192.168.96.0/20 fdca:6c19:2096::/64'

  [ "$status" -eq 0 ]
  grep -F -- '-6 rule add from fdca:6c19:2096::/64 to fdca:6c19:2096::/64 lookup main priority 108' "$IP_LOG"
  grep -F -- '-6 rule add from fdca:6c19:2096::17/128 lookup 51804 priority 114' "$IP_LOG"
  grep -F -- '-6 rule add from fdca:6c19:2096::/64 lookup 51804 priority 130' "$IP_LOG"
}

@test "non-owner receives only its qBittorrent IPv6 rule" {
  run bash -c 'source ./proton-docker-network-watcher.sh radarr; reapply_routes 192.168.96.0/20 fdca:6c19:2096::/64'

  [ "$status" -eq 0 ]
  grep -F -- '-6 rule add from fdca:6c19:2096::16/128 lookup 51803 priority 113' "$IP_LOG"
  ! grep -F -- '-6 rule add from fdca:6c19:2096::/64 lookup 51803 priority 130' "$IP_LOG"
}
