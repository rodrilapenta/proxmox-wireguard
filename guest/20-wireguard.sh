#!/usr/bin/env bash
set -Eeuo pipefail
umask 077
ROOT_DIR="/opt/proxmox-wireguard"
if [[ -f "${ROOT_DIR}/config/resolved.conf" ]]; then
  source "${ROOT_DIR}/config/resolved.conf"
else
  source "${ROOT_DIR}/config/env.conf"
fi
[[ $EUID -eq 0 ]] || { echo "Run as root." >&2; exit 1; }

install -d -m 0700 /etc/wireguard
install -d -m 0700 /var/lib/proxmox-wireguard/peers
install -d -m 0700 /var/lib/proxmox-wireguard/exports

if [[ ! -s /etc/wireguard/server.key ]]; then
  wg genkey > /etc/wireguard/server.key
  chmod 600 /etc/wireguard/server.key
fi
wg pubkey < /etc/wireguard/server.key > /etc/wireguard/server.pub
chmod 644 /etc/wireguard/server.pub

cat >/usr/local/sbin/wg-home-render <<'EOS'
#!/usr/bin/env bash
set -Eeuo pipefail
umask 077
ROOT_DIR="/opt/proxmox-wireguard"
source "${ROOT_DIR}/config/env.conf"

server_key="$(cat /etc/wireguard/server.key)"
tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT

cat >"$tmp" <<EOF
# Managed by proxmox-wireguard. Do not edit generated peer sections here.
[Interface]
Address = ${WG_SERVER_IP}/24
ListenPort = ${WG_PORT}
PrivateKey = ${server_key}
MTU = ${WG_MTU}
SaveConfig = false

EOF

shopt -s nullglob
for peer in /var/lib/proxmox-wireguard/peers/*.conf; do
  cat "$peer" >>"$tmp"
  printf '\n' >>"$tmp"
done

install -m 0600 "$tmp" "/etc/wireguard/${WG_IF}.conf"

if ip link show "$WG_IF" &>/dev/null; then
  wg syncconf "$WG_IF" <(wg-quick strip "$WG_IF")
fi
EOS
chmod 0750 /usr/local/sbin/wg-home-render

/usr/local/sbin/wg-home-render
systemctl enable "wg-quick@${WG_IF}"
systemctl restart "wg-quick@${WG_IF}"

echo "WireGuard server public key:"
cat /etc/wireguard/server.pub
