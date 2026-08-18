#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

ROOT_DIR="/opt/proxmox-wireguard"
[[ $EUID -eq 0 ]] || { echo "Run as root." >&2; exit 1; }

if [[ -f "${ROOT_DIR}/config/resolved.conf" ]]; then
  source "${ROOT_DIR}/config/resolved.conf"
else
  echo "resolved.conf missing; cannot persist deployment metadata." >&2
  exit 1
fi

install -d -m 0700 /etc/proxmox-wireguard

cat >/etc/proxmox-wireguard/deployment.conf <<EOF
VM_NAME="${VM_NAME}"
VM_IP="${VM_IP}"
VM_PREFIX="${VM_PREFIX}"
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
DASHBOARD_PORT="${DASHBOARD_PORT:-8443}"
EOF

chmod 0600 /etc/proxmox-wireguard/deployment.conf
echo "Deployment metadata persisted to /etc/proxmox-wireguard/deployment.conf"
