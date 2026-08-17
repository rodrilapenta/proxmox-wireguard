#!/usr/bin/env bash
set -Eeuo pipefail

# Prevent host locale variables from being forwarded to minimal guests.
unset LC_ALL LC_CTYPE LANG LANGUAGE 2>/dev/null || true

RESOLVE_NONINTERACTIVE_EXISTING="${RESOLVE_NONINTERACTIVE_EXISTING:-0}"
RESOLVE_STATE_ONLY="${RESOLVE_STATE_ONLY:-0}"

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
source "${ROOT_DIR}/config/env.conf"

HOST_STATE_FILE="/var/lib/proxmox-wireguard/deployment.conf"

die(){ echo "ERROR: $*" >&2; exit 1; }
ask() {
  local prompt="$1" default="$2" value
  if [[ -n "$default" ]]; then
    read -r -p "${prompt} [${default}]: " value
    printf '%s' "${value:-$default}"
  else
    read -r -p "${prompt}: " value
    printf '%s' "$value"
  fi
}

is_ipv4() {
  local ip="$1"
  python3 - "$ip" <<'PY' >/dev/null 2>&1
import ipaddress, sys
try:
    ipaddress.IPv4Address(sys.argv[1])
except Exception:
    raise SystemExit(1)
PY
}

is_public_ipv4() {
  local ip="$1"
  python3 - "$ip" <<'PY' >/dev/null 2>&1
import ipaddress, sys
ip = ipaddress.IPv4Address(sys.argv[1])
raise SystemExit(0 if ip.is_global else 1)
PY
}

detect_public_ipv4() {
  local ip=""
  local urls=(
    "https://api.ipify.org"
    "https://ifconfig.me/ip"
    "https://ipv4.icanhazip.com"
  )

  for url in "${urls[@]}"; do
    ip="$(curl -4fsS --max-time 5 "$url" 2>/dev/null | tr -d '[:space:]' || true)"
    if [[ -n "$ip" ]] && is_ipv4 "$ip"; then
      printf '%s' "$ip"
      return 0
    fi
  done
  return 1
}

resolve_ipv4() {
  local host="$1"
  getent ahostsv4 "$host" 2>/dev/null | awk 'NR==1{print $1}'
}

[[ $EUID -eq 0 ]] || die "Run as root on the Proxmox host."
command -v qm >/dev/null || die "qm not found. Run this on Proxmox VE."
command -v curl >/dev/null || die "curl is required on the Proxmox host."
command -v python3 >/dev/null || die "python3 is required on the Proxmox host."

VM_NAME="$MANAGED_VM_NAME"

load_host_state() {
  HOST_STATE_FOUND=0
  if [[ -s "$HOST_STATE_FILE" ]]; then
    # shellcheck source=/dev/null
    source "$HOST_STATE_FILE"
    HOST_STATE_FOUND=1
  fi
}

find_managed_vm() {
  local id tags name
  while read -r id; do
    [[ "$id" =~ ^[0-9]+$ ]] || continue
    tags="$(qm config "$id" 2>/dev/null | awk -F': ' '/^tags:/ {print $2; exit}')"
    if tr ';' '\n' <<<"$tags" | grep -Fxq "$MANAGED_TAG"; then
      printf '%s' "$id"
      return 0
    fi
  done < <(qm list | awk 'NR>1{print $1}')
  return 1
}

find_legacy_vm() {
  local id name
  while read -r id; do
    [[ "$id" =~ ^[0-9]+$ ]] || continue
    name="$(qm config "$id" 2>/dev/null | awk -F': ' '/^name:/ {print $2; exit}')"
    if [[ "$name" == "$MANAGED_VM_NAME" ]]; then
      printf '%s' "$id"
      return 0
    fi
  done < <(qm list | awk 'NR>1{print $1}')
  return 1
}

load_host_state
existing_managed_vmid="$(find_managed_vm || true)"

if [[ "${HOST_STATE_FOUND:-0}" == "1" && -n "${VMID:-}" ]] && qm status "$VMID" &>/dev/null; then
  host_cfg="$(qm config "$VMID" 2>/dev/null || true)"
  host_tags="$(awk -F': ' '/^tags:/ {print $2; exit}' <<<"$host_cfg")"
  host_name="$(awk -F': ' '/^name:/ {print $2; exit}' <<<"$host_cfg")"
  if tr ';' '\n' <<<"$host_tags" | grep -Fxq "$MANAGED_TAG" || [[ "$host_name" == "$MANAGED_VM_NAME" ]]; then
    existing_managed_vmid="$VMID"
  fi
fi

legacy_vmid=""
if [[ -z "$existing_managed_vmid" ]]; then
  legacy_vmid="$(find_legacy_vm || true)"
fi


read_existing_vm_config() {
  local id="$1" cfg ipconfig netline scsi storage
  cfg="$(qm config "$id")"

  EXISTING_VM_NAME="$(awk -F': ' '/^name:/ {print $2; exit}' <<<"$cfg")"
  EXISTING_VM_BRIDGE="$(awk -F'bridge=' '/^net0:/ {split($2,a,","); print a[1]; exit}' <<<"$cfg")"

  ipconfig="$(awk -F': ' '/^ipconfig0:/ {print $2; exit}' <<<"$cfg")"
  EXISTING_VM_IP_CIDR="$(sed -n 's/.*ip=\([^,]*\).*/\1/p' <<<"$ipconfig")"
  EXISTING_VM_IP="${EXISTING_VM_IP_CIDR%/*}"
  EXISTING_VM_PREFIX="${EXISTING_VM_IP_CIDR#*/}"
  EXISTING_VM_GATEWAY="$(sed -n 's/.*gw=\([^,]*\).*/\1/p' <<<"$ipconfig")"

  EXISTING_VM_DNS="$(awk -F': ' '/^nameserver:/ {print $2; exit}' <<<"$cfg")"

  scsi="$(awk -F': ' '/^scsi0:/ {print $2; exit}' <<<"$cfg")"
  EXISTING_VM_STORAGE="${scsi%%:*}"

  EXISTING_VM_MEMORY="$(awk -F': ' '/^memory:/ {print $2; exit}' <<<"$cfg")"
  EXISTING_VM_CORES="$(awk -F': ' '/^cores:/ {print $2; exit}' <<<"$cfg")"

  # Derive LAN CIDR from the VM IP/prefix.
  if [[ -n "$EXISTING_VM_IP_CIDR" ]]; then
    EXISTING_VM_LAN_CIDR="$(python3 - <<PY
import ipaddress
print(ipaddress.ip_interface("${EXISTING_VM_IP_CIDR}").network)
PY
)"
  else
    EXISTING_VM_LAN_CIDR=""
  fi
}

read_proxmox_managed_metadata() {
  PROXMOX_METADATA_FOUND=0
  PROXMOX_WG_ENDPOINT=""
  PROXMOX_WG_PORT=""
  PROXMOX_WG_CIDR=""
  PROXMOX_WG_SERVER_IP=""
  PROXMOX_WG_CLIENT_DNS=""
  PROXMOX_WG_MTU=""
  PROXMOX_WG_KEEPALIVE=""
  PROXMOX_PUBLIC_IP=""

  local id="$1"
  local cfg desc block
  cfg="$(qm config "$id" 2>/dev/null || true)"
  desc="$(awk -F': ' '/^description:/ {print substr($0,index($0,":")+2); exit}' <<<"$cfg")"

  block="$(python3 - "$desc" <<'PY'
import sys
desc=sys.argv[1]
b="WIREGUARD_HOME_METADATA_BEGIN"
e="WIREGUARD_HOME_METADATA_END"
if b in desc and e in desc:
    print(desc.split(b,1)[1].split(e,1)[0].strip())
PY
)"
  [[ -n "$block" ]] || return 0

  PROXMOX_METADATA_FOUND=1
  meta_get() {
    local key="$1"
    awk -F= -v k="$key" '$1==k {print substr($0,index($0,"=")+1); exit}' <<<"$block"
  }

  PROXMOX_WG_ENDPOINT="$(meta_get WG_ENDPOINT)"
  PROXMOX_WG_PORT="$(meta_get WG_PORT)"
  PROXMOX_WG_CIDR="$(meta_get WG_CIDR)"
  PROXMOX_WG_SERVER_IP="$(meta_get WG_SERVER_IP)"
  PROXMOX_WG_CLIENT_DNS="$(meta_get WG_CLIENT_DNS)"
  PROXMOX_WG_MTU="$(meta_get WG_MTU)"
  PROXMOX_WG_KEEPALIVE="$(meta_get WG_PERSISTENT_KEEPALIVE)"
  PROXMOX_PUBLIC_IP="$(meta_get WG_DETECTED_PUBLIC_IP)"
}

read_guest_metadata_via_qga() {
  QGA_METADATA_FOUND=0
  QGA_METADATA=""

  local id="$1"
  command -v jq >/dev/null 2>&1 || return 0

  # qemu guest agent is optional during early/legacy recovery.
  local json
  json="$(qm guest exec "$id" -- /bin/sh -c \
    'if [ -f /etc/proxmox-wireguard/deployment.conf ]; then cat /etc/proxmox-wireguard/deployment.conf; elif [ -f /opt/proxmox-wireguard/config/resolved.conf ]; then cat /opt/proxmox-wireguard/config/resolved.conf; fi' \
    2>/dev/null || true)"

  [[ -n "$json" ]] || return 0

  # Proxmox returns command output as JSON. Decode stdout if present.
  QGA_METADATA="$(jq -r '."out-data" // ."out_data" // empty' <<<"$json" 2>/dev/null || true)"
  [[ -n "$QGA_METADATA" ]] || return 0
  QGA_METADATA_FOUND=1
}

apply_metadata_blob() {
  local metadata="$1"

  conf_get_blob() {
    local key="$1"
    awk -F= -v k="$key" '$1==k {
      v=substr($0,index($0,"=")+1)
      gsub(/^"|"$/,"",v)
      print v
      exit
    }' <<<"$metadata"
  }

  EXISTING_WG_ENDPOINT="$(conf_get_blob WG_ENDPOINT)"
  EXISTING_WG_PORT="$(conf_get_blob WG_PORT)"
  EXISTING_WG_CIDR="$(conf_get_blob WG_CIDR)"
  EXISTING_WG_SERVER_IP="$(conf_get_blob WG_SERVER_IP)"
  EXISTING_WG_CLIENT_DNS="$(conf_get_blob WG_CLIENT_DNS)"
  EXISTING_WG_MTU="$(conf_get_blob WG_MTU)"
  EXISTING_WG_KEEPALIVE="$(conf_get_blob WG_PERSISTENT_KEEPALIVE)"
  EXISTING_PUBLIC_IP="$(conf_get_blob WG_DETECTED_PUBLIC_IP)"
}

read_existing_guest_metadata() {
  EXISTING_GUEST_METADATA_FOUND=0
  EXISTING_WG_ENDPOINT=""
  EXISTING_WG_PORT=""
  EXISTING_WG_CIDR=""
  EXISTING_WG_SERVER_IP=""
  EXISTING_WG_CLIENT_DNS=""
  EXISTING_WG_MTU=""
  EXISTING_WG_KEEPALIVE=""
  EXISTING_PUBLIC_IP=""

  [[ -n "${EXISTING_VM_IP:-}" ]] || return 0
  [[ -f "$SSH_PRIVATE_KEY" ]] || return 0

  local metadata=""
  local ssh_opts=(
    -i "$SSH_PRIVATE_KEY"
    -o BatchMode=yes
    -o StrictHostKeyChecking=accept-new
    -o ConnectTimeout=4
  )

  metadata="$(ssh "${ssh_opts[@]}" "${GUEST_USER}@${EXISTING_VM_IP}" \
    'export LANG=C.UTF-8 LC_ALL=C.UTF-8;
     if sudo test -f /etc/proxmox-wireguard/deployment.conf; then
       sudo cat /etc/proxmox-wireguard/deployment.conf;
     elif sudo test -f /opt/proxmox-wireguard/config/resolved.conf; then
       sudo cat /opt/proxmox-wireguard/config/resolved.conf;
     fi' 2>/dev/null || true)"

  [[ -n "$metadata" ]] || return 0
  EXISTING_GUEST_METADATA_FOUND=1

  conf_get() {
    local key="$1"
    awk -F= -v k="$key" '$1==k {
      v=substr($0,index($0,"=")+1)
      gsub(/^"|"$/,"",v)
      print v
      exit
    }' <<<"$metadata"
  }

  EXISTING_WG_ENDPOINT="$(conf_get WG_ENDPOINT)"
  EXISTING_WG_PORT="$(conf_get WG_PORT)"
  EXISTING_WG_CIDR="$(conf_get WG_CIDR)"
  EXISTING_WG_SERVER_IP="$(conf_get WG_SERVER_IP)"
  EXISTING_WG_CLIENT_DNS="$(conf_get WG_CLIENT_DNS)"
  EXISTING_WG_MTU="$(conf_get WG_MTU)"
  EXISTING_WG_KEEPALIVE="$(conf_get WG_PERSISTENT_KEEPALIVE)"
  EXISTING_PUBLIC_IP="$(conf_get WG_DETECTED_PUBLIC_IP)"
}

# Bridge and default route
detected_gateway="$(ip -4 route show default | awk 'NR==1{print $3}')"
detected_bridge="$(ip -4 route show default | awk 'NR==1{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')"

[[ -n "$detected_gateway" ]] || die "Could not detect an IPv4 default gateway."
[[ -n "$detected_bridge" ]] || die "Could not detect the default-route interface."

# Prefix / LAN CIDR from the detected interface
detected_addr_cidr="$(ip -4 -o addr show dev "$detected_bridge" scope global | awk 'NR==1{print $4}')"
[[ -n "$detected_addr_cidr" ]] || die "Could not detect an IPv4 address on $detected_bridge."

detected_ip="${detected_addr_cidr%/*}"
detected_prefix="${detected_addr_cidr#*/}"

# Calculate network CIDR using Python's ipaddress if available, else ipcalc if available.
if command -v python3 >/dev/null 2>&1; then
  detected_lan_cidr="$(python3 - <<PY
import ipaddress
print(ipaddress.ip_interface("${detected_addr_cidr}").network)
PY
)"
elif command -v ipcalc >/dev/null 2>&1; then
  detected_lan_cidr="$(ipcalc -n "$detected_addr_cidr" | awk -F'= ' '/Network/ {print $2; exit}')"
else
  die "Need python3 or ipcalc to derive LAN CIDR."
fi

# VM storage: prefer local-lvm, otherwise first active storage that supports images.
detected_vm_storage=""
if pvesm status | awk 'NR>1 && $3=="active"{print $1}' | grep -Fxq "local-lvm"; then
  detected_vm_storage="local-lvm"
else
  while read -r st; do
    [[ -z "$st" ]] && continue
    content="$(pvesm status --storage "$st" 2>/dev/null | awk 'NR==2{print $1}')"
    # Fallback: inspect storage config if needed.
    if pvesm config "$st" 2>/dev/null | grep -qE 'content .*images'; then
      detected_vm_storage="$st"
      break
    fi
  done < <(pvesm status | awk 'NR>1 && $3=="active"{print $1}')
fi
[[ -n "$detected_vm_storage" ]] || detected_vm_storage="local-lvm"

# Backup storage: prefer "local", else first active storage supporting backup.
detected_backup_storage=""
if pvesm status | awk 'NR>1 && $3=="active"{print $1}' | grep -Fxq "local"; then
  detected_backup_storage="local"
else
  while read -r st; do
    [[ -z "$st" ]] && continue
    if pvesm config "$st" 2>/dev/null | grep -qE 'content .*backup'; then
      detected_backup_storage="$st"
      break
    fi
  done < <(pvesm status | awk 'NR>1 && $3=="active"{print $1}')
fi

# Reuse a managed deployment VMID if found. For pre-v9 installations, a fixed-name
# legacy VM is offered for adoption. Only when neither exists do we choose a free VMID.
detected_vmid=""
if [[ -n "$existing_managed_vmid" ]]; then
  detected_vmid="$existing_managed_vmid"
elif [[ -n "$legacy_vmid" ]]; then
  echo
  echo "[INFO] Legacy WireGuard VM detected: VMID ${legacy_vmid}, name ${MANAGED_VM_NAME}"
  read -r -p "Adopt this legacy VM into proxmox-wireguard management? [Y/n]: " adopt_answer
  case "${adopt_answer,,}" in
    ""|y|yes)
      qm set "$legacy_vmid" --tags "$MANAGED_TAG" --description "$MANAGED_DESCRIPTION" >/dev/null
      detected_vmid="$legacy_vmid"
      existing_managed_vmid="$legacy_vmid"
      echo "[OK] Legacy VM adopted and tagged: $MANAGED_TAG"
      ;;
    *)
      echo "[INFO] Legacy VM not adopted."
      ;;
  esac
fi

if [[ -z "$detected_vmid" ]]; then
  for candidate in $(seq 110 999); do
    if ! qm status "$candidate" &>/dev/null && ! pct status "$candidate" &>/dev/null; then
      detected_vmid="$candidate"
      break
    fi
  done
fi
[[ -n "$detected_vmid" ]] || die "Could not find or select a VMID."

if [[ -n "$existing_managed_vmid" ]]; then
  read_existing_vm_config "$existing_managed_vmid"

  # Recovery precedence:
  # 1. Persistent Proxmox host state (/var/lib/proxmox-wireguard/deployment.conf)
  # 2. Proxmox VM metadata
  # 3. QEMU Guest Agent
  # 4. SSH guest metadata
  EXISTING_GUEST_METADATA_FOUND=0
  EXISTING_WG_ENDPOINT=""
  EXISTING_WG_PORT=""
  EXISTING_WG_CIDR=""
  EXISTING_WG_SERVER_IP=""
  EXISTING_WG_CLIENT_DNS=""
  EXISTING_WG_MTU=""
  EXISTING_WG_KEEPALIVE=""
  EXISTING_PUBLIC_IP=""

  if [[ "${HOST_STATE_FOUND:-0}" == "1" && -n "${WG_ENDPOINT:-}" ]]; then
    EXISTING_WG_ENDPOINT="${WG_ENDPOINT:-}"
    EXISTING_WG_PORT="${WG_PORT:-}"
    EXISTING_WG_CIDR="${WG_CIDR:-}"
    EXISTING_WG_SERVER_IP="${WG_SERVER_IP:-}"
    EXISTING_WG_CLIENT_DNS="${WG_CLIENT_DNS:-${PIHOLE_IP:-}}"
    EXISTING_WG_MTU="${WG_MTU:-}"
    EXISTING_WG_KEEPALIVE="${WG_PERSISTENT_KEEPALIVE:-}"
    EXISTING_PUBLIC_IP="${WG_DETECTED_PUBLIC_IP:-}"
    EXISTING_GUEST_METADATA_FOUND=1
    EXISTING_METADATA_SOURCE="Proxmox host state"
  fi

  if [[ "$EXISTING_GUEST_METADATA_FOUND" != "1" ]]; then
    read_proxmox_managed_metadata "$existing_managed_vmid"
    if [[ "$PROXMOX_METADATA_FOUND" == "1" ]]; then
      EXISTING_WG_ENDPOINT="$PROXMOX_WG_ENDPOINT"
      EXISTING_WG_PORT="$PROXMOX_WG_PORT"
      EXISTING_WG_CIDR="$PROXMOX_WG_CIDR"
      EXISTING_WG_SERVER_IP="$PROXMOX_WG_SERVER_IP"
      EXISTING_WG_CLIENT_DNS="$PROXMOX_WG_CLIENT_DNS"
      EXISTING_WG_MTU="$PROXMOX_WG_MTU"
      EXISTING_WG_KEEPALIVE="$PROXMOX_WG_KEEPALIVE"
      EXISTING_PUBLIC_IP="$PROXMOX_PUBLIC_IP"
      EXISTING_GUEST_METADATA_FOUND=1
      EXISTING_METADATA_SOURCE="Proxmox VM metadata"
    fi
  fi

  if [[ "$EXISTING_GUEST_METADATA_FOUND" != "1" ]]; then
    read_guest_metadata_via_qga "$existing_managed_vmid"
    if [[ "$QGA_METADATA_FOUND" == "1" ]]; then
      apply_metadata_blob "$QGA_METADATA"
      EXISTING_GUEST_METADATA_FOUND=1
      EXISTING_METADATA_SOURCE="QEMU Guest Agent"
    fi
  fi

  if [[ "$EXISTING_GUEST_METADATA_FOUND" != "1" ]]; then
    read_existing_guest_metadata
    if [[ "$EXISTING_GUEST_METADATA_FOUND" == "1" ]]; then
      EXISTING_METADATA_SOURCE="SSH guest metadata"
    fi
  fi
fi

# Suggest VM IP only for a NEW deployment. Existing managed deployments must
# retain the VM's actual configured address.
# We deliberately prefer no magic reservation assumption; user confirms.
detected_vm_ip=""
if [[ -n "$existing_managed_vmid" ]]; then
  detected_vm_ip="$EXISTING_VM_IP"
else
  network_base="${detected_lan_cidr%/*}"
  if command -v python3 >/dev/null 2>&1; then
    mapfile -t candidates < <(python3 - <<PY
import ipaddress
net=ipaddress.ip_network("${detected_lan_cidr}", strict=False)
for ip in list(net.hosts())[9:250]:
    print(ip)
PY
)
    for candidate in "${candidates[@]}"; do
      [[ "$candidate" == "$detected_gateway" || "$candidate" == "$detected_ip" ]] && continue
      if ! ping -c 1 -W 1 "$candidate" &>/dev/null; then
        detected_vm_ip="$candidate"
        break
      fi
    done
  fi
fi

# DNS default: current resolver if it is a LAN IP, otherwise gateway.
detected_dns="$(awk '/^nameserver /{print $2; exit}' /etc/resolv.conf)"
[[ -z "$detected_dns" ]] && detected_dns="$detected_gateway"

detected_public_ip=""
if detected_public_ip="$(detect_public_ipv4)"; then
  if is_public_ipv4 "$detected_public_ip"; then
    :
  else
    echo "[WARN] External service returned a non-global IPv4: $detected_public_ip" >&2
  fi
else
  detected_public_ip=""
fi

echo
echo "Detected environment:"
echo "  Interface/bridge:    $detected_bridge"
echo "  Proxmox IPv4:        $detected_ip/$detected_prefix"
echo "  LAN:                 $detected_lan_cidr"
echo "  Gateway:             $detected_gateway"
echo "  VM storage:          $detected_vm_storage"
echo "  Backup storage:      ${detected_backup_storage:-<none detected>}"
echo "  Suggested VMID:      $detected_vmid"
echo "  Suggested VM IP:     ${detected_vm_ip:-<enter manually>}"
if [[ -n "$existing_managed_vmid" ]]; then
  echo "  Existing VM config:   detected and will be reused"
  echo "  Existing VM IP:       ${EXISTING_VM_IP_CIDR}"
  echo "  Existing VM bridge:   ${EXISTING_VM_BRIDGE}"
  echo "  Existing VM storage:  ${EXISTING_VM_STORAGE}"
  echo "  Existing VM DNS:      ${EXISTING_VM_DNS:-<none>}"
  if [[ "${EXISTING_GUEST_METADATA_FOUND:-0}" == "1" ]]; then
    echo "  Deployment metadata:  ${EXISTING_METADATA_SOURCE:-recovered}"
    echo "  WireGuard endpoint:   ${EXISTING_WG_ENDPOINT:-<missing>}"
  else
    echo "  Deployment metadata:  not found in guest"
  fi
else
  echo "  Suggested DNS:       $detected_dns"
fi
echo "  Public IPv4:         ${detected_public_ip:-<not detected>}"
echo

if [[ -n "$existing_managed_vmid" ]]; then
  resolved_vmid="$existing_managed_vmid"
  resolved_bridge="${EXISTING_VM_BRIDGE:-$detected_bridge}"
  resolved_storage="${EXISTING_VM_STORAGE:-$detected_vm_storage}"
  resolved_backup="${PVE_BACKUP_STORAGE:-$detected_backup_storage}"
  resolved_vm_ip="${EXISTING_VM_IP}"
  resolved_prefix="${EXISTING_VM_PREFIX}"
  resolved_gateway="${EXISTING_VM_GATEWAY:-$detected_gateway}"
  resolved_lan="${EXISTING_VM_LAN_CIDR:-$detected_lan_cidr}"
  resolved_dns="${EXISTING_WG_CLIENT_DNS:-${EXISTING_VM_DNS:-${WG_CLIENT_DNS:-${PIHOLE_IP:-$detected_dns}}}}"

  echo
  echo "Reusing existing managed VM configuration:"
  echo "  VMID:       $resolved_vmid"
  echo "  Bridge:     $resolved_bridge"
  echo "  Storage:    $resolved_storage"
  echo "  VM IPv4:    $resolved_vm_ip/$resolved_prefix"
  echo "  Gateway:    $resolved_gateway"
  echo "  LAN CIDR:   $resolved_lan"
  echo "  DNS:        $resolved_dns"
  echo
  if [[ "$RESOLVE_NONINTERACTIVE_EXISTING" != "1" ]]; then
    read -r -p "Use these existing VM values? [Y/n]: " existing_values_answer
    case "${existing_values_answer,,}" in
      ""|y|yes) ;;
      *) die "Existing managed VM values were rejected. Use wipe/rebuild for a different VM configuration." ;;
    esac
  else
    echo "Existing deployment values recovered for state detection."
  fi
else
  resolved_vmid="$(ask "VMID" "${VMID:-$detected_vmid}")"
  resolved_bridge="$(ask "Proxmox bridge/interface" "${VM_BRIDGE:-$detected_bridge}")"
  resolved_storage="$(ask "VM storage" "${VM_STORAGE:-$detected_vm_storage}")"
  resolved_backup="$(ask "Backup storage" "${PVE_BACKUP_STORAGE:-$detected_backup_storage}")"
  resolved_vm_ip="$(ask "Static IPv4 for WireGuard VM" "${VM_IP:-$detected_vm_ip}")"
  resolved_prefix="$(ask "LAN prefix length" "${VM_PREFIX:-$detected_prefix}")"
  resolved_gateway="$(ask "LAN gateway" "${LAN_GATEWAY:-$detected_gateway}")"
  resolved_lan="$(ask "LAN CIDR" "${LAN_CIDR:-$detected_lan_cidr}")"
  resolved_dns="$(ask "DNS server for VM and VPN clients" "${WG_CLIENT_DNS:-${PIHOLE_IP:-$detected_dns}}")"
fi
resolved_endpoint=""
if [[ -n "${EXISTING_WG_ENDPOINT:-}" ]]; then
  resolved_endpoint="$EXISTING_WG_ENDPOINT"
  echo
  echo "Recovered WireGuard endpoint from existing deployment:"
  echo "  $resolved_endpoint"

  resolved_dns_ip="$(resolve_ipv4 "$resolved_endpoint" || true)"
  if [[ -n "$resolved_dns_ip" && -n "$detected_public_ip" ]]; then
    if [[ "$resolved_dns_ip" == "$detected_public_ip" ]]; then
      echo "  [OK] Endpoint resolves to current public IPv4 ($detected_public_ip)."
    else
      echo "  [WARN] Endpoint resolves to $resolved_dns_ip but public IPv4 is $detected_public_ip."
    fi
  fi
elif [[ "$RESOLVE_STATE_ONLY" == "1" && -n "${existing_managed_vmid:-}" ]]; then
  resolved_endpoint=""
  echo
  echo "WireGuard endpoint is not configured yet; deferring endpoint selection until Continue/recover is selected."
else
  echo
  echo "WireGuard public endpoint:"
  if [[ -n "$detected_public_ip" ]]; then
    echo "  1) Use detected public IPv4: $detected_public_ip"
  else
    echo "  1) Use detected public IPv4: <not available>"
  fi
  echo "  2) Enter DNS/DDNS hostname"
  echo "  3) Enter another IPv4 manually"
  read -r -p "Choice [1]: " endpoint_choice
  endpoint_choice="${endpoint_choice:-1}"

  case "$endpoint_choice" in
    1)
      [[ -n "$detected_public_ip" ]] || die "No public IPv4 was detected. Choose option 2 or 3."
      resolved_endpoint="$detected_public_ip"
      ;;
    2)
      resolved_endpoint="$(ask "DNS/DDNS hostname" "${WG_ENDPOINT}")"
      [[ -n "$resolved_endpoint" ]] || die "DNS/DDNS hostname cannot be empty."
      resolved_dns_ip="$(resolve_ipv4 "$resolved_endpoint" || true)"
      if [[ -n "$resolved_dns_ip" ]]; then
        echo "  Resolved IPv4:        $resolved_dns_ip"
        if [[ -n "$detected_public_ip" ]]; then
          echo "  Detected public IPv4: $detected_public_ip"
          if [[ "$resolved_dns_ip" == "$detected_public_ip" ]]; then
            echo "  [OK] DDNS matches current public IPv4."
          else
            echo "  [WARN] DDNS does NOT match the current public IPv4."
          fi
        fi
      else
        echo "  [WARN] Could not resolve an IPv4 for '$resolved_endpoint'."
      fi
      ;;
    3)
      resolved_endpoint="$(ask "Public IPv4" "")"
      is_ipv4 "$resolved_endpoint" || die "Invalid IPv4 address: $resolved_endpoint"
      if ! is_public_ipv4 "$resolved_endpoint"; then
        echo "[WARN] The entered IPv4 is not globally routable: $resolved_endpoint"
      fi
      ;;
    *)
      die "Invalid endpoint choice: $endpoint_choice"
      ;;
  esac
fi

if [[ "$RESOLVE_STATE_ONLY" != "1" || -z "${existing_managed_vmid:-}" ]]; then
  [[ -n "$resolved_endpoint" ]] || die "WireGuard public endpoint cannot be empty."
fi

cat > "${ROOT_DIR}/config/resolved.conf" <<EOF
VMID=${resolved_vmid}
VM_NAME="${MANAGED_VM_NAME}"
MANAGED_TAG="${MANAGED_TAG}"
MANAGED_DESCRIPTION="${MANAGED_DESCRIPTION}"
VM_MEMORY_MB=${VM_MEMORY_MB}
VM_CORES=${VM_CORES}
VM_DISK_GB=${VM_DISK_GB}
VM_STORAGE="${resolved_storage}"
VM_BRIDGE="${resolved_bridge}"
VM_START_ON_BOOT=${VM_START_ON_BOOT}
VM_MACHINE="${VM_MACHINE}"

DEBIAN_IMAGE_URL="${DEBIAN_IMAGE_URL}"
DEBIAN_SHA512_URL="${DEBIAN_SHA512_URL}"
DEBIAN_IMAGE_CACHE="${DEBIAN_IMAGE_CACHE}"

GUEST_USER="${GUEST_USER}"
SSH_PRIVATE_KEY="${SSH_PRIVATE_KEY}"

VM_IP="${resolved_vm_ip}"
VM_PREFIX=${resolved_prefix}
LAN_CIDR="${resolved_lan}"
LAN_GATEWAY="${resolved_gateway}"
PIHOLE_IP="${resolved_dns}"

WG_IF="${WG_IF}"
WG_PORT=${EXISTING_WG_PORT:-${WG_PORT}}
WG_CIDR="${EXISTING_WG_CIDR:-${WG_CIDR}}"
WG_SERVER_IP="${EXISTING_WG_SERVER_IP:-${WG_SERVER_IP}}"
WG_ENDPOINT="${resolved_endpoint}"
WG_DETECTED_PUBLIC_IP="${detected_public_ip}"
WG_CLIENT_DNS="${resolved_dns}"
WG_PERSISTENT_KEEPALIVE=${EXISTING_WG_KEEPALIVE:-${WG_PERSISTENT_KEEPALIVE}}
WG_MTU=${EXISTING_WG_MTU:-${WG_MTU}}

PVE_BACKUP_STORAGE="${resolved_backup}"
REQUIRE_INTERACTIVE_CONFIRMATION="${REQUIRE_INTERACTIVE_CONFIRMATION}"
EOF

chmod 600 "${ROOT_DIR}/config/resolved.conf"
echo
echo "Resolved configuration written to:"
echo "  ${ROOT_DIR}/config/resolved.conf"
