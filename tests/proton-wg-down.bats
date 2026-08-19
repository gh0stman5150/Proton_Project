#!/usr/bin/env bats

setup() {
  TEST_TMPDIR="${BATS_TEST_TMPDIR:-$BATS_TMPDIR}"
  TMPBIN="$TEST_TMPDIR/bin"
  export PATH="$TMPBIN:$PATH"
  export PROTON_INSTANCE_ROOT="$TEST_TMPDIR/instances"
  export PROTON_COMMON_ENV="$TEST_TMPDIR/proton-common.env"
  export STATE_DIR="$TEST_TMPDIR/state"
  export WG_RUNTIME_DIR="$TEST_TMPDIR/runtime"
  export IP_LOG="$TEST_TMPDIR/ip.log"
  export PROTON_ROUTE_LOCK_FILE="$TEST_TMPDIR/policy-routing.lock"
  mkdir -p "$TMPBIN" "$STATE_DIR" "$WG_RUNTIME_DIR" "$PROTON_INSTANCE_ROOT/sonarr"
  : > "$IP_LOG"

  cat > "$PROTON_COMMON_ENV" <<EOF
WG_IPV6_ENABLED=on
DOCKER_NETWORK_CIDR=192.168.96.0/20
DOCKER_NETWORK_CIDR6=fdca:6c19:2096::/64
MANAGE_RESOLVED_DNS=off
EOF
  cat > "$PROTON_INSTANCE_ROOT/sonarr/proton.env" <<EOF
WG_ADDRESS_SUBNET=4
VPN_INTERFACE=pvsonarr
WG_PROFILE=pvsonarr
WG_CONFIG=$TEST_TMPDIR/pvsonarr.conf
STATE_DIR=$STATE_DIR
EOF
  cat > "$PROTON_INSTANCE_ROOT/sonarr/qbittorrent.env" <<'EOF'
QBITTORRENT_URL=http://127.0.0.1:8083
QBT_CONTAINER_NAME=qbittorrent-sonarr
QBT_NETWORK_NAME=starr_network
EOF
  printf '[Interface]\nPrivateKey = test\n' > "$TEST_TMPDIR/pvsonarr.conf"
  printf '%s' 'fdca:6c19:2096::17' > "$STATE_DIR/qbt-container-ip6"

  cat > "$TMPBIN/ip" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$IP_LOG"
EOF
  cat > "$TMPBIN/docker" <<'EOF'
#!/usr/bin/env bash
if [[ "$*" == *"GlobalIPv6Address"* ]]; then
  printf 'starr_network=fdca:6c19:2096::17\n'
elif [[ "$1" == inspect ]]; then
  printf 'starr_network=192.168.96.17\n'
fi
EOF
  cat > "$TMPBIN/wg-quick" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  cat > "$TMPBIN/iptables" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  cat > "$TMPBIN/systemd-cat" <<'EOF'
#!/usr/bin/env bash
cat - >/dev/null
EOF
  chmod +x "$TMPBIN/ip" "$TMPBIN/docker" "$TMPBIN/wg-quick" "$TMPBIN/iptables" "$TMPBIN/systemd-cat"
}

@test "wg down removes Docker IPv6 owner rules before flushing the tunnel table" {
  run bash ./proton-wg-down-safe.sh sonarr

  [ "$status" -eq 0 ]
  qbt_line="$(grep -nF -- '-6 rule del from fdca:6c19:2096::17/128 lookup 51804 priority 114' "$IP_LOG" | head -n1 | cut -d: -f1)"
  fallback_line="$(grep -nF -- '-6 rule del from fdca:6c19:2096::/64 lookup 51804 priority 130' "$IP_LOG" | head -n1 | cut -d: -f1)"
  flush_line="$(grep -nF -- '-6 route flush table 51804' "$IP_LOG" | head -n1 | cut -d: -f1)"
  [ -n "$qbt_line" ]
  [ -n "$fallback_line" ]
  [ -n "$flush_line" ]
  [ "$qbt_line" -lt "$flush_line" ]
  [ "$fallback_line" -lt "$flush_line" ]
  [ ! -e "$STATE_DIR/qbt-container-ip6" ]
}
