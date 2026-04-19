#!/usr/bin/env bats

setup() {
  TEST_TMPDIR="${BATS_TEST_TMPDIR:-$BATS_TMPDIR}"
  TMPBIN="$TEST_TMPDIR/bin"
  export PATH="$TMPBIN:$PATH"
  export QBITTORRENT_ENV_FILE="$TEST_TMPDIR/qb.env"
  export QBT_COMMON_SCRIPT="$TEST_TMPDIR/proton-qbittorrent-common.sh"

  mkdir -p "$TMPBIN"

  cat > "$QBITTORRENT_ENV_FILE" <<'EOF'
QBITTORRENT_URL=http://qb.test:8080
EOF

  cat > "$QBT_COMMON_SCRIPT" <<'EOF'
#!/usr/bin/env bash
qbt_source_env_file() {
  # shellcheck disable=SC1090
  source "$1"
}

qbt_webui_http_status() {
  echo 200
}

qbt_login() {
  if [[ -n "${QBT_TEST_LOGIN_ERROR:-}" ]]; then
    QBT_LOGIN_ERROR="$QBT_TEST_LOGIN_ERROR"
    return 1
  fi
  return 0
}
EOF
  chmod +x "$QBT_COMMON_SCRIPT"

  cat > "$TMPBIN/curl" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *"/api/v2/torrents/info?filter=active"*)
    printf '[{\"name\":\"active\"}]'
    ;;
  *"/api/v2/transfer/info"*)
    printf '{\"dl_info_speed\":1,\"ul_info_speed\":2}'
    ;;
esac
EOF
  chmod +x "$TMPBIN/curl"

  cat > "$TMPBIN/flock" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "$TMPBIN/flock"

  cat > "$TMPBIN/systemctl" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "$TMPBIN/systemctl"

  cat > "$TMPBIN/systemd-cat" <<'EOF'
#!/usr/bin/env bash
cat -
EOF
  chmod +x "$TMPBIN/systemd-cat"

  cat > "$TMPBIN/sleep" <<'EOF'
#!/usr/bin/env bash
exit 42
EOF
  chmod +x "$TMPBIN/sleep"
}

@test "low throughput no longer exits immediately on first increment" {
  run env \
    QBITTORRENT_ENV_FILE="$QBITTORRENT_ENV_FILE" \
    QBT_COMMON_SCRIPT="$QBT_COMMON_SCRIPT" \
    CHECK_INTERVAL=60 \
    MIN_COMBINED_SPEED_BPS=65536 \
    MAX_LOW_SPEED_CHECKS=3 \
    bash ./proton-healthcheck.sh

  [ "$status" -eq 42 ]
  [[ "$output" == *"Low throughput detected"* ]]
}

@test "failed NAT-PMP recovery reports the real non-zero exit code" {
  cat > "$TEST_TMPDIR/port-forward-once.sh" <<'EOF'
#!/usr/bin/env bash
exit 7
EOF
  chmod +x "$TEST_TMPDIR/port-forward-once.sh"

  run env \
    QBITTORRENT_ENV_FILE="$QBITTORRENT_ENV_FILE" \
    QBT_COMMON_SCRIPT="$QBT_COMMON_SCRIPT" \
    PORT_FORWARD_SCRIPT="$TEST_TMPDIR/port-forward-once.sh" \
    RECOVERY_LOCK_FILE="$TEST_TMPDIR/recovery.lock" \
    CHECK_INTERVAL=60 \
    MIN_COMBINED_SPEED_BPS=65536 \
    MAX_LOW_SPEED_CHECKS=1 \
    bash ./proton-healthcheck.sh

  [ "$status" -eq 42 ]
  [[ "$output" == *"Recovery action 'NAT-PMP refresh' failed with exit 7"* ]]
}

@test "healthcheck logs the shared qB login diagnostic when the Web UI is unreachable" {
  run env \
    QBITTORRENT_ENV_FILE="$QBITTORRENT_ENV_FILE" \
    QBT_COMMON_SCRIPT="$QBT_COMMON_SCRIPT" \
    QBT_TEST_LOGIN_ERROR="qBittorrent Web UI unreachable at http://qb.test:8080" \
    CHECK_INTERVAL=60 \
    bash ./proton-healthcheck.sh

  [ "$status" -eq 42 ]
  [[ "$output" == *"qBittorrent Web UI unreachable at http://qb.test:8080; retrying later"* ]]
}
