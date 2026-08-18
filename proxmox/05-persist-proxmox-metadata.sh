#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
HOST_STATE_DIR="/var/lib/proxmox-wireguard"
HOST_STATE_FILE="${HOST_STATE_DIR}/deployment.conf"

[[ -f "${ROOT_DIR}/config/resolved.conf" ]] || {
  echo "resolved.conf missing; cannot persist host metadata." >&2
  exit 1
}
source "${ROOT_DIR}/config/resolved.conf"
source "${ROOT_DIR}/VERSION"

[[ $EUID -eq 0 ]] || { echo "Run as root on Proxmox." >&2; exit 1; }

install -d -m 0700 "$HOST_STATE_DIR"
cat >"$HOST_STATE_FILE" <<EOF
VMID="${VMID}"
VM_NAME="${VM_NAME}"
VM_IP="${VM_IP}"
VM_PREFIX="${VM_PREFIX}"
VM_STORAGE="${VM_STORAGE}"
VM_BRIDGE="${VM_BRIDGE}"
LAN_CIDR="${LAN_CIDR}"
LAN_GATEWAY="${LAN_GATEWAY}"
PIHOLE_IP="${PIHOLE_IP}"
WG_IF="${WG_IF}"
WG_PORT="${WG_PORT}"
WG_CIDR="${WG_CIDR}"
WG_SERVER_IP="${WG_SERVER_IP}"
WG_ENDPOINT="${WG_ENDPOINT}"
WG_DETECTED_PUBLIC_IP="${WG_DETECTED_PUBLIC_IP:-}"
WG_CLIENT_DNS="${WG_CLIENT_DNS}"
WG_PERSISTENT_KEEPALIVE="${WG_PERSISTENT_KEEPALIVE}"
WG_MTU="${WG_MTU}"
PVE_BACKUP_STORAGE="${PVE_BACKUP_STORAGE}"
PROJECT_VERSION="${PROJECT_VERSION}"
STATE_SCHEMA_VERSION="${STATE_SCHEMA_VERSION}"
DASHBOARD_PORT="${DASHBOARD_PORT:-8443}"
EOF
chmod 0600 "$HOST_STATE_FILE"
echo "[OK] Persistent host metadata written to ${HOST_STATE_FILE}."
