#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=/dev/null
if [[ -f "${ROOT_DIR}/config/resolved.conf" ]]; then
  source "${ROOT_DIR}/config/resolved.conf"
else
  source "${ROOT_DIR}/config/env.conf"
fi

VM_NAME="${MANAGED_VM_NAME:-${VM_NAME:-wireguard-gateway}}"
MANAGED_TAG="${MANAGED_TAG:-proxmox-wireguard-managed}"
MANAGED_DESCRIPTION="${MANAGED_DESCRIPTION:-Managed by proxmox-wireguard installer}"

die(){ echo "ERROR: $*" >&2; exit 1; }
log(){ echo "[create-wireguard-vm] $*"; }
cleanup_on_error() {
  rc=$?
  if (( rc != 0 )); then
    echo "[create-wireguard-vm] Failed with rc=$rc." >&2
    if qm status "$VMID" &>/dev/null; then
      echo "[create-wireguard-vm] VM $VMID was partially created; leaving it in place for inspection." >&2
    fi
  fi
  exit "$rc"
}
trap cleanup_on_error EXIT

[[ $EUID -eq 0 ]] || die "Run as root on the Proxmox host."
[[ -f /run/proxmox-wireguard-preflight-approved ]] || die "Run proxmox/00-preflight.sh and approve creation first."
rm -f /run/proxmox-wireguard-preflight-approved
for c in qm pvesm curl awk sha512sum ping; do command -v "$c" >/dev/null || die "$c not found"; done

[[ -f "$SSH_PRIVATE_KEY" && -f "${SSH_PRIVATE_KEY}.pub" ]] || \
  die "Deployment key missing. Run proxmox/00-prepare.sh first."
[[ -s "$DEBIAN_IMAGE_CACHE" ]] || die "Debian image missing. Run proxmox/00-prepare.sh first."

if qm status "$VMID" &>/dev/null; then
  die "VMID $VMID already exists. Refusing to overwrite it."
fi

if ping -c 2 -W 1 "$VM_IP" &>/dev/null; then
  die "$VM_IP answers ping. Choose/verify a free IP before continuing."
fi

pvesm status | awk 'NR>1 {print $1}' | grep -Fxq "$VM_STORAGE" || die "VM_STORAGE '$VM_STORAGE' not found."
ip link show "$VM_BRIDGE" &>/dev/null || die "Bridge '$VM_BRIDGE' not found."

log "Creating VM ${VMID} (${VM_NAME})..."
qm create "$VMID" \
  --name "$VM_NAME" \
  --tags "$MANAGED_TAG" \
  --description "$MANAGED_DESCRIPTION" \
  --memory "$VM_MEMORY_MB" \
  --balloon 0 \
  --cores "$VM_CORES" \
  --cpu host \
  --machine "$VM_MACHINE" \
  --ostype l26 \
  --scsihw virtio-scsi-single \
  --net0 "virtio,bridge=${VM_BRIDGE},firewall=0" \
  --agent "enabled=1,fstrim_cloned_disks=1" \
  --onboot "$VM_START_ON_BOOT" \
  --serial0 socket \
  --vga serial0

log "Importing Debian cloud disk to $VM_STORAGE..."
qm importdisk "$VMID" "$DEBIAN_IMAGE_CACHE" "$VM_STORAGE"

# qm importdisk produces unused0. Attach it deterministically.
unused="$(qm config "$VMID" | awk -F': ' '/^unused[0-9]+:/ {print $2; exit}')"
[[ -n "$unused" ]] || die "Could not locate imported unused disk."

qm set "$VMID" --scsi0 "${unused},discard=on,ssd=1,iothread=1"
qm set "$VMID" --ide2 "${VM_STORAGE}:cloudinit"
qm set "$VMID" --boot "order=scsi0"

SNIPPETS_DIR="/var/lib/vz/snippets"
mkdir -p "$SNIPPETS_DIR"
USER_DATA_FILE="${SNIPPETS_DIR}/proxmox-wireguard-${VMID}-user.yaml"
SSH_PUB="$(cat "${SSH_PRIVATE_KEY}.pub")"

cat >"$USER_DATA_FILE" <<EOF
#cloud-config
hostname: ${VM_NAME}
manage_etc_hosts: true
users:
  - name: ${GUEST_USER}
    groups: [sudo]
    shell: /bin/bash
    sudo: "ALL=(ALL) NOPASSWD:ALL"
    lock_passwd: true
    ssh_authorized_keys:
      - ${SSH_PUB}
ssh_pwauth: false
package_update: true
package_upgrade: true
EOF

qm set "$VMID" --cicustom "user=local:snippets/$(basename "$USER_DATA_FILE")"
qm set "$VMID" --ipconfig0 "ip=${VM_IP}/${VM_PREFIX},gw=${LAN_GATEWAY}"
qm set "$VMID" --nameserver "$PIHOLE_IP"

log "Growing root disk to ${VM_DISK_GB}G..."
qm disk resize "$VMID" scsi0 "${VM_DISK_GB}G"

log "Cloud-init preview:"
qm cloudinit dump "$VMID" user || true
qm cloudinit dump "$VMID" network || true

# Fresh VM on a reused IP means a new SSH server host key.
# Clear any stale local trust entry before first boot.
if command -v ssh-keygen >/dev/null 2>&1; then
  ssh-keygen -f /root/.ssh/known_hosts -R "$VM_IP" >/dev/null 2>&1 || true
  ssh-keygen -f /root/.ssh/known_hosts -R "[$VM_IP]:22" >/dev/null 2>&1 || true
fi

log "Starting VM..."
qm start "$VMID"

trap - EXIT
log "VM created successfully."
echo
echo "Next:"
echo "  ${ROOT_DIR}/proxmox/02-bootstrap-wireguard-guest.sh"
