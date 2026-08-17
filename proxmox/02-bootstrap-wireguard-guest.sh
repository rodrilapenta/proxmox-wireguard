#!/usr/bin/env bash
set -Eeuo pipefail

# Prevent host locale variables from being forwarded to minimal guests.
unset LC_ALL LC_CTYPE LANG LANGUAGE 2>/dev/null || true
umask 077

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=/dev/null
if [[ -f "${ROOT_DIR}/config/resolved.conf" ]]; then
  source "${ROOT_DIR}/config/resolved.conf"
else
  source "${ROOT_DIR}/config/env.conf"
fi

die(){ echo "ERROR: $*" >&2; exit 1; }
log(){ echo "[bootstrap] $*"; }

[[ $EUID -eq 0 ]] || die "Run as root on the Proxmox host."
[[ -f "$SSH_PRIVATE_KEY" ]] || die "SSH_PRIVATE_KEY does not exist: $SSH_PRIVATE_KEY"
command -v ssh >/dev/null || die "ssh not found"
command -v scp >/dev/null || die "scp not found"

SSH_OPTS=(
  -i "$SSH_PRIVATE_KEY"
  -o BatchMode=yes
  -o StrictHostKeyChecking=accept-new
  -o ConnectTimeout=5
)

clear_stale_host_key() {
  command -v ssh-keygen >/dev/null 2>&1 || return 0
  ssh-keygen -f /root/.ssh/known_hosts -R "$VM_IP" >/dev/null 2>&1 || true
  ssh-keygen -f /root/.ssh/known_hosts -R "[$VM_IP]:22" >/dev/null 2>&1 || true
}


log "Waiting for cloud-init/SSH at ${VM_IP}..."
ok=0
last_ssh_error=""
for attempt in $(seq 1 60); do
  set +e
  ssh_output="$(ssh "${SSH_OPTS[@]}" "${GUEST_USER}@${VM_IP}" 'export LANG=C.UTF-8 LC_ALL=C.UTF-8; true' 2>&1)"
  ssh_rc=$?
  set -e

  if (( ssh_rc == 0 )); then
    ok=1
    break
  fi

  last_ssh_error="$ssh_output"

  if grep -q "REMOTE HOST IDENTIFICATION HAS CHANGED" <<<"$ssh_output"; then
    echo "[bootstrap-wireguard] Stale SSH host key detected for ${VM_IP}; removing old trust entry and retrying."
    clear_stale_host_key
    continue
  fi

  if (( attempt == 1 )); then
    echo "[bootstrap-wireguard] SSH not ready yet. First error:"
    printf '%s\n' "$ssh_output"
  elif (( attempt % 10 == 0 )); then
    echo "[bootstrap-wireguard] Still waiting for SSH... attempt ${attempt}/60"
  fi

  sleep 3
done

if (( ok != 1 )); then
  echo "[bootstrap-wireguard] Last SSH error:" >&2
  printf '%s\n' "$last_ssh_error" >&2
  die "SSH did not become available."
fi

log "Waiting for cloud-init to finish..."
set +e
ssh "${SSH_OPTS[@]}" "${GUEST_USER}@${VM_IP}" 'export LANG=C.UTF-8 LC_ALL=C.UTF-8; sudo cloud-init status --wait'
cloud_init_rc=$?
set -e

case "$cloud_init_rc" in
  0)
    log "cloud-init completed successfully."
    ;;
  2)
    echo "[bootstrap-wireguard] WARN: cloud-init completed in degraded state (rc=2)."
    ssh "${SSH_OPTS[@]}" "${GUEST_USER}@${VM_IP}" 'export LANG=C.UTF-8 LC_ALL=C.UTF-8; sudo cloud-init status --long' || true
    ;;
  *)
    echo "[bootstrap-wireguard] ERROR: cloud-init failed with rc=${cloud_init_rc}." >&2
    ssh "${SSH_OPTS[@]}" "${GUEST_USER}@${VM_IP}" 'export LANG=C.UTF-8 LC_ALL=C.UTF-8; sudo cloud-init status --long' || true
    exit "$cloud_init_rc"
    ;;
esac

log "Copying deployment package..."
tar -C "$ROOT_DIR" -czf - . | \
  ssh "${SSH_OPTS[@]}" "${GUEST_USER}@${VM_IP}" \
    'export LANG=C.UTF-8 LC_ALL=C.UTF-8; sudo rm -rf /opt/proxmox-wireguard && sudo mkdir -p /opt/proxmox-wireguard && sudo tar -xzf - -C /opt/proxmox-wireguard'

log "Running guest installer..."
ssh -tt "${SSH_OPTS[@]}" "${GUEST_USER}@${VM_IP}" \
  'export LANG=C.UTF-8 LC_ALL=C.UTF-8; sudo /opt/proxmox-wireguard/guest/install-all.sh'

log "Bootstrap complete."
echo
echo "Server:"
echo "  ssh -i ${SSH_PRIVATE_KEY} ${GUEST_USER}@${VM_IP}"
