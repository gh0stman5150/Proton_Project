#!/usr/bin/env bats

setup() {
  TMPBIN="$BATS_TMPDIR/bin"
  mkdir -p "$TMPBIN"
  export PATH="$TMPBIN:$PATH"
}

@test "all shell scripts have a shebang and pass bash -n syntax check" {
  failed=0
  while IFS= read -r -d '' script; do
    [ -f "$script" ] || { echo "MISSING: $script"; failed=1; continue; }
    first=$(sed -n '1p' "$script" 2>/dev/null || true)
    if [ "${first:0:2}" != "#!" ]; then
      echo "NO_SHEBANG: $script"
      failed=1
      continue
    fi
    run bash -n "$script"
    if [ "$status" -ne 0 ]; then
      echo "SYNTAX_ERROR in $script: $output"
      failed=1
    fi
  done < <(find . -type f -name '*.sh' -print0)

  [ "$failed" -eq 0 ]
}
