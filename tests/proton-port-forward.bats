#!/usr/bin/env bats

setup() {
  TEST_TMPDIR="${BATS_TEST_TMPDIR:-$BATS_TMPDIR}"
  TMPBIN="$TEST_TMPDIR/bin"
  export STATE_DIR="$TEST_TMPDIR/state"
  export STATE_FILE="$STATE_DIR/proton-port.state"
  export SERVER_SELECTION_FILE="$STATE_DIR/current-server.env"
  export RECOVERY_LOCK_FILE="$STATE_DIR/recovery.lock"
  export PF_CAPABLE_PROFILES_FILE="$TEST_TMPDIR/pf-capable.tsv"
  export PF_INCAPABLE_PROFILES_FILE="$TEST_TMPDIR/pf-incapable.tsv"
  export WG_POOL_DIR="$TEST_TMPDIR/pool"
  export SERVER_POOL_ENABLED=on
  export CHECK_INTERVAL=45
  export MAX_FAILURES=1
  export NATPMP_TIMEOUT_SECONDS=1
  export PATH="$TMPBIN:$PATH"
  export SERVER_MANAGER_LOG="$TEST_TMPDIR/server-manager.log"
  export WG_UP_SCRIPT="$TEST_TMPDIR/wg-up.sh"
  export SERVER_MANAGER_SCRIPT="$TEST_TMPDIR/server-manager.sh"

  mkdir -p "$TMPBIN" "$STATE_DIR" "$WG_POOL_DIR"

  cat > "$SERVER_SELECTION_FILE" <<EOF
SELECTED_WG_PROFILE=wg-good
SELECTED_VPN_INTERFACE=wg-good
SELECTED_CONFIG=$TEST_TMPDIR/wg-good.conf
EOF

  cat > "$TMPBIN/systemd-cat" <<'EOF'
#!/usr/bin/env bash
cat - >/dev/null
EOF
  chmod +x "$TMPBIN/systemd-cat"

  cat > "$TMPBIN/flock" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "$TMPBIN/flock"

  cat > "$TMPBIN/ip" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == "-4" && "$2" == "addr" && "$3" == "show" ]]; then
  printf '3: %s    inet 10.2.0.2/32 scope global %s\n' "$4" "$4"
  exit 0
fi
exit 1
EOF
  chmod +x "$TMPBIN/ip"

  cat > "$TMPBIN/natpmpc" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
  chmod +x "$TMPBIN/natpmpc"

  cat > "$TMPBIN/timeout" <<'EOF'
#!/usr/bin/env bash
shift
"$@"
EOF
  chmod +x "$TMPBIN/timeout"

  cat > "$SERVER_MANAGER_SCRIPT" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$SERVER_MANAGER_LOG"
EOF
  chmod +x "$SERVER_MANAGER_SCRIPT"

  cat > "$WG_UP_SCRIPT" <<'EOF'
#!/usr/bin/env bash
exit 42
EOF
  chmod +x "$WG_UP_SCRIPT"
}

@test "proven port-forward profiles are cooled down instead of marked incapable after repeated failures" {
  printf 'wg-good\t1\t45678\n' > "$PF_CAPABLE_PROFILES_FILE"

  run env \
    STATE_DIR="$STATE_DIR" \
    STATE_FILE="$STATE_FILE" \
    SERVER_SELECTION_FILE="$SERVER_SELECTION_FILE" \
    RECOVERY_LOCK_FILE="$RECOVERY_LOCK_FILE" \
    PF_CAPABLE_PROFILES_FILE="$PF_CAPABLE_PROFILES_FILE" \
    PF_INCAPABLE_PROFILES_FILE="$PF_INCAPABLE_PROFILES_FILE" \
    WG_POOL_DIR="$WG_POOL_DIR" \
    SERVER_POOL_ENABLED="$SERVER_POOL_ENABLED" \
    CHECK_INTERVAL="$CHECK_INTERVAL" \
    MAX_FAILURES="$MAX_FAILURES" \
    NATPMP_TIMEOUT_SECONDS="$NATPMP_TIMEOUT_SECONDS" \
    WG_UP_SCRIPT="$WG_UP_SCRIPT" \
    SERVER_MANAGER_SCRIPT="$SERVER_MANAGER_SCRIPT" \
    SERVER_MANAGER_LOG="$SERVER_MANAGER_LOG" \
    bash ./proton-port-forward-safe.sh

  [ "$status" -eq 42 ]
  grep -F 'mark-bad wg-good port-forward-failures' "$SERVER_MANAGER_LOG"
  run grep -F 'mark-incapable wg-good natpmp-timeout' "$SERVER_MANAGER_LOG"
  [ "$status" -ne 0 ]
}

@test "unproven port-forward profiles are marked incapable after repeated failures" {
  run env \
    STATE_DIR="$STATE_DIR" \
    STATE_FILE="$STATE_FILE" \
    SERVER_SELECTION_FILE="$SERVER_SELECTION_FILE" \
    RECOVERY_LOCK_FILE="$RECOVERY_LOCK_FILE" \
    PF_CAPABLE_PROFILES_FILE="$PF_CAPABLE_PROFILES_FILE" \
    PF_INCAPABLE_PROFILES_FILE="$PF_INCAPABLE_PROFILES_FILE" \
    WG_POOL_DIR="$WG_POOL_DIR" \
    SERVER_POOL_ENABLED="$SERVER_POOL_ENABLED" \
    CHECK_INTERVAL="$CHECK_INTERVAL" \
    MAX_FAILURES="$MAX_FAILURES" \
    NATPMP_TIMEOUT_SECONDS="$NATPMP_TIMEOUT_SECONDS" \
    WG_UP_SCRIPT="$WG_UP_SCRIPT" \
    SERVER_MANAGER_SCRIPT="$SERVER_MANAGER_SCRIPT" \
    SERVER_MANAGER_LOG="$SERVER_MANAGER_LOG" \
    bash ./proton-port-forward-safe.sh

  [ "$status" -eq 42 ]
  grep -F 'mark-incapable wg-good natpmp-timeout' "$SERVER_MANAGER_LOG"
  grep -F 'mark-bad wg-good port-forward-failures' "$SERVER_MANAGER_LOG"
}
