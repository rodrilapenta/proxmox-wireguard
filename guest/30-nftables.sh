#!/usr/bin/env bash
set -Eeuo pipefail
ROOT_DIR="/opt/proxmox-wireguard"
if [[ -f "${ROOT_DIR}/config/resolved.conf" ]]; then
  source "${ROOT_DIR}/config/resolved.conf"
else
  source "${ROOT_DIR}/config/env.conf"
fi
[[ $EUID -eq 0 ]] || { echo "Run as root." >&2; exit 1; }

LAN_IF="$(ip -4 route show default | awk 'NR==1 {for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')"
[[ -n "$LAN_IF" ]] || { echo "Could not detect LAN interface." >&2; exit 1; }

cat >/etc/nftables.conf <<EOF
#!/usr/sbin/nft -f
flush ruleset

table inet filter {
  chain input {
    type filter hook input priority filter; policy drop;

    iifname "lo" accept
    ct state established,related accept
    ct state invalid drop

    # Diagnostics / PMTU.
    ip protocol icmp accept

    # SSH administration: LAN or VPN only.
    ip saddr ${LAN_CIDR} tcp dport 22 accept
    ip saddr ${WG_CIDR} tcp dport 22 accept

    # WireGuard handshake.
    udp dport ${WG_PORT} accept
  }

  chain forward {
    type filter hook forward priority filter; policy drop;

    ct state established,related accept
    ct state invalid drop

    # VPN clients may access the LAN and, for full-tunnel profiles, Internet
    # through the gateway's default route.
    iifname "${WG_IF}" oifname "${LAN_IF}" accept
  }

  chain output {
    type filter hook output priority filter; policy accept;
  }
}

table ip nat {
  chain postrouting {
    type nat hook postrouting priority srcnat; policy accept;
    ip saddr ${WG_CIDR} oifname "${LAN_IF}" masquerade
  }
}
EOF

nft -c -f /etc/nftables.conf
systemctl enable nftables
systemctl restart nftables

echo "nftables loaded. LAN interface detected as: $LAN_IF"
