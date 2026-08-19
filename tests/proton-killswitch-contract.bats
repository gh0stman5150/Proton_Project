#!/usr/bin/env bats

@test "both firewall backends serialize their shared host-wide ruleset" {
  grep -Fq 'KILLSWITCH_LOCK_FILE="${KILLSWITCH_LOCK_FILE:-/run/proton/killswitch.lock}"' proton-killswitch-nft.sh
  grep -Fq 'KILLSWITCH_LOCK_FILE="${KILLSWITCH_LOCK_FILE:-/run/proton/killswitch.lock}"' proton-killswitch-safe.sh
  grep -Fq 'flock -w 30 9' proton-killswitch-nft.sh
  grep -Fq 'flock -w 30 9' proton-killswitch-safe.sh
}

setup() {
  TEST_TMPDIR="${BATS_TEST_TMPDIR:-$BATS_TMPDIR}"
  TMPBIN="$TEST_TMPDIR/bin"
  mkdir -p "$TMPBIN"
  export PATH="$TMPBIN:$PATH"
  export IPTABLES_LOG="$TEST_TMPDIR/iptables.log"
  export NFT_LOG="$TEST_TMPDIR/nft.log"
  export NFT_STDIN="$TEST_TMPDIR/nft.stdin"
  export SYSTEMD_LOG="$TEST_TMPDIR/systemd.log"
  export NFT_CONCURRENCY_LOG="$TEST_TMPDIR/nft-concurrency.log"
  export NFT_ACTIVE_DIR="$TEST_TMPDIR/nft-active"
  export STATE_DIR="$TEST_TMPDIR/state"
  export KILLSWITCH_LOCK_FILE="$TEST_TMPDIR/killswitch.lock"
  mkdir -p "$STATE_DIR"

  cat > "$TMPBIN/systemd-cat" <<'EOF'
#!/usr/bin/env bash
cat - >> "$SYSTEMD_LOG"
EOF
  chmod +x "$TMPBIN/systemd-cat"

  cat > "$TMPBIN/wg" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == "show" && "$2" == "interfaces" ]]; then
  echo proton
fi
exit 0
EOF
  chmod +x "$TMPBIN/wg"

  cat > "$TMPBIN/ip" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  route)
    echo 'default via 192.168.50.1 dev eth0'
    ;;
  '-4 route show dev eth0')
    echo '192.168.50.0/24 proto kernel scope link src 192.168.50.10'
    ;;
  'link show proton')
    echo '3: proton: <POINTOPOINT,UP,LOWER_UP> mtu 1420'
    ;;
  *)
    ;;
esac
exit 0
EOF
  chmod +x "$TMPBIN/ip"

  cat > "$TMPBIN/iptables" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$IPTABLES_LOG"
exit 0
EOF
  chmod +x "$TMPBIN/iptables"

  cat > "$TMPBIN/nft" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == '-f' ]]; then
  if [[ "${TEST_NFT_CONCURRENCY:-0}" == 1 ]]; then
    if ! mkdir "$NFT_ACTIVE_DIR" 2>/dev/null; then
      printf '%s\n' overlap >> "$NFT_CONCURRENCY_LOG"
    fi
    /bin/sleep 0.2
    rmdir "$NFT_ACTIVE_DIR" 2>/dev/null || true
  fi
  cat > "$NFT_STDIN"
  exit 0
fi
printf '%s\n' "$*" >> "$NFT_LOG"
case "$1" in
  list)
    if [[ "$*" == "list table inet proton" && "${TEST_NFT_PROTON_EXISTS:-0}" == 1 ]]; then
      exit 0
    fi
    exit 1
    ;;
  *)
    exit 0
    ;;
esac
EOF
  chmod +x "$TMPBIN/nft"
}

@test "iptables backend blocks Docker WAN bypass and direct LAN DNS" {
  run env DOCKER_NETWORK_CIDR=172.18.0.0/16 SERVER_POOL_ENABLED=off VPN_INTERFACE=proton bash ./proton-killswitch-safe.sh
  [ "$status" -eq 0 ]
  grep -F 'PROTON_DOCKER_FORWARD -s 172.18.0.0/16 -o eth0 -d 192.168.50.0/24 -p tcp --dport 53 -j DROP' "$IPTABLES_LOG"
  grep -F 'PROTON_DOCKER_FORWARD -s 172.18.0.0/16 -o eth0 -d 192.168.50.0/24 -p udp --dport 53 -j DROP' "$IPTABLES_LOG"
  grep -F 'PROTON_DOCKER_FORWARD -s 172.18.0.0/16 -o proton -j ACCEPT' "$IPTABLES_LOG"
  grep -F 'PROTON_DOCKER_FORWARD -s 172.18.0.0/16 -j DROP' "$IPTABLES_LOG"
  ! grep -F -- '--dport 53 -j ACCEPT' "$IPTABLES_LOG"
}

@test "nft backend emits Docker-only DNS drops and no host mark rules" {
  run env DOCKER_NETWORK_CIDR=172.18.0.0/16 SERVER_POOL_ENABLED=off VPN_INTERFACE=proton bash ./proton-killswitch-nft.sh
  [ "$status" -eq 0 ]
  grep -F 'udp dport 53 drop' "$NFT_STDIN"
  grep -F 'tcp dport 53 drop' "$NFT_STDIN"
  grep -F 'oifname "proton" ip saddr 172.18.0.0/16 accept' "$NFT_STDIN"
  ! grep -F 'accept        iifname' "$NFT_STDIN"
  ! grep -F 'accept        oifname' "$NFT_STDIN"
  ! grep -F 'meta mark set' "$NFT_STDIN"
  ! grep -F 'dport 53 return' "$NFT_STDIN"
}

@test "nft backend replaces an existing filter table in one atomic batch" {
  run env TEST_NFT_PROTON_EXISTS=1 DOCKER_NETWORK_CIDR=172.18.0.0/16 \
    SERVER_POOL_ENABLED=off VPN_INTERFACE=proton bash ./proton-killswitch-nft.sh

  [ "$status" -eq 0 ]
  grep -Fx 'delete table inet proton' "$NFT_STDIN"
  grep -F 'table inet proton {' "$NFT_STDIN"
  ! grep -Fx 'delete table inet proton' "$NFT_LOG"
  [ -f "$KILLSWITCH_LOCK_FILE" ]
}

@test "nft backend serializes concurrent watcher applies" {
  run bash -c '
    TEST_NFT_CONCURRENCY=1 DOCKER_NETWORK_CIDR=172.18.0.0/16 SERVER_POOL_ENABLED=off VPN_INTERFACE=proton bash ./proton-killswitch-nft.sh &
    first=$!
    TEST_NFT_CONCURRENCY=1 DOCKER_NETWORK_CIDR=172.18.0.0/16 SERVER_POOL_ENABLED=off VPN_INTERFACE=proton bash ./proton-killswitch-nft.sh &
    second=$!
    wait "$first"
    wait "$second"
  '

  [ "$status" -eq 0 ]
  [ ! -s "$NFT_CONCURRENCY_LOG" ]
}

@test "nft backend allows Docker IPv6 only through Proton and installs scoped NAT66" {
  run env \
    DOCKER_NETWORK_CIDR=172.18.0.0/16 \
    DOCKER_NETWORK_CIDR6=fdca:6c19:2096::/64 \
    SERVER_POOL_ENABLED=off \
    VPN_INTERFACE=proton \
    bash ./proton-killswitch-nft.sh

  [ "$status" -eq 0 ]
  grep -F 'ip6 saddr fdca:6c19:2096::/64 ip6 daddr fdca:6c19:2096::/64 accept' "$NFT_STDIN"
  grep -F 'oifname "proton" ip6 saddr fdca:6c19:2096::/64 accept' "$NFT_STDIN"
  grep -F 'ip6 saddr fdca:6c19:2096::/64 drop' "$NFT_STDIN"
  grep -F 'ip6 daddr fdca:6c19:2096::/64 drop' "$NFT_STDIN"
  grep -F 'add rule ip6 proton_nat6 postrouting ip6 saddr fdca:6c19:2096::/64 oifname proton masquerade comment proton-wg-snat6' "$NFT_LOG"
}

@test "iptables backend refuses Docker IPv6 before creating chains" {
  run env \
    DOCKER_NETWORK_CIDR=172.18.0.0/16 \
    DOCKER_NETWORK_CIDR6=fdca:6c19:2096::/64 \
    SERVER_POOL_ENABLED=off \
    VPN_INTERFACE=proton \
    bash ./proton-killswitch-safe.sh

  [ "$status" -ne 0 ]
  grep -F 'Docker IPv6 requires KILLSWITCH_BACKEND=nftables' "$SYSTEMD_LOG"
  [ ! -s "$IPTABLES_LOG" ]
}
