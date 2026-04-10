#!/usr/bin/env bats

setup() {
  TMPBIN="$BATS_TMPDIR/bin"
  mkdir -p "$TMPBIN"
  export REAL_STAT="$(command -v stat)"
  export PATH="$TMPBIN:$PATH"
  export STATE_FILE="$BATS_TMPDIR/proton-port.state"
  export CACHE_FILE="$BATS_TMPDIR/qbt-port.cache"
  export ENV_FILE="$BATS_TMPDIR/qbittorrent.env"
  export PORT_ENV_FILE="$BATS_TMPDIR/qbittorrent-port.env"
  export CURL_STATE="$BATS_TMPDIR/current-qbt-port"
  export DOCKER_LOG="$BATS_TMPDIR/docker.log"
  export NFT_LOG="$BATS_TMPDIR/nft.log"
  export CURL_LOG="$BATS_TMPDIR/curl.log"
  export PROJECT_DIR="$BATS_TMPDIR/project"
  mkdir -p "$PROJECT_DIR"

  cat > "$TMPBIN/systemd-cat" <<'EOF'
#!/usr/bin/env bash
cat - >/dev/null
EOF
  chmod +x "$TMPBIN/systemd-cat"

  cat > "$TMPBIN/stat" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == '-c' && "$2" == '%a' ]]; then
  echo 600
  exit 0
fi
if [[ "$1" == '-c' && "$2" == '%u' ]]; then
  echo 0
  exit 0
fi
exec "$REAL_STAT" "$@"
EOF
  chmod +x "$TMPBIN/stat"

  cat > "$TMPBIN/curl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CURL_LOG"
case "$*" in
  *'/api/v2/auth/login'*)
    echo 'Ok.'
    ;;
  *'/api/v2/app/preferences'*)
    printf '{"listen_port":%s}\n' "$(cat "$CURL_STATE")"
    ;;
  *'/api/v2/app/setPreferences'*)
    for arg in "$@"; do
      case "$arg" in
        json=\{"listen_port":*\})
          port="${arg#json={\"listen_port\":}"
          port="${port%\}}"
          printf '%s' "$port" > "$CURL_STATE"
          ;;
      esac
    done
    ;;
  *'/api/v2/app/version'*)
    ;;
  *)
    echo "unexpected curl invocation: $*" >&2
    exit 1
    ;;
esac
exit 0
EOF
  chmod +x "$TMPBIN/curl"

  cat > "$TMPBIN/docker" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$DOCKER_LOG"
if [[ "$1" == 'compose' ]]; then
  exit 0
fi
if [[ "$1" == 'restart' ]]; then
  exit 0
fi
if [[ "$1" == 'inspect' && "$2" == '-f' ]]; then
  if [[ "$3" == '{{.HostConfig.NetworkMode}}' ]]; then
    echo 'bridge'
    exit 0
  fi
  echo 'starr=172.18.0.10'
  exit 0
fi
exit 0
EOF
  chmod +x "$TMPBIN/docker"

  cat > "$TMPBIN/nft" <<'EOF'
#!/usr/bin/env bash
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

write_qbt_env() {
  local mode="$1"
  cat > "$ENV_FILE" <<EOF
QBITTORRENT_URL=http://127.0.0.1:8081
QBITTORRENT_USER=test-user
QBITTORRENT_PASS=test-pass
QBT_PORT_APPLY_MODE=$mode
QBT_COMPOSE_PROJECT_DIR=$PROJECT_DIR
QBT_COMPOSE_SERVICE=qbittorrent
QBT_PORT_ENV_FILE=$PORT_ENV_FILE
QBT_CONTAINER_NAME=qbittorrent
QBT_INTERNAL_PORT=6881
QBT_NETWORK_NAME=starr
EOF
}

@test "compose-recreate mode skips docker compose when forwarded port is unchanged" {
  write_qbt_env compose-recreate
  echo 'CURRENT_PORT=40000' > "$STATE_FILE"
  echo 'QBT_PUBLISHED_PORT=40000' > "$PORT_ENV_FILE"
  printf '40000' > "$CURL_STATE"

  run env QBITTORRENT_ENV_FILE="$ENV_FILE" STATE_FILE="$STATE_FILE" CACHE_FILE="$CACHE_FILE" QBT_COMMON_SCRIPT="./proton-qbittorrent-common.sh" bash ./proton-qbittorrent-sync-safe.sh
  [ "$status" -eq 0 ]
  [ ! -s "$DOCKER_LOG" ]
  grep -F 'QBT_PUBLISHED_PORT=40000' "$PORT_ENV_FILE"
}

@test "compose-recreate mode updates the published-port artifact and recreates the service on port change" {
  write_qbt_env compose-recreate
  echo 'CURRENT_PORT=40001' > "$STATE_FILE"
  echo 'QBT_PUBLISHED_PORT=30000' > "$PORT_ENV_FILE"
  printf '30000' > "$CURL_STATE"

  run env QBITTORRENT_ENV_FILE="$ENV_FILE" STATE_FILE="$STATE_FILE" CACHE_FILE="$CACHE_FILE" QBT_COMMON_SCRIPT="./proton-qbittorrent-common.sh" bash ./proton-qbittorrent-sync-safe.sh
  [ "$status" -eq 0 ]
  grep -F 'QBT_PUBLISHED_PORT=40001' "$PORT_ENV_FILE"
  grep -F 'compose --project-directory' "$DOCKER_LOG"
  grep -F 'up -d --force-recreate --no-deps qbittorrent' "$DOCKER_LOG"
}

@test "legacy-dnat mode refreshes nft DNAT rules without invoking docker compose" {
  write_qbt_env legacy-dnat
  echo 'CURRENT_PORT=45000' > "$STATE_FILE"
  printf '45000' > "$CURL_STATE"

  run env QBITTORRENT_ENV_FILE="$ENV_FILE" STATE_FILE="$STATE_FILE" CACHE_FILE="$CACHE_FILE" QBT_COMMON_SCRIPT="./proton-qbittorrent-common.sh" bash ./proton-qbittorrent-sync-safe.sh
  [ "$status" -eq 0 ]
  grep -F 'add rule ip proton_nat prerouting tcp dport 45000 dnat to 172.18.0.10:6881 comment qbt-dnat' "$NFT_LOG"
  grep -F 'add rule ip proton_nat prerouting udp dport 45000 dnat to 172.18.0.10:6881 comment qbt-dnat' "$NFT_LOG"
  ! grep -F 'compose --project-directory' "$DOCKER_LOG"
}
