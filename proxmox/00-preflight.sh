#!/usr/bin/env bash
set -Eeuo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
if [[ -f "${ROOT_DIR}/config/resolved.conf" ]]; then
  source "${ROOT_DIR}/config/resolved.conf"
else
  source "${ROOT_DIR}/config/env.conf"
fi
fail=0
ok(){ echo "[OK]   $*"; }
warn(){ echo "[WARN] $*"; }
bad(){ echo "[FAIL] $*"; fail=1; }
info(){ echo "[INFO] $*"; }
[[ $EUID -eq 0 ]] || { echo "Run as root on Proxmox." >&2; exit 1; }
command -v qm >/dev/null || { echo "qm not found; not a Proxmox host." >&2; exit 1; }

echo "=== Proxmox WireGuard preflight ==="
info "Host: $(hostname -f 2>/dev/null || hostname)"

if ip link show "$VM_BRIDGE" &>/dev/null; then ok "Bridge exists: $VM_BRIDGE"; else bad "Bridge missing: $VM_BRIDGE"; fi

detected_gw="$(ip -4 route show default | awk 'NR==1{print $3}')"
detected_dev="$(ip -4 route show default | awk 'NR==1{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1);exit}}')"
[[ -n "$detected_gw" ]] && info "Default gateway: $detected_gw via $detected_dev" || bad "No IPv4 default route."
[[ "$detected_gw" == "$LAN_GATEWAY" ]] && ok "Gateway matches $LAN_GATEWAY" || warn "Configured gateway $LAN_GATEWAY differs from live $detected_gw"

pvesm status | awk 'NR>1{print $1}' | grep -Fxq "$VM_STORAGE" && ok "VM storage exists: $VM_STORAGE" || bad "VM storage missing: $VM_STORAGE"
pvesm status | awk 'NR>1{print $1}' | grep -Fxq "$PVE_BACKUP_STORAGE" && ok "Backup storage exists: $PVE_BACKUP_STORAGE" || warn "Backup storage missing: $PVE_BACKUP_STORAGE"

if qm status "$VMID" &>/dev/null; then bad "VMID $VMID already exists."; else ok "VMID $VMID is free."; fi

conflict=0
if ping -c 2 -W 1 "$VM_IP" &>/dev/null; then conflict=1; bad "$VM_IP responds to ping."; fi
neighbor_entry="$(ip neigh show "$VM_IP" 2>/dev/null || true)"
if [[ -n "$neighbor_entry" ]]; then
  warn "$VM_IP exists in the local neighbor cache; this alone is not treated as an address conflict."
  info "Neighbor cache: $neighbor_entry"
fi
(( conflict == 0 )) && ok "No evidence that $VM_IP is occupied."

ping -c 1 -W 1 "$PIHOLE_IP" &>/dev/null && ok "Pi-hole reachable: $PIHOLE_IP" || warn "Pi-hole did not answer ping: $PIHOLE_IP"
if getent ahostsv4 "$WG_ENDPOINT" >/dev/null 2>&1; then
  resolved="$(getent ahostsv4 "$WG_ENDPOINT" | awk 'NR==1{print $1}')"
  ok "DDNS resolves: $WG_ENDPOINT -> $resolved"
else warn "DDNS does not resolve: $WG_ENDPOINT"; fi

echo
echo "--- Proposed creation ---"
echo "VMID: $VMID"
echo "Name: $VM_NAME"
echo "Bridge: $VM_BRIDGE"
echo "Storage: $VM_STORAGE"
echo "CPU/RAM/Disk: ${VM_CORES} core(s) / ${VM_MEMORY_MB} MB / ${VM_DISK_GB} GB"
echo "LAN IP: ${VM_IP}/${VM_PREFIX}"
echo "LAN: $LAN_CIDR"
echo "Gateway: $LAN_GATEWAY"
echo "DNS/Pi-hole: $PIHOLE_IP"
echo "WireGuard VPN: $WG_CIDR"
echo "WireGuard server: $WG_SERVER_IP"
echo "Endpoint: ${WG_ENDPOINT}:${WG_PORT}/UDP"
echo "-------------------------"

(( fail == 0 )) || { echo "Preflight FAILED. Nothing created."; exit 1; }
ok "Preflight passed."
if [[ "${REQUIRE_INTERACTIVE_CONFIRMATION^^}" == "YES" ]]; then
  echo
  echo "Nothing has been created yet."
  read -r -p "Create VM ${VMID} (${VM_NAME}) with the configuration above? [Y/n]: " answer
answer="${answer:-y}"
  case "${answer,,}" in
    y|yes) ;;
    *)
      echo "Cancelled. Nothing was changed."
      exit 10
      ;;
  esac
fi
touch /run/proxmox-wireguard-preflight-approved
chmod 600 /run/proxmox-wireguard-preflight-approved
ok "Creation authorized for the next create-script execution."
