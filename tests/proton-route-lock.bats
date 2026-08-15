#!/usr/bin/env bats

setup() {
  TEST_TMPDIR="${BATS_TEST_TMPDIR:-$BATS_TMPDIR}"
  export ROUTE_LOCK_FILE="$TEST_TMPDIR/policy-routing.lock"
  export ROUTE_LOCK_READY="$TEST_TMPDIR/holder.ready"
}

@test "the global policy-route lock excludes concurrent route mutation" {
  (
    export PROTON_ROUTE_LOCK_FILE="$ROUTE_LOCK_FILE"
    export PROTON_ROUTE_LOCK_WAIT_SECONDS=5
    source ./proton-instance-common.sh
    proton_route_lock_acquire
    : > "$ROUTE_LOCK_READY"
    sleep 1
    proton_route_lock_release
  ) &
  holder_pid=$!

  for _ in {1..50}; do
    [[ -f "$ROUTE_LOCK_READY" ]] && break
    sleep 0.02
  done
  [[ -f "$ROUTE_LOCK_READY" ]]

  run env \
    PROTON_ROUTE_LOCK_FILE="$ROUTE_LOCK_FILE" \
    PROTON_ROUTE_LOCK_WAIT_SECONDS=0 \
    bash -c 'source ./proton-instance-common.sh; proton_route_lock_acquire'
  [ "$status" -ne 0 ]
  [[ "$output" == *"Timed out"* ]]

  wait "$holder_pid"

  run env \
    PROTON_ROUTE_LOCK_FILE="$ROUTE_LOCK_FILE" \
    PROTON_ROUTE_LOCK_WAIT_SECONDS=1 \
    bash -c 'source ./proton-instance-common.sh; proton_route_lock_acquire; proton_route_lock_release'
  [ "$status" -eq 0 ]
}

@test "five concurrent instances canonicalize one shared rule without EEXIST" {
  fake_bin="$TEST_TMPDIR/bin"
  rule_state="$TEST_TMPDIR/rule.state"
  ip_errors="$TEST_TMPDIR/ip.errors"
  mkdir -p "$fake_bin"
  : > "$ip_errors"

  cat > "$fake_bin/ip" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == "rule" && "$2" == "del" ]]; then
  if [[ -f "$IP_RULE_STATE" ]]; then
    rm -f "$IP_RULE_STATE"
    sleep 0.03
    exit 0
  fi
  sleep 0.03
  exit 2
fi
if [[ "$1" == "rule" && "$2" == "add" ]]; then
  if [[ -f "$IP_RULE_STATE" ]]; then
    printf 'RTNETLINK answers: File exists\n' >> "$IP_ERROR_LOG"
    exit 2
  fi
  printf '%s\n' "$*" > "$IP_RULE_STATE"
  exit 0
fi
printf 'unexpected ip invocation: %s\n' "$*" >> "$IP_ERROR_LOG"
exit 2
EOF
  chmod +x "$fake_bin/ip"

  pids=()
  for instance in lidarr prowlarr radarr sonarr whisparr; do
    (
      export PATH="$fake_bin:$PATH"
      export IP_RULE_STATE="$rule_state"
      export IP_ERROR_LOG="$ip_errors"
      export PROTON_ROUTE_LOCK_FILE="$ROUTE_LOCK_FILE"
      export PROTON_ROUTE_LOCK_WAIT_SECONDS=5
      source ./proton-instance-common.sh
      proton_route_lock_acquire
      proton_replace_ip_rule 4 from 192.168.96.0/20 to 192.168.96.0/20 lookup main priority 108
      proton_route_lock_release
    ) &
    pids+=("$!")
  done

  combined_status=0
  for pid in "${pids[@]}"; do
    wait "$pid" || combined_status=1
  done

  [ "$combined_status" -eq 0 ]
  [ "$(cat "$rule_state")" = "rule add from 192.168.96.0/20 to 192.168.96.0/20 lookup main priority 108" ]
  [ ! -s "$ip_errors" ]
}

@test "every route-mutating lifecycle path uses the shared lock" {
  grep -Fq 'proton_route_lock_acquire' proton-wg-up-safe.sh
  grep -Fq 'proton_route_lock_release' proton-wg-up-safe.sh
  grep -Fq 'proton_route_lock_acquire' proton-wg-down-safe.sh
  grep -Fq 'proton_route_lock_release' proton-wg-down-safe.sh
  grep -Fq 'reapply_routes_serialized' proton-docker-network-watcher.sh
  grep -Fq 'proton_replace_ip_rule 4' proton-wg-up-safe.sh
  grep -Fq 'proton_replace_ip_rule 4' proton-docker-network-watcher.sh
}
