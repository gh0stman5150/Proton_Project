#!/usr/bin/env bats

setup() {
  TMPBIN="$BATS_TMPDIR/bin"
  mkdir -p "$TMPBIN"
  export PATH="$TMPBIN:$PATH"
}

@test "exits non-zero when required command missing" {
  OLD_PATH="$PATH"
  # Intentionally override PATH to simulate missing commands
  # shellcheck disable=SC2123
  PATH="/nonexistent"
  run bash ./proton-qbt-dnat-cleanup.sh
  [ "$status" -ne 0 ]
  PATH="$OLD_PATH"
}

@test "exits 0 when nft present but chain absent" {
  cat > "$TMPBIN/systemd-cat" <<'EOF'
#!/usr/bin/env bash
cat -
EOF
  chmod +x "$TMPBIN/systemd-cat"

  cat > "$TMPBIN/nft" <<'EOF'
#!/usr/bin/env bash
# Simulate nft: return non-zero for 'list' to indicate chain missing
if [ "$1" = "list" ]; then
  exit 1
fi
exit 0
EOF
  chmod +x "$TMPBIN/nft"

  run bash ./proton-qbt-dnat-cleanup.sh
  [ "$status" -eq 0 ]
  [[ "$output" =~ "No DNAT chain" ]]
}
