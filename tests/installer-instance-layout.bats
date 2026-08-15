#!/usr/bin/env bats

@test "installer bundle includes instance helper and templated units" {
  grep -Fq 'proton-instance-common.sh' install-proton-systemd.sh
  grep -Fq 'proton-wg@.service' install-proton-systemd.sh
  grep -Fq 'proton-port-forward@.service' install-proton-systemd.sh
  grep -Fq 'proton-healthcheck@.service' install-proton-systemd.sh
  grep -Fq 'proton-docker-watch@.service' install-proton-systemd.sh
  grep -Fq 'proton-qbt-allocate@.service' install-proton-systemd.sh
  grep -Fq 'proton-qbt-allocate-and-sync.sh' install-proton-systemd.sh
  grep -Fq 'qbittorrent-compose.common.yml' install-proton-systemd.sh
  grep -Fq 'qbittorrent-instances.tsv' install-proton-systemd.sh
  grep -Fq 'QBT_COMPOSE_COMMON_DIR="/opt/qbittorrent-common"' install-proton-systemd.sh
  grep -Fq 'proton-qbt-fleet-verify.sh' install-proton-systemd.sh
  grep -Fq 'proton-qbt-fleet-reconcile.sh' install-proton-systemd.sh
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
  grep -Fq 'Preserved and normalized ${port_env} to one QBT_PUBLISHED_PORT assignment' install-proton-systemd.sh
  grep -Fq 'chmod 0600 "${instance_dir}/${real_config}"' install-proton-systemd.sh
  grep -Fq 'chmod 0600 "$temp_file"' install-proton-systemd.sh
}

@test "installer includes prowlarr manual-download instance defaults" {
  grep -Fq $'prowlarr\t8082\t51057\t10.6.0.2\tpvprowlarr\t6\t51806\t116' qbittorrent-instances.tsv
  grep -Fq $'whisparr\t8085\t51054\t10.5.0.2\tpvwhisparr\t5\t51805\t115' qbittorrent-instances.tsv
  grep -Fq 'instance_manifest_value "$1" 2' install-proton-systemd.sh
  grep -Fq 'instance_manifest_value "$1" 5' install-proton-systemd.sh
  grep -Fq 'instance_manifest_value "$1" 6' install-proton-systemd.sh
  grep -Fq 'QBT_CONTAINER_NAME=qbittorrent-${instance}' install-proton-systemd.sh
  grep -Fq 'QBT_COMPOSE_PROJECT_DIR=/opt/qbittorrent-${instance}' install-proton-systemd.sh
  grep -Fq 'QBT_COMPOSE_SERVICE=qbittorrent-${instance}' install-proton-systemd.sh
  grep -Fq 'QBT_PORT_ENV_FILE=${ETC_PROTON_DIR}/instances/${instance}/qbittorrent-port.env' install-proton-systemd.sh
  grep -Fq 'QBT_NETWORK_NAME=starr_network' install-proton-systemd.sh
  grep -Fq 'normalize_instance_qbittorrent_port_env "$port_env"' install-proton-systemd.sh
  grep -Fq 'QBT_PUBLISHED_PORT=%s' install-proton-systemd.sh
  ! grep -Fq 'QBT_FORWARDED_PORT=' install-proton-systemd.sh
}

@test "instance normalizer applies unique Compose service names" {
  grep -Fq 'QBT_COMPOSE_SERVICE=qbittorrent-$inst' proton-instances-normalize.sh
}
