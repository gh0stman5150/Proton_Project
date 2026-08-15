#!/usr/bin/env bats

@test "units recreate /run/proton before sandboxing it writable" {
  local unit

  for unit in \
    proton-killswitch.service \
    proton-wg@.service \
    proton-port-forward@.service \
    proton-healthcheck@.service
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

@test "templated units pass instance names and keep service relationships isolated" {
  grep -Fq 'ExecStart=/usr/local/bin/proton/proton-wg-up-safe.sh %i' proton-wg@.service
  grep -Fq 'ExecStop=/usr/local/bin/proton/proton-wg-down-safe.sh %i' proton-wg@.service

  grep -Fq 'Requires=proton-wg@%i.service' proton-port-forward@.service
  grep -Fq 'ExecStartPre=/usr/local/bin/proton/proton-port-forward-healthcheck.sh %i' proton-port-forward@.service
  grep -Fq 'ExecStart=/usr/local/bin/proton/proton-port-forward-safe.sh %i' proton-port-forward@.service
  grep -Fq 'ExecStop=/usr/local/bin/proton/proton-qbt-dnat-cleanup.sh %i' proton-port-forward@.service

  grep -Fq 'Requires=proton-wg@%i.service proton-port-forward@%i.service' proton-healthcheck@.service
  grep -Fq 'ExecStart=/usr/local/bin/proton/proton-healthcheck.sh %i' proton-healthcheck@.service

  grep -Fq 'ExecStart=/usr/local/bin/proton/proton-qbt-allocate-and-sync.sh %i' proton-qbt-allocate@.service
  grep -Fq 'Requires=proton-wg@%i.service' proton-qbt-allocate@.service
  ! grep -Fq '/usr/local/bin/proton_project/' proton-qbt-allocate@.service
}
