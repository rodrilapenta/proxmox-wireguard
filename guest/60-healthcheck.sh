#!/usr/bin/env bash
set -u
ROOT_DIR="/opt/proxmox-wireguard"
if [[ -f "${ROOT_DIR}/config/resolved.conf" ]]; then
  source "${ROOT_DIR}/config/resolved.conf"
else
  source "${ROOT_DIR}/config/env.conf"
fi

STATE_DIR="/var/lib/proxmox-wireguard"
HEALTH_OK_FILE="${STATE_DIR}/healthcheck.ok"
HEALTH_REPORT_FILE="${STATE_DIR}/healthcheck.last"
HEALTH_STATUS_FILE="${STATE_DIR}/healthcheck.status"
mkdir -p "$STATE_DIR"
rm -f "$HEALTH_OK_FILE"

fail=0
report_tmp="$(mktemp)"
trap 'rm -f "$report_tmp"' EXIT

ok(){ printf '[OK]   %s\n' "$*" | tee -a "$report_tmp"; }
bad(){ printf '[FAIL] %s\n' "$*" | tee -a "$report_tmp"; fail=1; }
warn(){ printf '[WARN] %s\n' "$*" | tee -a "$report_tmp"; }

systemctl is-active --quiet "wg-quick@${WG_IF}" && ok "WireGuard service active" || bad "WireGuard service inactive"
ip link show "$WG_IF" &>/dev/null && ok "$WG_IF exists" || bad "$WG_IF missing"
if wg show "$WG_IF" 2>/dev/null | awk '/listening port:/ {print $3}' | grep -Fxq "$WG_PORT"; then
  ok "WireGuard reports UDP ${WG_PORT} listening"
elif ss -H -lunp 2>/dev/null | grep -Eq '(^|[[:space:]])[^[:space:]]*:'"${WG_PORT}"'([[:space:]]|$)'; then
  ok "UDP ${WG_PORT} listening"
else
  bad "UDP ${WG_PORT} not listening"
fi
[[ "$(sysctl -n net.ipv4.ip_forward 2>/dev/null)" == "1" ]] && ok "IPv4 forwarding enabled" || bad "IPv4 forwarding disabled"
systemctl is-active --quiet nftables && ok "nftables active" || bad "nftables inactive"
nft list ruleset &>/dev/null && ok "nftables ruleset readable" || bad "nftables ruleset unavailable"
ping -c 1 -W 2 "$LAN_GATEWAY" &>/dev/null && ok "LAN gateway reachable ($LAN_GATEWAY)" || bad "LAN gateway unreachable"
ping -c 1 -W 2 "$PIHOLE_IP" &>/dev/null && ok "Pi-hole reachable ($PIHOLE_IP)" || warn "Pi-hole unreachable"
getent ahostsv4 deb.debian.org &>/dev/null && ok "DNS resolution works" || warn "DNS resolution failed"
ping -c 1 -W 2 1.1.1.1 &>/dev/null && ok "Internet IPv4 reachable" || warn "Internet IPv4 ping failed"
systemctl is-enabled --quiet "wg-quick@${WG_IF}" && ok "WireGuard enabled at boot" || bad "WireGuard not enabled at boot"
systemctl is-enabled --quiet nftables && ok "nftables enabled at boot" || bad "nftables not enabled at boot"
systemctl is-active --quiet qemu-guest-agent && ok "QEMU guest agent active" || warn "QEMU guest agent inactive"

if [[ -f "${ROOT_DIR}/VERSION" ]]; then
  source "${ROOT_DIR}/VERSION"
  if [[ "$(printf '%s\n' "1.2.0" "$PROJECT_VERSION" | sort -V | head -1)" == "1.2.0" ]]; then
    systemctl is-active --quiet proxmox-wireguard-dashboard && ok "Dashboard service active" || bad "Dashboard service inactive"
    systemctl is-active --quiet proxmox-wireguard-dashboard-helper && ok "Dashboard helper service active" || bad "Dashboard helper service inactive"
    ss -H -ltn 2>/dev/null | grep -Eq '(^|[[:space:]])[^[:space:]]*:'"${DASHBOARD_PORT:-8443}"'([[:space:]]|$)' && ok "Dashboard HTTPS port ${DASHBOARD_PORT:-8443} listening" || bad "Dashboard HTTPS port ${DASHBOARD_PORT:-8443} not listening"
  fi
fi

echo
wg_output="$(wg show "$WG_IF" 2>/dev/null || true)"
printf '%s\n' "$wg_output"
{
  echo
  printf '%s\n' "$wg_output"
} >>"$report_tmp"

install -m 0600 "$report_tmp" "$HEALTH_REPORT_FILE"

timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
if (( fail == 0 )); then
  {
    printf 'timestamp=%s\n' "$timestamp"
    printf 'wg_if=%s\n' "$WG_IF"
    printf 'wg_port=%s\n' "$WG_PORT"
  } >"$HEALTH_OK_FILE"
  chmod 0600 "$HEALTH_OK_FILE"
fi

{
  if (( fail == 0 )); then printf 'status=passed\n'; else printf 'status=failed\n'; fi
  printf 'timestamp=%s\n' "$timestamp"
} >"$HEALTH_STATUS_FILE"
chmod 0600 "$HEALTH_STATUS_FILE"

exit "$fail"
