#!/usr/bin/env bats

setup() {
  TEST_TMPDIR="${BATS_TEST_TMPDIR:-$BATS_TMPDIR}"
  TMPBIN="$TEST_TMPDIR/bin"
  mkdir -p "$TMPBIN"
  export REAL_STAT="$(command -v stat)"
  export PATH="$TMPBIN:$PATH"
  export STATE_FILE="$TEST_TMPDIR/proton-port.state"
  export CACHE_FILE="$TEST_TMPDIR/qbt-port.cache"
  export ENV_FILE="$TEST_TMPDIR/qbittorrent.env"
  export PORT_ENV_FILE="$TEST_TMPDIR/qbittorrent-port.env"
  export CURL_STATE="$TEST_TMPDIR/current-qbt-port"
  export DOCKER_LOG="$TEST_TMPDIR/docker.log"
  export NFT_LOG="$TEST_TMPDIR/nft.log"
  export CURL_LOG="$TEST_TMPDIR/curl.log"
  export PROJECT_DIR="$TEST_TMPDIR/project"
  export DOCKER_CONFIG_DIR="$TEST_TMPDIR/docker-config"
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
output_file=""
for ((i = 1; i <= $#; i++)); do
  if [[ "${!i}" == "-o" ]]; then
    next_index=$((i + 1))
    output_file="${!next_index}"
  fi
done

write_body() {
  if [[ -n "$output_file" ]]; then
    printf '%s' "$1" > "$output_file"
  else
    printf '%s' "$1"
  fi
}

printf '%s\n' "$*" >> "$CURL_LOG"
case "$*" in
  *'/api/v2/auth/login'*)
    write_body 'Ok.'
    if [[ "$*" == *'%{http_code}'* ]]; then
      printf '200'
    fi
    ;;
  *'/api/v2/app/preferences'*)
    write_body "{\"listen_port\":$(cat "$CURL_STATE")}"
    ;;
  *'/api/v2/app/setPreferences'*)
    for arg in "$@"; do
      if [[ "$arg" =~ ^json=\{\"listen_port\":([0-9]+)\}$ ]]; then
        printf '%s' "${BASH_REMATCH[1]}" > "$CURL_STATE"
      fi
    done
    ;;
  *'/api/v2/app/version'*)
    if [[ "$*" == *'%{http_code}'* ]]; then
      printf '200'
    fi
    ;;
  *)
    echo "unexpected curl invocation: $*" >&2
    exit 1
    ;;
esac
exit 0
EOF
  chmod +x "$TMPBIN/curl"

  cat > "$TMPBIN/flock" <<'EOF'
#!/usr/bin/env bash
if [[ "${QBT_TEST_FLOCK_FAIL:-}" == "1" ]]; then
  exit 1
fi
exit 0
EOF
  chmod +x "$TMPBIN/flock"

  cat > "$TMPBIN/docker" <<'EOF'
#!/usr/bin/env bash
printf 'PWD=%s DOCKER_CONFIG=%s QBT_PUBLISHED_PORT=%s CMD=%s\n' "$PWD" "${DOCKER_CONFIG:-}" "${QBT_PUBLISHED_PORT:-}" "$*" >> "$DOCKER_LOG"
if [[ "$1" == 'compose' ]]; then
  counter_file="${DOCKER_LOG}.compose-${QBT_PUBLISHED_PORT:-unset}.count"
  attempt=0
  if [[ -f "$counter_file" ]]; then
    attempt="$(cat "$counter_file")"
  fi
  attempt=$((attempt + 1))
  printf '%s' "$attempt" > "$counter_file"

  if [[ "${QBT_TEST_COMPOSE_FAIL_PORT:-}" == "${QBT_PUBLISHED_PORT:-}" ]]; then
    case "${QBT_TEST_COMPOSE_FAIL_MODE:-always}" in
      once)
        if [[ "$attempt" -eq 1 ]]; then
          printf '%s\n' "Error response from daemon: failed to bind host port 0.0.0.0:${QBT_PUBLISHED_PORT}/tcp: address already in use" >&2
          exit 1
        fi
        ;;
      always)
        printf '%s\n' "Error response from daemon: failed to bind host port 0.0.0.0:${QBT_PUBLISHED_PORT}/tcp: address already in use" >&2
        exit 1
        ;;
    esac
  fi
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

  run env QBITTORRENT_ENV_FILE="$ENV_FILE" STATE_FILE="$STATE_FILE" CACHE_FILE="$CACHE_FILE" DOCKER_CONFIG_DIR="$DOCKER_CONFIG_DIR" QBT_COMMON_SCRIPT="./proton-qbittorrent-common.sh" bash ./proton-qbittorrent-sync-safe.sh
  [ "$status" -eq 0 ]
  [ ! -s "$DOCKER_LOG" ]
  grep -F 'QBT_PUBLISHED_PORT=40000' "$PORT_ENV_FILE"
}

@test "compose-recreate mode updates the published-port artifact and recreates the service on port change" {
  write_qbt_env compose-recreate
  echo 'CURRENT_PORT=40001' > "$STATE_FILE"
  echo 'QBT_PUBLISHED_PORT=30000' > "$PORT_ENV_FILE"
  printf '30000' > "$CURL_STATE"

  run env QBITTORRENT_ENV_FILE="$ENV_FILE" STATE_FILE="$STATE_FILE" CACHE_FILE="$CACHE_FILE" DOCKER_CONFIG_DIR="$DOCKER_CONFIG_DIR" QBT_COMMON_SCRIPT="./proton-qbittorrent-common.sh" bash ./proton-qbittorrent-sync-safe.sh
  [ "$status" -eq 0 ]
  grep -F 'QBT_PUBLISHED_PORT=40001' "$PORT_ENV_FILE"
  grep -F "PWD=$PROJECT_DIR" "$DOCKER_LOG"
  grep -F "DOCKER_CONFIG=$DOCKER_CONFIG_DIR" "$DOCKER_LOG"
  grep -F 'QBT_PUBLISHED_PORT=40001' "$DOCKER_LOG"
  grep -F 'CMD=compose up -d --force-recreate --no-deps qbittorrent' "$DOCKER_LOG"
}

@test "compose-recreate mode retries a busy host port before succeeding" {
  write_qbt_env compose-recreate
  echo 'CURRENT_PORT=40001' > "$STATE_FILE"
  echo 'QBT_PUBLISHED_PORT=30000' > "$PORT_ENV_FILE"
  printf '30000' > "$CURL_STATE"

  run env QBITTORRENT_ENV_FILE="$ENV_FILE" STATE_FILE="$STATE_FILE" CACHE_FILE="$CACHE_FILE" DOCKER_CONFIG_DIR="$DOCKER_CONFIG_DIR" QBT_COMMON_SCRIPT="./proton-qbittorrent-common.sh" QBT_TEST_COMPOSE_FAIL_PORT=40001 QBT_TEST_COMPOSE_FAIL_MODE=once QBT_COMPOSE_RECREATE_RETRIES=2 QBT_COMPOSE_RECREATE_RETRY_DELAY=0 bash ./proton-qbittorrent-sync-safe.sh
  [ "$status" -eq 0 ]
  [[ "$(grep -c 'QBT_PUBLISHED_PORT=40001' "$DOCKER_LOG")" -eq 2 ]]
  grep -F 'QBT_PUBLISHED_PORT=40001' "$PORT_ENV_FILE"
}

@test "compose-recreate mode restores the previous published port after repeated bind failures" {
  write_qbt_env compose-recreate
  echo 'CURRENT_PORT=40001' > "$STATE_FILE"
  echo 'QBT_PUBLISHED_PORT=30000' > "$PORT_ENV_FILE"
  printf '30000' > "$CURL_STATE"

  run env QBITTORRENT_ENV_FILE="$ENV_FILE" STATE_FILE="$STATE_FILE" CACHE_FILE="$CACHE_FILE" DOCKER_CONFIG_DIR="$DOCKER_CONFIG_DIR" QBT_COMMON_SCRIPT="./proton-qbittorrent-common.sh" QBT_TEST_COMPOSE_FAIL_PORT=40001 QBT_TEST_COMPOSE_FAIL_MODE=always QBT_COMPOSE_RECREATE_RETRIES=2 QBT_COMPOSE_RECREATE_RETRY_DELAY=0 bash ./proton-qbittorrent-sync-safe.sh
  [ "$status" -eq 1 ]
  grep -F 'QBT_PUBLISHED_PORT=30000' "$PORT_ENV_FILE"
  grep -F 'QBT_PUBLISHED_PORT=30000' "$DOCKER_LOG"
  [[ "$(cat "$CURL_STATE")" == "30000" ]]
}

@test "compose-recreate mode skips when another sync instance already holds the lock" {
  write_qbt_env compose-recreate
  echo 'CURRENT_PORT=40001' > "$STATE_FILE"
  echo 'QBT_PUBLISHED_PORT=30000' > "$PORT_ENV_FILE"
  printf '30000' > "$CURL_STATE"

  run env QBITTORRENT_ENV_FILE="$ENV_FILE" STATE_FILE="$STATE_FILE" CACHE_FILE="$CACHE_FILE" DOCKER_CONFIG_DIR="$DOCKER_CONFIG_DIR" QBT_COMMON_SCRIPT="./proton-qbittorrent-common.sh" QBT_TEST_FLOCK_FAIL=1 bash ./proton-qbittorrent-sync-safe.sh
  [ "$status" -eq 0 ]
  [ ! -s "$DOCKER_LOG" ]
  grep -F 'QBT_PUBLISHED_PORT=30000' "$PORT_ENV_FILE"
}

@test "legacy-dnat mode refreshes nft DNAT rules without invoking docker compose" {
  write_qbt_env legacy-dnat
  echo 'CURRENT_PORT=45000' > "$STATE_FILE"
  printf '45000' > "$CURL_STATE"

  run env QBITTORRENT_ENV_FILE="$ENV_FILE" STATE_FILE="$STATE_FILE" CACHE_FILE="$CACHE_FILE" DOCKER_CONFIG_DIR="$DOCKER_CONFIG_DIR" QBT_COMMON_SCRIPT="./proton-qbittorrent-common.sh" bash ./proton-qbittorrent-sync-safe.sh
  [ "$status" -eq 0 ]
  grep -F 'add rule ip proton_nat prerouting tcp dport 45000 dnat to 172.18.0.10:6881 comment qbt-dnat' "$NFT_LOG"
  grep -F 'add rule ip proton_nat prerouting udp dport 45000 dnat to 172.18.0.10:6881 comment qbt-dnat' "$NFT_LOG"
  ! grep -F 'CMD=compose ' "$DOCKER_LOG"
}
