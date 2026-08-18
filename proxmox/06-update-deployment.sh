#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

unset LC_ALL LC_CTYPE LANG LANGUAGE 2>/dev/null || true
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
source "${ROOT_DIR}/config/resolved.conf"
source "${ROOT_DIR}/VERSION"

[[ $EUID -eq 0 ]] || { echo "Run as root on Proxmox." >&2; exit 1; }
stage="/tmp/proxmox-wireguard-update-${PROJECT_VERSION}-$$"
snapshot="pre-update-${PROJECT_VERSION//./-}-$(date +%Y%m%d%H%M%S)"
ssh_opts=(-i "$SSH_PRIVATE_KEY" -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=5)
cleanup(){ ssh "${ssh_opts[@]}" "${GUEST_USER}@${VM_IP}" "sudo rm -rf '$stage'" >/dev/null 2>&1 || true; }
trap cleanup EXIT

echo "[update] Creating pre-update snapshot ${snapshot}..."
"${ROOT_DIR}/proxmox/03-snapshot-wireguard.sh" "$snapshot"
echo "[update] Backing up guest configuration..."
ssh "${ssh_opts[@]}" "${GUEST_USER}@${VM_IP}" 'sudo /opt/proxmox-wireguard/guest/50-backup-config.sh'
echo "[update] Copying ${PROJECT_VERSION} package to staging..."
tar -C "$ROOT_DIR" --exclude='.git' --exclude='config/resolved.conf' -czf - . | \
  ssh "${ssh_opts[@]}" "${GUEST_USER}@${VM_IP}" "sudo mkdir -p '$stage' && sudo tar -xzf - -C '$stage'"
echo "[update] Applying migrations..."
"${ROOT_DIR}/proxmox/06-configure-dashboard-password.sh" "$stage"
ssh -tt "${ssh_opts[@]}" "${GUEST_USER}@${VM_IP}" "sudo '$stage/guest/update-version.sh' '$stage'"
echo "[OK] Deployment updated to ${PROJECT_VERSION}."
