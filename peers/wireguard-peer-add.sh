#!/usr/bin/env bash
set -Eeuo pipefail
umask 077
ROOT_DIR="/opt/proxmox-wireguard"
if [[ -f "${ROOT_DIR}/config/resolved.conf" ]]; then
  source "${ROOT_DIR}/config/resolved.conf"
else
  source "${ROOT_DIR}/config/env.conf"
fi
[[ $EUID -eq 0 ]] || { echo "Run with sudo/root." >&2; exit 1; }

name="${1:-}"
[[ "$name" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,47}$ ]] || {
  echo "Usage: $0 <peer-name>  (letters/numbers/._-)" >&2
  exit 2
}

peer_file="/var/lib/proxmox-wireguard/peers/${name}.conf"
export_dir="/var/lib/proxmox-wireguard/exports/${name}"
[[ ! -e "$peer_file" ]] || { echo "Peer already exists: $name" >&2; exit 1; }

# Find the first free host address from .2 through .254.
used="$(grep -Rhs '^AllowedIPs = ' /var/lib/proxmox-wireguard/peers 2>/dev/null | sed -E 's/.*= ([0-9.]+)\/32/\1/' || true)"
prefix="${WG_SERVER_IP%.*}"
peer_ip=""
for n in $(seq 2 254); do
  candidate="${prefix}.${n}"
  if ! grep -Fxq "$candidate" <<<"$used"; then peer_ip="$candidate"; break; fi
done
[[ -n "$peer_ip" ]] || { echo "No free peer addresses." >&2; exit 1; }

client_priv="$(wg genkey)"
client_pub="$(printf '%s' "$client_priv" | wg pubkey)"
psk="$(wg genpsk)"
server_pub="$(cat /etc/wireguard/server.pub)"

cat >"$peer_file" <<EOF
# peer: ${name}
[Peer]
PublicKey = ${client_pub}
PresharedKey = ${psk}
AllowedIPs = ${peer_ip}/32
EOF
chmod 600 "$peer_file"

install -d -m 0700 "$export_dir"

public_ip="${WG_DETECTED_PUBLIC_IP:-}"

write_profile() {
  local outfile="$1"
  local endpoint="$2"
  local allowed_ips="$3"

  local description
  if [[ "$allowed_ips" == "0.0.0.0/0" ]]; then
    description="All traffic, including Internet, via VPN"
  else
    description="Local/LAN traffic via VPN; Internet direct"
  fi

  cat >"$outfile" <<EOF
# ${description}
[Interface]
PrivateKey = ${client_priv}
Address = ${peer_ip}/32
DNS = ${WG_CLIENT_DNS}
MTU = ${WG_MTU}

[Peer]
PublicKey = ${server_pub}
PresharedKey = ${psk}
Endpoint = ${endpoint}:${WG_PORT}
AllowedIPs = ${allowed_ips}
PersistentKeepalive = ${WG_PERSISTENT_KEEPALIVE}
EOF
  chmod 600 "$outfile"
}

# Primary DDNS/hostname profiles.
write_profile \
  "${export_dir}/${name}-split-ddns.conf" \
  "${WG_ENDPOINT}" \
  "${LAN_CIDR}, ${WG_CIDR}"

write_profile \
  "${export_dir}/${name}-full-ddns.conf" \
  "${WG_ENDPOINT}" \
  "0.0.0.0/0"

# Direct-public-IP fallback profiles when a public IPv4 is known.
if [[ -n "$public_ip" ]]; then
  write_profile \
    "${export_dir}/${name}-split-ip.conf" \
    "${public_ip}" \
    "${LAN_CIDR}, ${WG_CIDR}"

  write_profile \
    "${export_dir}/${name}-full-ip.conf" \
    "${public_ip}" \
    "0.0.0.0/0"
fi

/usr/local/sbin/wg-home-render

echo "Peer created: $name"
echo "VPN IP:       $peer_ip"
echo
echo "Primary profiles (DDNS/hostname):"
echo "  Split: ${export_dir}/${name}-split-ddns.conf"
echo "         Local/LAN traffic via VPN; Internet direct"
echo "  Full:  ${export_dir}/${name}-full-ddns.conf"
echo "         All traffic, including Internet, via VPN"

if [[ -n "$public_ip" ]]; then
  echo
  echo "Fallback profiles (direct public IPv4):"
  echo "  Split: ${export_dir}/${name}-split-ip.conf"
  echo "         Local/LAN traffic via VPN; Internet direct"
  echo "  Full:  ${export_dir}/${name}-full-ip.conf"
  echo "         All traffic, including Internet, via VPN"
fi

echo
if [[ -n "$public_ip" && "$WG_ENDPOINT" != "$public_ip" ]]; then
  resolved_endpoint_ip="$(getent ahostsv4 "$WG_ENDPOINT" 2>/dev/null | awk 'NR==1{print $1}' || true)"
  if [[ -n "$resolved_endpoint_ip" ]]; then
    if [[ "$resolved_endpoint_ip" == "$public_ip" ]]; then
      echo "[OK] DDNS resolves to current public IPv4: $public_ip"
    else
      echo "[WARN] DDNS resolves to $resolved_endpoint_ip but detected public IPv4 is $public_ip"
    fi
  else
    echo "[WARN] Could not resolve DDNS endpoint '$WG_ENDPOINT' right now."
  fi
fi

echo
echo "QR 1/4 - Split / DDNS"
echo "Local/LAN traffic via VPN; Internet direct"
qrencode -t ANSIUTF8 <"${export_dir}/${name}-split-ddns.conf"

echo
echo "QR 2/4 - Full / DDNS"
echo "All traffic, including Internet, via VPN"
qrencode -t ANSIUTF8 <"${export_dir}/${name}-full-ddns.conf"

if [[ -n "$public_ip" ]]; then
  echo
  echo "QR 3/4 - Split / Direct IP"
  echo "Local/LAN traffic via VPN; Internet direct"
  qrencode -t ANSIUTF8 <"${export_dir}/${name}-split-ip.conf"

  echo
  echo "QR 4/4 - Full / Direct IP"
  echo "All traffic, including Internet, via VPN"
  qrencode -t ANSIUTF8 <"${export_dir}/${name}-full-ip.conf"
else
  echo
  echo "[INFO] Direct-IP fallback profiles were not generated because no public IPv4 is currently available."
fi

echo
echo "SECURITY: client private key currently exists in the export files."
echo
read -r -p "Have you imported all desired profiles and want to purge the exports now? [y/N]: " purge_now
case "${purge_now,,}" in
  y|yes)
    sudo /opt/proxmox-wireguard/peers/wireguard-peer-purge-export.sh "$name"
    echo "[OK] Client export files and temporary private-key material purged."
    ;;
  *)
    echo "[INFO] Export files kept temporarily."
    echo "When finished importing profiles, purge them with:"
    echo "  sudo /opt/proxmox-wireguard/peers/wireguard-peer-purge-export.sh '$name'"
    ;;
esac
