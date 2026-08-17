#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

green=$'\e[32m'; yellow=$'\e[33m'; red=$'\e[31m'; cyan=$'\e[36m'; reset=$'\e[0m'
log(){ printf '\n%s==>%s %s\n' "$cyan" "$reset" "$*"; }
ok(){ printf '%s[OK]%s %s\n' "$green" "$reset" "$*"; }
warn(){ printf '%s[WARN]%s %s\n' "$yellow" "$reset" "$*"; }
die(){ printf '%s[FAIL]%s %s\n' "$red" "$reset" "$*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "Run as root on the Proxmox host."
command -v qm >/dev/null || die "qm not found. Run this on Proxmox VE."

find "${SCRIPT_DIR}" -type f -name '*.sh' ! -path "${SCRIPT_DIR}/install-proxmox-wireguard.sh" -exec chmod 0750 {} +
ok "Executable permissions ensured for all child scripts."

# Discover deployment artifacts even when the project directory was freshly copied.
# VM identity is primarily the immutable Proxmox tag; fixed name is legacy fallback.
if [[ ! -f "${SCRIPT_DIR}/config/resolved.conf" ]]; then
  if [[ -s /var/lib/proxmox-wireguard/deployment.conf ]]; then
    ok "Persistent Proxmox host deployment metadata found."
  fi
  discovery="$("${SCRIPT_DIR}/proxmox/00-detect-deployment.sh")"
  managed_ids="$(awk -F= '/^MANAGED_IDS=/{print $2}' <<<"$discovery" | xargs)"
  legacy_ids="$(awk -F= '/^LEGACY_IDS=/{print $2}' <<<"$discovery" | xargs)"
  key_exists="$(awk -F= '/^KEY_EXISTS=/{print $2}' <<<"$discovery")"
  key_valid="$(awk -F= '/^KEY_PAIR_VALID=/{print $2}' <<<"$discovery")"
  key_fp="$(awk -F= '/^KEY_FINGERPRINT=/{print substr($0,index($0,"=")+1)}' <<<"$discovery")"

  if [[ -n "$managed_ids" ]]; then
    count="$(wc -w <<<"$managed_ids")"
    [[ "$count" == "1" ]] || die "Multiple VMs carry the proxmox-wireguard management tag: $managed_ids"
    detected_existing_vmid="$managed_ids"
    ok "Managed WireGuard VM found: VMID $detected_existing_vmid"
  elif [[ -n "$legacy_ids" ]]; then
    count="$(wc -w <<<"$legacy_ids")"
    [[ "$count" == "1" ]] || die "Multiple legacy VMs use the fixed name wireguard-gateway: $legacy_ids"
    detected_existing_vmid="$legacy_ids"
    warn "Legacy WireGuard VM found by fixed name: VMID $detected_existing_vmid"
  else
    detected_existing_vmid=""
  fi

  if [[ "$key_exists" == "1" ]]; then
    if [[ "$key_valid" == "1" ]]; then
      ok "Existing installer SSH key pair detected (${key_fp})."
      echo "     It will be validated against the existing guest during state detection."
    else
      warn "Installer SSH-key files exist but are not a valid matching pair."
    fi
  fi

  log "Resolving host/network configuration"
  RESOLVE_NONINTERACTIVE_EXISTING=1 RESOLVE_STATE_ONLY=1 "${SCRIPT_DIR}/proxmox/00-resolve-config.sh"
fi

source "${SCRIPT_DIR}/config/resolved.conf"
VM_NAME="${MANAGED_VM_NAME:-${VM_NAME:-wireguard-gateway}}"

detect_state() {
  declare -g STATE DETAIL VM_EXISTS VM_NAME_MATCH VM_RUNNING SSH_OK CLOUD_INIT_DONE PACKAGE_PRESENT
  declare -g WIREGUARD_INSTALLED WIREGUARD_ACTIVE NFTABLES_ACTIVE HEALTHCHECK_OK SNAPSHOT_PRESENT METADATA_PRESENT HEALTH_REPORT_PRESENT
  while IFS='=' read -r key value; do
    case "$key" in
      STATE|DETAIL|VM_EXISTS|VM_NAME_MATCH|VM_RUNNING|SSH_OK|CLOUD_INIT_DONE|PACKAGE_PRESENT|WIREGUARD_INSTALLED|WIREGUARD_ACTIVE|NFTABLES_ACTIVE|HEALTHCHECK_OK|SNAPSHOT_PRESENT|METADATA_PRESENT|HEALTH_REPORT_PRESENT)
        printf -v "$key" '%s' "$value"
        ;;
    esac
  done < <("${SCRIPT_DIR}/proxmox/00-detect-state.sh")
}

print_state() {
  echo
  echo "=================================================================="
  echo " Proxmox WireGuard - detected state"
  echo "=================================================================="
  echo "State:   $STATE"
  echo "Detail:  $DETAIL"
  echo
  printf 'VM exists:             %s\n' "$VM_EXISTS"
  printf 'VM running:            %s\n' "$VM_RUNNING"
  printf 'SSH reachable:         %s\n' "$SSH_OK"
  printf 'cloud-init done:       %s\n' "$CLOUD_INIT_DONE"
  printf 'package present:       %s\n' "$PACKAGE_PRESENT"
  printf 'WireGuard installed:   %s\n' "$WIREGUARD_INSTALLED"
  printf 'WireGuard active:      %s\n' "$WIREGUARD_ACTIVE"
  printf 'nftables active:       %s\n' "$NFTABLES_ACTIVE"
  printf 'healthcheck clean:     %s\n' "$HEALTHCHECK_OK"
  printf 'deployment metadata:   %s\n' "$METADATA_PRESENT"
  printf 'initial snapshot:      %s\n' "$SNAPSHOT_PRESENT"
  echo "=================================================================="
}

wipe_and_restart() {
  "${SCRIPT_DIR}/proxmox/99-wipe-proxmox-wireguard.sh"
  exec "$0"
}

offer_resume_or_wipe() {
  echo
  echo "Choose an action:"
  echo "  1) Continue/recover from the detected state"
  echo "  2) Wipe this WireGuard deployment and rebuild from scratch"
  echo "  3) Exit"
  read -r -p "Choice [1]: " action
  action="${action:-1}"
  case "$action" in
    1)
      if [[ -z "${WG_ENDPOINT:-}" ]]; then
        echo
        echo "Additional configuration is required to continue recovery."
        RESOLVE_NONINTERACTIVE_EXISTING=1 RESOLVE_STATE_ONLY=0 "${SCRIPT_DIR}/proxmox/00-resolve-config.sh"
        # shellcheck source=/dev/null
        source "${SCRIPT_DIR}/config/resolved.conf"
      fi

      echo
      echo "Recovered existing deployment:"
      echo "  VMID:       ${VMID}"
      echo "  Bridge:     ${VM_BRIDGE}"
      echo "  Storage:    ${VM_STORAGE}"
      echo "  VM IPv4:    ${VM_IP}/${VM_PREFIX}"
      echo "  Gateway:    ${LAN_GATEWAY}"
      echo "  LAN CIDR:   ${LAN_CIDR}"
      echo "  DNS:        ${PIHOLE_IP}"
      echo "  Endpoint:   ${WG_ENDPOINT}:${WG_PORT}"
      echo
      read -r -p "Continue/recover with these values? [Y/n]: " confirm_recovery
      confirm_recovery="${confirm_recovery:-y}"
      if [[ "$confirm_recovery" =~ ^[Yy]$ ]]; then
        return 0
      fi
      echo "Recovery cancelled. Nothing was changed."
      exit 0
      ;;
    2) wipe_and_restart ;;
    *) exit 0 ;;
  esac
}

detect_state
print_state

case "$STATE" in
  foreign-vm)
    die "Configured VMID belongs to another VM. Edit config/resolved.conf or remove it and rerun."
    ;;

  complete)
    echo
    echo "Deployment is already complete."
    echo "  1) Run healthcheck again"
    echo "  2) Wipe and rebuild from scratch"
    echo "  3) Exit"
    read -r -p "Choice [1]: " action
    action="${action:-1}"
    case "$action" in
      1)
        ssh -i "$SSH_PRIVATE_KEY" -o BatchMode=yes -o StrictHostKeyChecking=accept-new \
          "${GUEST_USER}@${VM_IP}" 'sudo /opt/proxmox-wireguard/guest/60-healthcheck.sh'
        exit $?
        ;;
      2) wipe_and_restart ;;
      *) exit 0 ;;
    esac
    ;;

  fresh)
    log "Fresh installation selected"
    "${SCRIPT_DIR}/proxmox/00-preflight.sh"
    "${SCRIPT_DIR}/proxmox/00-prepare.sh"
    "${SCRIPT_DIR}/proxmox/01-create-wireguard-vm.sh"
    ;;

  *)
    offer_resume_or_wipe
    ;;
esac

# Re-detect after possible fresh VM creation or resume decision.
detect_state

case "$STATE" in
  vm-stopped)
    log "Starting existing WireGuard VM"
    qm start "$VMID"
    sleep 2
    ;;

  vm-no-ssh|cloud-init-pending|needs-bootstrap|bootstrap-incomplete|services-incomplete|healthcheck-failing)
    log "Continuing from guest bootstrap/recovery"
    "${SCRIPT_DIR}/proxmox/02-bootstrap-wireguard-guest.sh"
    ;;

  needs-snapshot)
    log "Guest is healthy; only snapshot is missing"
    ;;

  fresh)
    # Fresh VM was just created above.
    log "Bootstrapping newly-created guest"
    "${SCRIPT_DIR}/proxmox/02-bootstrap-wireguard-guest.sh"
    ;;
esac

# Validate after bootstrap/recovery.
log "Persisting recovery metadata on Proxmox"
"${SCRIPT_DIR}/proxmox/05-persist-proxmox-metadata.sh"

log "Running final state detection"
detect_state
print_state

# If guest health is good but snapshot absent, create it.
if [[ "$HEALTHCHECK_OK" == "1" && "$SNAPSHOT_PRESENT" == "0" ]]; then
  log "Creating initial known-good snapshot"
  "${SCRIPT_DIR}/proxmox/03-snapshot-wireguard.sh" "wireguard-ready-01"
  detect_state
fi

if [[ "$HEALTHCHECK_OK" != "1" ]]; then
  warn "Installation/recovery did not reach a clean healthcheck."
  if [[ "${HEALTH_REPORT_PRESENT:-0}" == "1" ]]; then
    echo
    echo "Last guest healthcheck report:"
    ssh -i "$SSH_PRIVATE_KEY" -o BatchMode=yes -o StrictHostKeyChecking=accept-new       "${GUEST_USER}@${VM_IP}" 'sudo cat /var/lib/proxmox-wireguard/healthcheck.last' || true
  fi
  echo
  echo "Run the installer again after correcting the reported failure; state will be re-detected."
  exit 1
fi

echo
echo "=================================================================="
ok "Proxmox WireGuard is installed and healthy."
echo "=================================================================="
echo "VM:        ${VMID} - ${VM_NAME}"
echo "LAN IP:    ${VM_IP}/${VM_PREFIX}"
echo "VPN:       ${WG_SERVER_IP} on ${WG_CIDR}"
echo "Endpoint:  ${WG_ENDPOINT}:${WG_PORT}/UDP"
echo
echo "Router step:"
echo "  Forward UDP ${WG_PORT} -> ${VM_IP}:${WG_PORT}"
echo
echo "Administration:"
echo "  Deployment key:"
echo "    ssh -i ${SSH_PRIVATE_KEY} ${GUEST_USER}@${VM_IP}"
echo
echo "  Human admin access can be configured/reconfigured with:"
echo "    sudo /opt/proxmox-wireguard/guest/45-admin-access.sh"
echo
echo "Create a WireGuard client:"
echo "  sudo /opt/proxmox-wireguard/peers/wireguard-peer-add.sh <peer-name>"
