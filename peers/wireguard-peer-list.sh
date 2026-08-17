#!/usr/bin/env bash
set -Eeuo pipefail
[[ $EUID -eq 0 ]] || { echo "Run with sudo/root." >&2; exit 1; }

printf '%-24s %-16s %-44s\n' "NAME" "VPN IP" "PUBLIC KEY"
printf '%-24s %-16s %-44s\n' "------------------------" "---------------" "--------------------------------------------"

shopt -s nullglob
for f in /var/lib/proxmox-wireguard/peers/*.conf; do
  name="$(sed -n 's/^# peer: //p' "$f" | head -1)"
  ip="$(sed -n 's/^AllowedIPs = \([0-9.]*\)\/32/\1/p' "$f" | head -1)"
  pub="$(sed -n 's/^PublicKey = //p' "$f" | head -1)"
  printf '%-24s %-16s %-44s\n' "$name" "$ip" "$pub"
done
