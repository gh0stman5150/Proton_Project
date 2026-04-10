#!/usr/bin/env bats

setup() {
  TEST_TMPDIR="${BATS_TEST_TMPDIR:-$BATS_TMPDIR}"
  TMPBIN="$TEST_TMPDIR/bin"
  mkdir -p "$TMPBIN"
  export PATH="$TMPBIN:$PATH"
  export IPTABLES_LOG="$TEST_TMPDIR/iptables.log"
  export NFT_LOG="$TEST_TMPDIR/nft.log"
  export NFT_STDIN="$TEST_TMPDIR/nft.stdin"

  cat > "$TMPBIN/systemd-cat" <<'EOF'
#!/usr/bin/env bash
cat - >/dev/null
EOF
  chmod +x "$TMPBIN/systemd-cat"

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
  cat > "$NFT_STDIN"
  exit 0
fi
printf '%s\n' "$*" >> "$NFT_LOG"
case "$1" in
  list)
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
  ! grep -F 'meta mark set' "$NFT_STDIN"
  ! grep -F 'dport 53 return' "$NFT_STDIN"
}
