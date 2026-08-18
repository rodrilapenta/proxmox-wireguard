#!/usr/bin/env bash
set -Eeuo pipefail

# Prevent host locale variables from being forwarded to minimal guests.
unset LC_ALL LC_CTYPE LANG LANGUAGE 2>/dev/null || true

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"

if [[ -f "${ROOT_DIR}/config/resolved.conf" ]]; then
  source "${ROOT_DIR}/config/resolved.conf"
else
  source "${ROOT_DIR}/config/env.conf"
fi

VM_NAME="${MANAGED_VM_NAME:-${VM_NAME:-wireguard-gateway}}"
MANAGED_TAG="${MANAGED_TAG:-proxmox-wireguard-managed}"

STATE="fresh"
DETAIL="No existing WireGuard deployment detected."
VM_EXISTS=0
VM_NAME_MATCH=0
VM_RUNNING=0
SSH_OK=0
CLOUD_INIT_DONE=0
PACKAGE_PRESENT=0
WIREGUARD_INSTALLED=0
WIREGUARD_ACTIVE=0
NFTABLES_ACTIVE=0
HEALTHCHECK_OK=0
SNAPSHOT_PRESENT=0
METADATA_PRESENT=0
HEALTH_REPORT_PRESENT=0
INSTALLED_VERSION="unknown"

ssh_opts=(
  -i "$SSH_PRIVATE_KEY"
  -o BatchMode=yes
  -o StrictHostKeyChecking=accept-new
  -o ConnectTimeout=4
)

if [[ -z "${VMID:-}" ]]; then
  while read -r id; do
    cfg="$(qm config "$id" 2>/dev/null || true)"
    tags="$(awk -F': ' '/^tags:/ {print $2; exit}' <<<"$cfg")"
    name="$(awk -F': ' '/^name:/ {print $2; exit}' <<<"$cfg")"
    if tr ';' '\n' <<<"$tags" | grep -Fxq "$MANAGED_TAG"; then VMID="$id"; break; fi
    if [[ "$name" == "$VM_NAME" && -z "${legacy_candidate:-}" ]]; then legacy_candidate="$id"; fi
  done < <(qm list | awk 'NR>1{print $1}')
  [[ -z "${VMID:-}" && -n "${legacy_candidate:-}" ]] && VMID="$legacy_candidate"
fi

if qm status "$VMID" &>/dev/null; then
  VM_EXISTS=1
  existing_name="$(qm config "$VMID" | awk -F': ' '/^name:/ {print $2; exit}')"
  [[ "$existing_name" == "$VM_NAME" ]] && VM_NAME_MATCH=1

  vm_status="$(qm status "$VMID" | awk '{print $2}')"
  [[ "$vm_status" == "running" ]] && VM_RUNNING=1
fi

if (( VM_EXISTS == 1 && VM_NAME_MATCH == 0 )); then
  STATE="foreign-vm"
  DETAIL="VMID ${VMID} exists but belongs to another VM."
else
  if (( VM_EXISTS == 1 && VM_RUNNING == 1 )) && [[ -f "$SSH_PRIVATE_KEY" ]]; then
    if ssh "${ssh_opts[@]}" "${GUEST_USER}@${VM_IP}" 'true' &>/dev/null; then
      SSH_OK=1

      if ssh "${ssh_opts[@]}" "${GUEST_USER}@${VM_IP}" \
          'sudo cloud-init status 2>/dev/null | grep -Eq "status: (done|degraded done)"' &>/dev/null; then
        CLOUD_INIT_DONE=1
      fi

      if ssh "${ssh_opts[@]}" "${GUEST_USER}@${VM_IP}" \
          'test -d /opt/proxmox-wireguard' &>/dev/null; then
        PACKAGE_PRESENT=1
        INSTALLED_VERSION="$(ssh "${ssh_opts[@]}" "${GUEST_USER}@${VM_IP}" \
          'if sudo test -f /etc/proxmox-wireguard/version; then sudo awk -F= '\''$1 == "PROJECT_VERSION" { print $2; exit }'\'' /etc/proxmox-wireguard/version; else echo 1.0.0; fi' 2>/dev/null || echo unknown)"
      fi

      if ssh "${ssh_opts[@]}" "${GUEST_USER}@${VM_IP}" \
          'sudo test -f /etc/proxmox-wireguard/deployment.conf' &>/dev/null; then
        METADATA_PRESENT=1
      fi

      if ssh "${ssh_opts[@]}" "${GUEST_USER}@${VM_IP}" \
          'sudo test -s /var/lib/proxmox-wireguard/healthcheck.last' &>/dev/null; then
        HEALTH_REPORT_PRESENT=1
      fi

      if ssh "${ssh_opts[@]}" "${GUEST_USER}@${VM_IP}" \
          'command -v wg >/dev/null && sudo test -f /etc/wireguard/wg0.conf' &>/dev/null; then
        WIREGUARD_INSTALLED=1
      fi

      if ssh "${ssh_opts[@]}" "${GUEST_USER}@${VM_IP}" \
          'sudo systemctl is-active --quiet wg-quick@wg0' &>/dev/null; then
        WIREGUARD_ACTIVE=1
      fi

      if ssh "${ssh_opts[@]}" "${GUEST_USER}@${VM_IP}" \
          'sudo systemctl is-active --quiet nftables' &>/dev/null; then
        NFTABLES_ACTIVE=1
      fi

      # A successful healthcheck persists /var/lib/proxmox-wireguard/healthcheck.ok.
      # Combine that marker with current critical service checks instead of
      # blindly rerunning all network-sensitive probes on every state detection.
      if (( WIREGUARD_ACTIVE == 1 && NFTABLES_ACTIVE == 1 )); then
        if ssh "${ssh_opts[@]}" "${GUEST_USER}@${VM_IP}" \
            'sudo test -s /var/lib/proxmox-wireguard/healthcheck.ok' &>/dev/null; then
          HEALTHCHECK_OK=1
        else
          # Legacy/current incomplete run: execute healthcheck once to establish
          # the marker. Preserve the report in the guest if it fails.
          if ssh "${ssh_opts[@]}" "${GUEST_USER}@${VM_IP}" \
              'sudo /opt/proxmox-wireguard/guest/60-healthcheck.sh >/dev/null 2>&1' &>/dev/null; then
            HEALTHCHECK_OK=1
          fi
        fi
      fi
    fi
  fi

  if qm listsnapshot "$VMID" 2>/dev/null | grep -Fq "wireguard-ready-01"; then
    SNAPSHOT_PRESENT=1
  fi

  if (( VM_EXISTS == 0 )); then
    STATE="fresh"
    DETAIL="No existing WireGuard VM."
  elif (( VM_RUNNING == 0 )); then
    STATE="vm-stopped"
    DETAIL="WireGuard VM exists but is stopped."
  elif (( SSH_OK == 0 )); then
    STATE="vm-no-ssh"
    DETAIL="WireGuard VM is running but SSH is not reachable."
  elif (( CLOUD_INIT_DONE == 0 )); then
    STATE="cloud-init-pending"
    DETAIL="SSH works but cloud-init has not completed."
  elif (( PACKAGE_PRESENT == 0 )); then
    STATE="needs-bootstrap"
    DETAIL="VM and cloud-init are ready; package has not been copied."
  elif (( WIREGUARD_INSTALLED == 0 )); then
    STATE="bootstrap-incomplete"
    DETAIL="Package exists but WireGuard is not fully installed."
  elif (( WIREGUARD_ACTIVE == 0 || NFTABLES_ACTIVE == 0 )); then
    STATE="services-incomplete"
    DETAIL="WireGuard files exist but one or more services are inactive."
  elif (( HEALTHCHECK_OK == 0 )); then
    STATE="healthcheck-failing"
    DETAIL="Services appear installed but healthcheck is not clean."
  elif (( SNAPSHOT_PRESENT == 0 )); then
    STATE="needs-snapshot"
    DETAIL="Deployment is healthy but initial snapshot is missing."
  else
    STATE="complete"
    DETAIL="WireGuard deployment is complete and healthy."
  fi
fi

cat <<EOF
STATE=${STATE}
DETAIL=${DETAIL}
VM_EXISTS=${VM_EXISTS}
VM_NAME_MATCH=${VM_NAME_MATCH}
VM_RUNNING=${VM_RUNNING}
SSH_OK=${SSH_OK}
CLOUD_INIT_DONE=${CLOUD_INIT_DONE}
PACKAGE_PRESENT=${PACKAGE_PRESENT}
WIREGUARD_INSTALLED=${WIREGUARD_INSTALLED}
WIREGUARD_ACTIVE=${WIREGUARD_ACTIVE}
NFTABLES_ACTIVE=${NFTABLES_ACTIVE}
HEALTHCHECK_OK=${HEALTHCHECK_OK}
SNAPSHOT_PRESENT=${SNAPSHOT_PRESENT}
METADATA_PRESENT=${METADATA_PRESENT}
HEALTH_REPORT_PRESENT=${HEALTH_REPORT_PRESENT}
INSTALLED_VERSION=${INSTALLED_VERSION}
EOF
