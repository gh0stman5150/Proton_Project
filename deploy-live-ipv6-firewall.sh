#!/usr/bin/env bash

set -euo pipefail

PROJECT_DIR="${PROJECT_DIR:-/usr/local/bin/proton_project}"
LIVE_DIR="${LIVE_DIR:-/usr/local/bin/proton}"
BACKUP_ROOT="${BACKUP_ROOT:-/var/backups/proton-ipv6-firewall}"
DEPLOY_TIMESTAMP="${DEPLOY_TIMESTAMP:-$(date -u +%Y%m%dT%H%M%SZ)}"

SCRIPTS=(
	proton-killswitch-nft.sh
	proton-killswitch-safe.sh
	proton-killswitch-reset.sh
	proton-wg-up-safe.sh
	proton-wg-down-safe.sh
	proton-docker-network-watcher.sh
)

usage() {
	cat <<'EOF'
Usage:
  deploy-live-ipv6-firewall.sh deploy
  deploy-live-ipv6-firewall.sh rollback SNAPSHOT_DIR

Deploy and rollback only copy Docker IPv6 firewall and routing executables. They
do not restart services, apply firewall rules, change Proton configuration, or
enable Docker IPv6.
EOF
}

require_root() {
	if [[ "${EUID:-$(id -u)}" -ne 0 && "${DEPLOY_ALLOW_UNPRIVILEGED_TEST:-0}" != 1 ]]; then
		echo "ERROR: Run this script as root." >&2
		exit 1
	fi
}

validate_sources() {
	local script

	for script in "${SCRIPTS[@]}"; do
		[[ -f "$PROJECT_DIR/$script" ]] || {
			echo "ERROR: Missing source: $PROJECT_DIR/$script" >&2
			exit 1
		}
		bash -n "$PROJECT_DIR/$script"
	done
}

snapshot_live() {
	local snapshot_dir="$1" script

	install -d -m 0700 "$snapshot_dir"
	for script in "${SCRIPTS[@]}"; do
		[[ -f "$LIVE_DIR/$script" ]] || {
			echo "ERROR: Missing installed script: $LIVE_DIR/$script" >&2
			exit 1
		}
		install -m 0700 "$LIVE_DIR/$script" "$snapshot_dir/$script"
	done
	(
		cd "$snapshot_dir"
		sha256sum "${SCRIPTS[@]}" >SHA256SUMS
		sha256sum -c SHA256SUMS
	)
	chmod 0600 "$snapshot_dir/SHA256SUMS"
}

install_from() {
	local source_dir="$1" script staged

	for script in "${SCRIPTS[@]}"; do
		staged="$(mktemp "$LIVE_DIR/.${script}.XXXXXX")"
		install -m 0755 "$source_dir/$script" "$staged"
		mv -f "$staged" "$LIVE_DIR/$script"
	done
}

deploy() {
	local snapshot_dir="$BACKUP_ROOT/$DEPLOY_TIMESTAMP"

	validate_sources
	install -d -m 0700 "$BACKUP_ROOT"
	snapshot_live "$snapshot_dir"

	if ! install_from "$PROJECT_DIR"; then
		echo "ERROR: Deployment failed; restoring $snapshot_dir" >&2
		install_from "$snapshot_dir"
		exit 1
	fi

	echo "Deployed Docker IPv6 executables without restarting or applying services."
	echo "Rollback snapshot: $snapshot_dir"
}

rollback() {
	local snapshot_dir="$1"
	local recovery_dir="$BACKUP_ROOT/pre-rollback-$DEPLOY_TIMESTAMP"
	local script

	[[ -d "$snapshot_dir" ]] || {
		echo "ERROR: Snapshot directory not found: $snapshot_dir" >&2
		exit 1
	}
	for script in "${SCRIPTS[@]}"; do
		[[ -f "$snapshot_dir/$script" ]] || {
			echo "ERROR: Snapshot is incomplete: $snapshot_dir/$script" >&2
			exit 1
		}
		bash -n "$snapshot_dir/$script"
	done

	install -d -m 0700 "$BACKUP_ROOT"
	snapshot_live "$recovery_dir"
	install_from "$snapshot_dir"

	echo "Restored Docker IPv6 executables from $snapshot_dir without restarting services."
	echo "Pre-rollback snapshot: $recovery_dir"
}

require_root

case "${1:-}" in
deploy)
	[[ $# -eq 1 ]] || {
		usage >&2
		exit 2
	}
	deploy
	;;
rollback)
	[[ $# -eq 2 ]] || {
		usage >&2
		exit 2
	}
	rollback "$2"
	;;
*)
	usage >&2
	exit 2
	;;
esac
