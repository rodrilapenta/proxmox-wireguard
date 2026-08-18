#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

ROOT_DIR="/opt/proxmox-wireguard"
VERSION_FILE="/etc/proxmox-wireguard/version"
[[ $EUID -eq 0 ]] || { echo "Run as root." >&2; exit 1; }
source "${ROOT_DIR}/VERSION"
install -d -m 0700 /etc/proxmox-wireguard
cat >"$VERSION_FILE" <<EOF
PROJECT_VERSION=${PROJECT_VERSION}
STATE_SCHEMA_VERSION=${STATE_SCHEMA_VERSION}
UPDATED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF
chmod 0600 "$VERSION_FILE"
echo "[OK] Recorded installed version ${PROJECT_VERSION}."
