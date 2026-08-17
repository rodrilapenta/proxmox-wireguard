#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

[[ $EUID -eq 0 ]] || { echo "Run with sudo/root." >&2; exit 1; }
ROOT_DIR="/opt/proxmox-wireguard"
if [[ -f "${ROOT_DIR}/config/resolved.conf" ]]; then
  source "${ROOT_DIR}/config/resolved.conf"
else
  source "${ROOT_DIR}/config/env.conf"
fi

steps=(
  10-base-system.sh
  15-persist-metadata.sh
  20-wireguard.sh
  30-nftables.sh
  40-hardening.sh
  45-admin-access.sh
)

for step in "${steps[@]}"; do
  echo
  echo "=================================================================="
  echo "Running $step"
  echo "=================================================================="
  "${ROOT_DIR}/guest/${step}"
done

echo
"${ROOT_DIR}/guest/60-healthcheck.sh"

echo
echo "Installation complete."
echo "IMPORTANT: Port forwarding on the Deco is NOT created by these scripts."
echo "Configure UDP ${WG_PORT} -> ${VM_IP}:${WG_PORT} only after local validation."
