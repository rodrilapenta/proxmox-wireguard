#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"

if [[ -f "${ROOT_DIR}/config/resolved.conf" ]]; then
  source "${ROOT_DIR}/config/resolved.conf"
else
  source "${ROOT_DIR}/config/env.conf"
fi

VM_NAME="${MANAGED_VM_NAME:-${VM_NAME:-wireguard-gateway}}"
MANAGED_TAG="${MANAGED_TAG:-proxmox-wireguard-managed}"

die(){ echo "ERROR: $*" >&2; exit 1; }
[[ $EUID -eq 0 ]] || die "Run as root on Proxmox."

echo
echo "This will permanently delete the WireGuard deployment:"
echo "  VMID:       ${VMID}"
echo "  VM name:    ${VM_NAME}"
echo "  VM IP:      ${VM_IP}"
echo
echo "It will also remove generated cloud-init snippet and resolved config."
echo "This wipe also removes deployment SSH keys, project cache and stale SSH host-key entries for the VM IP."
echo
read -r -p "Really wipe this WireGuard deployment? [y/N]: " answer
case "${answer,,}" in
  y|yes) ;;
  *) echo "Cancelled."; exit 10 ;;
esac

if qm status "$VMID" &>/dev/null; then
  cfg="$(qm config "$VMID")"
  existing_name="$(awk -F': ' '/^name:/ {print $2; exit}' <<<"$cfg")"
  existing_tags="$(awk -F': ' '/^tags:/ {print $2; exit}' <<<"$cfg")"
  managed=0
  tr ';' '\n' <<<"$existing_tags" | grep -Fxq "$MANAGED_TAG" && managed=1 || true
  [[ "$existing_name" == "$VM_NAME" || "$managed" == "1" ]] || die "VMID $VMID is not owned by proxmox-wireguard. Refusing wipe."

  qm stop "$VMID" --skiplock 1 >/dev/null 2>&1 || true
  qm destroy "$VMID" --purge 1 --destroy-unreferenced-disks 1
fi

rm -f "/var/lib/vz/snippets/proxmox-wireguard-${VMID}-user.yaml"
rm -f "${ROOT_DIR}/config/resolved.conf"
rm -f /run/proxmox-wireguard-preflight-approved
rm -rf /var/lib/proxmox-wireguard

# Deployment SSH identity belongs to this installer and is part of a true clean reset.
if [[ -n "${SSH_PRIVATE_KEY:-}" ]]; then
  rm -f "$SSH_PRIVATE_KEY" "${SSH_PRIVATE_KEY}.pub"
fi

# Remove project-owned cloud-image cache only. This path is intentionally namespaced
# proxmox-wireguard so we never delete a generic/shared Debian image.
if [[ "${DEBIAN_IMAGE_CACHE:-}" == *"/proxmox-wireguard-"* ]]; then
  rm -f "$DEBIAN_IMAGE_CACHE" "${DEBIAN_IMAGE_CACHE}.download" "${DEBIAN_IMAGE_CACHE}.SHA512SUMS"
fi

# A fresh VM recreated on the same IP will have a new SSH host key.
# Remove the stale known_hosts entry so the next bootstrap can trust-on-first-use
# the newly-created guest instead of failing with REMOTE HOST IDENTIFICATION HAS CHANGED.
if [[ -n "${VM_IP:-}" ]] && command -v ssh-keygen >/dev/null 2>&1; then
  ssh-keygen -f /root/.ssh/known_hosts -R "$VM_IP" >/dev/null 2>&1 || true
  ssh-keygen -f /root/.ssh/known_hosts -R "[$VM_IP]:22" >/dev/null 2>&1 || true
fi

# Remove stale ARP/neighbor state for the VM IP as well. A just-destroyed VM can
# remain REACHABLE/STALE in the host neighbor cache for a while.
if [[ -n "${VM_IP:-}" ]]; then
  ip neigh del "$VM_IP" dev "${VM_BRIDGE:-vmbr0}" >/dev/null 2>&1 || true
fi

echo "[OK] WireGuard deployment, deployment SSH keys, generated config, snippets and project cache wiped."
