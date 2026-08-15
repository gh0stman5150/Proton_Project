#!/usr/bin/env bash
set -euo pipefail

# Normalize per-instance Proton configs to canonical templates and back up originals.
# Creates a backup under /run/proton/instances-normalize-backup-<ts> and writes the
# backup path to /run/proton/last-normalize-backup.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPL_PROTON_ENV="$SCRIPT_DIR/proton-common.env"
TEMPL_QBT_ENV="$SCRIPT_DIR/proton-qbittorrent.env"
TEMPL_QBT_PORT_ENV="$SCRIPT_DIR/proton-qbittorrent-port.env"

INSTANCES_DIR="/etc/proton/instances"
BACKUP_ROOT="/run/proton/instances-normalize-backup-$(date +%s)"

if [[ $EUID -ne 0 ]]; then
    echo "This script must be run as root (sudo)." >&2
    exit 2
fi

mkdir -p "$BACKUP_ROOT"
chmod 700 "$BACKUP_ROOT"

if [[ ! -d "$INSTANCES_DIR" ]]; then
    echo "Instances directory missing: $INSTANCES_DIR. Creating." >&2
    mkdir -p "$INSTANCES_DIR"
    chmod 755 "$INSTANCES_DIR"
fi

found=0
for inst_path in "$INSTANCES_DIR"/*; do
    [[ -d "$inst_path" ]] || continue
    inst="$(basename "$inst_path")"
    found=1
    echo "-- Instance: $inst"

    mkdir -p "$inst_path"

    dest_proton_env="$inst_path/proton.env"
    if [[ -f "$dest_proton_env" ]]; then
        echo " backing up existing proton.env -> $BACKUP_ROOT/$inst/"
        mkdir -p "$BACKUP_ROOT/$inst"
        cp -a "$dest_proton_env" "$BACKUP_ROOT/$inst/"
    else
        echo " installing proton.env from template"
        if [[ -f "$TEMPL_PROTON_ENV" ]]; then
            cp -a "$TEMPL_PROTON_ENV" "$dest_proton_env"
        else
            echo " WARNING: template $TEMPL_PROTON_ENV not found; skipping proton.env" >&2
        fi
    fi

    if [[ -f "$dest_proton_env" ]]; then
        # ensure per-instance STATE_DIR and selection file
        if grep -q '^STATE_DIR=' "$dest_proton_env" 2>/dev/null; then
            sed -i -E "s|^STATE_DIR=.*|STATE_DIR=/run/proton/$inst|" "$dest_proton_env" || true
        else
            echo "STATE_DIR=/run/proton/$inst" >> "$dest_proton_env"
        fi

        if grep -q '^SERVER_SELECTION_FILE=' "$dest_proton_env" 2>/dev/null; then
            sed -i -E "s|^SERVER_SELECTION_FILE=.*|SERVER_SELECTION_FILE=/run/proton/$inst/current-server.env|" "$dest_proton_env" || true
        else
            echo "SERVER_SELECTION_FILE=/run/proton/$inst/current-server.env" >> "$dest_proton_env"
        fi

        if grep -q '^RECOVERY_LOCK_FILE=' "$dest_proton_env" 2>/dev/null; then
            sed -i -E "s|^RECOVERY_LOCK_FILE=.*|RECOVERY_LOCK_FILE=/run/proton/$inst/recovery.lock|" "$dest_proton_env" || true
        else
            echo "RECOVERY_LOCK_FILE=/run/proton/$inst/recovery.lock" >> "$dest_proton_env"
        fi

        chown root:root "$dest_proton_env"
        chmod 600 "$dest_proton_env"
    fi

    dest_qbt_env="$inst_path/qbittorrent.env"
    if [[ -f "$dest_qbt_env" ]]; then
        echo " backing up existing qbittorrent.env -> $BACKUP_ROOT/$inst/"
        mkdir -p "$BACKUP_ROOT/$inst"
        cp -a "$dest_qbt_env" "$BACKUP_ROOT/$inst/"
    else
        echo " installing qbittorrent.env from template"
        if [[ -f "$TEMPL_QBT_ENV" ]]; then
            cp -a "$TEMPL_QBT_ENV" "$dest_qbt_env"
        else
            echo " WARNING: template $TEMPL_QBT_ENV not found; skipping qbittorrent.env" >&2
        fi
    fi

    if [[ -f "$dest_qbt_env" ]]; then
        if grep -q '^QBT_COMPOSE_PROJECT_DIR=' "$dest_qbt_env" 2>/dev/null; then
            sed -i -E "s|^QBT_COMPOSE_PROJECT_DIR=.*|QBT_COMPOSE_PROJECT_DIR=/opt/qbittorrent-$inst|" "$dest_qbt_env" || true
        else
            echo "QBT_COMPOSE_PROJECT_DIR=/opt/qbittorrent-$inst" >> "$dest_qbt_env"
        fi

        if grep -q '^QBT_COMPOSE_SERVICE=' "$dest_qbt_env" 2>/dev/null; then
            sed -i -E "s|^QBT_COMPOSE_SERVICE=.*|QBT_COMPOSE_SERVICE=qbittorrent-$inst|" "$dest_qbt_env" || true
        else
            echo "QBT_COMPOSE_SERVICE=qbittorrent-$inst" >> "$dest_qbt_env"
        fi

        if grep -q '^QBT_PORT_ENV_FILE=' "$dest_qbt_env" 2>/dev/null; then
            sed -i -E "s|^QBT_PORT_ENV_FILE=.*|QBT_PORT_ENV_FILE=/etc/proton/instances/$inst/qbittorrent-port.env|" "$dest_qbt_env" || true
        else
            echo "QBT_PORT_ENV_FILE=/etc/proton/instances/$inst/qbittorrent-port.env" >> "$dest_qbt_env"
        fi

        if ! grep -q '^QBT_PORT_APPLY_MODE=' "$dest_qbt_env" 2>/dev/null; then
            echo "QBT_PORT_APPLY_MODE=compose-recreate" >> "$dest_qbt_env"
        fi

        chown root:root "$dest_qbt_env"
        chmod 600 "$dest_qbt_env"
    fi

    dest_qbt_port_env="$inst_path/qbittorrent-port.env"
    if [[ -f "$dest_qbt_port_env" ]]; then
        echo " backing up existing qbittorrent-port.env -> $BACKUP_ROOT/$inst/"
        mkdir -p "$BACKUP_ROOT/$inst"
        cp -a "$dest_qbt_port_env" "$BACKUP_ROOT/$inst/"
    else
        if [[ -f "$TEMPL_QBT_PORT_ENV" ]]; then
            cp -a "$TEMPL_QBT_PORT_ENV" "$dest_qbt_port_env"
        fi
    fi
    if [[ -f "$dest_qbt_port_env" ]]; then
        chown root:root "$dest_qbt_port_env"
        chmod 600 "$dest_qbt_port_env"
    fi

    echo " done $inst"
done

if [[ $found -eq 0 ]]; then
    echo "No instance directories found under $INSTANCES_DIR. Nothing changed." >&2
    exit 0
fi

echo "$BACKUP_ROOT" > /run/proton/last-normalize-backup || true
echo "Normalization complete. Backups: $BACKUP_ROOT"

exit 0
