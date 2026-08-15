#!/usr/bin/env bats

@test "installer bundle includes instance helper and templated units" {
  grep -Fq 'proton-instance-common.sh' install-proton-systemd.sh
  grep -Fq 'proton-wg@.service' install-proton-systemd.sh
  grep -Fq 'proton-port-forward@.service' install-proton-systemd.sh
  grep -Fq 'proton-healthcheck@.service' install-proton-systemd.sh
  grep -Fq 'proton-docker-watch@.service' install-proton-systemd.sh
}

@test "installer retires obsolete singleton services" {
  grep -Fq 'LEGACY_SINGLETON_SERVICES=(' install-proton-systemd.sh
  grep -Fq 'proton-wg.service' install-proton-systemd.sh
  grep -Fq 'proton-port-forward.service' install-proton-systemd.sh
  grep -Fq 'proton-healthcheck.service' install-proton-systemd.sh
  grep -Fq 'systemctl disable --now "${LEGACY_SINGLETON_SERVICES[@]}"' install-proton-systemd.sh
  grep -Fq 'systemctl reset-failed "${LEGACY_SINGLETON_SERVICES[@]}"' install-proton-systemd.sh
}

@test "installer creates instance examples and preserves real configs" {
  grep -Fq '${ETC_PROTON_DIR}/instances/${instance}' install-proton-systemd.sh
  grep -Fq 'proton.env.example' install-proton-systemd.sh
  grep -Fq 'qbittorrent.env.example' install-proton-systemd.sh
  grep -Fq 'qbittorrent-port.env' install-proton-systemd.sh
  grep -Fq 'Preserved ${instance_dir}/${real_config}' install-proton-systemd.sh
  grep -Fq 'Preserved ${port_env}' install-proton-systemd.sh
  grep -Fq 'chmod 0600 "${instance_dir}/${real_config}"' install-proton-systemd.sh
  grep -Fq 'chmod 0600 "$port_env"' install-proton-systemd.sh
}

@test "installer includes prowlarr manual-download instance defaults" {
  grep -Fq 'prowlarr' install-proton-systemd.sh
  grep -Fq 'printf '"'"'%s\n'"'"' 8085' install-proton-systemd.sh
  grep -Fq 'printf '"'"'%s\n'"'"' pvprowl' install-proton-systemd.sh
  grep -Fq 'QBT_CONTAINER_NAME=qbittorrent-${instance}' install-proton-systemd.sh
  grep -Fq 'QBT_COMPOSE_PROJECT_DIR=/opt/qbittorrent-${instance}' install-proton-systemd.sh
  grep -Fq 'QBT_COMPOSE_SERVICE=qbittorrent-${instance}' install-proton-systemd.sh
  grep -Fq 'QBT_PORT_ENV_FILE=${ETC_PROTON_DIR}/instances/${instance}/qbittorrent-port.env' install-proton-systemd.sh
}

@test "instance normalizer applies unique Compose service names" {
  grep -Fq 'QBT_COMPOSE_SERVICE=qbittorrent-$inst' proton-instances-normalize.sh
}
