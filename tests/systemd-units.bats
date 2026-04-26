#!/usr/bin/env bats

@test "units recreate /run/proton before sandboxing it writable" {
  local unit

  for unit in \
    proton-killswitch.service \
    proton-wg.service \
    proton-port-forward.service \
    proton-healthcheck.service
  do
    if ! grep -Fq 'ReadWritePaths=' "$unit"; then
      echo "missing ReadWritePaths in $unit"
      return 1
    fi

    if ! grep -Fq '/run/proton' "$unit"; then
      echo "missing /run/proton writable path in $unit"
      return 1
    fi

    if ! grep -Fxq 'RuntimeDirectory=proton' "$unit"; then
      echo "missing RuntimeDirectory=proton in $unit"
      return 1
    fi

    if ! grep -Fxq 'RuntimeDirectoryMode=0700' "$unit"; then
      echo "missing RuntimeDirectoryMode=0700 in $unit"
      return 1
    fi

    if ! grep -Fxq 'RuntimeDirectoryPreserve=yes' "$unit"; then
      echo "missing RuntimeDirectoryPreserve=yes in $unit"
      return 1
    fi
  done
}
