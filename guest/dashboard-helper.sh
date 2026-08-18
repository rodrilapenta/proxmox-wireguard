#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

ROOT_DIR="${PWG_ROOT_DIR:-/opt/proxmox-wireguard}"
WG_BIN="${PWG_WG_BIN:-/usr/bin/wg}"
[[ $EUID -eq 0 || "${PWG_TEST_MODE:-0}" == "1" ]] || { echo "Run as root." >&2; exit 1; }

valid_peer() {
  [[ "${1:-}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,47}$ ]]
}
valid_profile() { [[ "${1:-}" =~ ^(split-ddns|full-ddns|split-ip|full-ip)$ ]]; }

action="${1:-}"
case "$action" in
  snapshot)
    [[ $# -eq 1 ]] || { echo "snapshot takes no arguments" >&2; exit 2; }
    config="${PWG_CONFIG_FILE:-/etc/proxmox-wireguard/deployment.conf}"
    version="${PWG_VERSION_FILE:-/etc/proxmox-wireguard/version}"
    health="${PWG_HEALTH_FILE:-/var/lib/proxmox-wireguard/healthcheck.ok}"
    health_status="${PWG_HEALTH_STATUS_FILE:-/var/lib/proxmox-wireguard/healthcheck.status}"
    peer_dir="${PWG_PEER_DIR:-/var/lib/proxmox-wireguard/peers}"
    export_dir="${PWG_EXPORT_DIR:-/var/lib/proxmox-wireguard/exports}"
    wg_interface="$(awk -F= '$1 == "WG_IF" {gsub(/^"|"$/, "", $2); print $2; exit}' "$config")"
    for key in WG_IF WG_PORT WG_CIDR WG_SERVER_IP WG_ENDPOINT VM_IP WG_CLIENT_DNS DASHBOARD_PORT; do
      value="$(awk -F= -v wanted="$key" '$1 == wanted {gsub(/^"|"$/, "", $2); print $2; exit}' "$config" 2>/dev/null || true)"
      printf 'CONFIG\t%s\t%s\n' "$key" "$value"
    done
    printf 'VERSION\t%s\n' "$(awk -F= '$1 == "PROJECT_VERSION" {print $2; exit}' "$version" 2>/dev/null || echo 1.0.0)"
    check_status="$(awk -F= '$1 == "status" {print $2; exit}' "$health_status" 2>/dev/null || true)"
    check_timestamp="$(awk -F= '$1 == "timestamp" {print $2; exit}' "$health_status" 2>/dev/null || true)"
    if [[ -z "$check_status" && -s "$health" ]]; then
      check_status="passed"
      check_timestamp="$(awk -F= '$1 == "timestamp" {print $2; exit}' "$health" 2>/dev/null || true)"
    fi
    printf 'HEALTH\t%s\t%s\n' "${check_status:-unknown}" "$check_timestamp"
    declare -A emitted_keys=()
    shopt -s nullglob
    for file in "$peer_dir"/*.conf; do
      name="$(sed -n 's/^# peer: //p' "$file" | head -1)"
      [[ -n "$name" ]] || name="$(basename "$file" .conf)"
      valid_peer "$name" || continue
      address="$(sed -n 's/^AllowedIPs = \([0-9.]*\)\/32/\1/p' "$file" | head -1)"
      public_key="$(sed -n 's/^PublicKey = //p' "$file" | head -1)"
      export_pending=0; [[ -d "$export_dir/$name" ]] && export_pending=1
      printf 'PEER\t%s\t%s\t%s\t%s\n' "$name" "$address" "$public_key" "$export_pending"
      [[ -n "$public_key" ]] && emitted_keys["$public_key"]=1
    done
    while IFS=$'\t' read -r public_key _ endpoint allowed_ips _ _ _ _; do
      [[ -n "$public_key" && -z "${emitted_keys[$public_key]:-}" ]] || continue
      address="${allowed_ips%%,*}"; address="${address%/32}"
      suffix="${address##*.}"
      [[ "$suffix" =~ ^[0-9]+$ ]] || suffix="$(printf '%s' "$public_key" | sha256sum | cut -c1-8)"
      printf 'PEER\tpeer-%s\t%s\t%s\t0\n' "$suffix" "$address" "$public_key"
    done < <("$WG_BIN" show "$wg_interface" dump 2>/dev/null | tail -n +2)
    ;;
  telemetry)
    [[ $# -eq 1 ]] || { echo "telemetry takes no arguments" >&2; exit 2; }
    # Deliberately removes the interface private key and peer preshared-key
    # columns from `wg show all dump`. Output: public key, handshake, rx, tx.
    config="${PWG_CONFIG_FILE:-/etc/proxmox-wireguard/deployment.conf}"
    wg_interface="$(awk -F= '$1 == "WG_IF" {gsub(/^"|"$/, "", $2); print $2; exit}' "$config")"
    "$WG_BIN" show "$wg_interface" dump | tail -n +2 | awk -F '\t' 'NF >= 8 {print $1 "\t" $5 "\t" $6 "\t" $7}'
    ;;
  healthcheck)
    [[ $# -eq 1 ]] || { echo "healthcheck takes no arguments" >&2; exit 2; }
    exec "${ROOT_DIR}/guest/60-healthcheck.sh"
    ;;
  schema)
    [[ $# -eq 1 ]] || { echo "schema takes no arguments" >&2; exit 2; }
    awk -F= '$1 == "STATE_SCHEMA_VERSION" {print $2; exit}' /etc/proxmox-wireguard/version
    ;;
  speedtest-servers)
    [[ $# -eq 1 ]] || { echo "speedtest-servers takes no arguments" >&2; exit 2; }
    command -v speedtest-cli >/dev/null || { echo "speedtest-cli is not installed" >&2; exit 1; }
    servers="$(timeout 30 speedtest-cli --list)"
    printf '%s\n' "$servers" | sed -n '1,10p'
    ;;
  speedtest)
    [[ $# -le 2 ]] || { echo "speedtest takes an optional numeric server ID" >&2; exit 2; }
    selected_server="${2:-}"
    [[ -z "$selected_server" || "$selected_server" =~ ^[0-9]{1,10}$ ]] || { echo "invalid speedtest server ID" >&2; exit 2; }
    command -v speedtest-cli >/dev/null || { echo "speedtest-cli is not installed" >&2; exit 1; }
    command -v jq >/dev/null || { echo "jq is not installed" >&2; exit 1; }
    speed_args=(--json --secure)
    [[ -n "$selected_server" ]] && speed_args+=(--server "$selected_server")
    result="$(timeout 120 speedtest-cli "${speed_args[@]}")"
    timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    server="$(jq -r '[.server.sponsor, .server.name, .server.country] | map(select(. != null and . != "")) | join(" — ")' <<<"$result")"
    latency="$(jq -r '.ping' <<<"$result")"
    download="$(jq -r '(.download / 1000000 * 100 | round) / 100' <<<"$result")"
    upload="$(jq -r '(.upload / 1000000 * 100 | round) / 100' <<<"$result")"
    history="/var/lib/proxmox-wireguard/speedtest-history.tsv"
    printf '%s\t%s\t%s\t%s\t%s\n' "$timestamp" "$latency" "$download" "$upload" "${server//$'\t'/ }" >>"$history"
    tail -n 20 "$history" >"${history}.tmp" && mv "${history}.tmp" "$history"
    printf 'Provider: speedtest-cli (community client; results are indicative)\nServer: %s\nLatency: %s ms\nDownload: %s Mbit/s\nUpload: %s Mbit/s\n\nRecent tests:\n' "$server" "$latency" "$download" "$upload"
    tail -n 5 "$history" | tac | awk -F '\t' '{printf "%s\nLatency: %s ms · Download: %s Mbit/s · Upload: %s Mbit/s\nServer: %s\n\n", $1, $2, $3, $4, $5}'
    ;;
  dns-check)
    [[ $# -eq 1 ]] || { echo "dns-check takes no arguments" >&2; exit 2; }
    endpoint="$(awk -F= '$1 == "WG_ENDPOINT" {gsub(/^"|"$/, "", $2); print $2; exit}' /etc/proxmox-wireguard/deployment.conf)"
    resolved="$(getent ahostsv4 "$endpoint" | awk 'NR==1 {print $1}')"
    [[ -n "$resolved" ]] || { echo "DNS resolution failed for configured endpoint" >&2; exit 1; }
    public="$(awk -F= '$1 == "WG_DETECTED_PUBLIC_IP" {gsub(/^"|"$/, "", $2); print $2; exit}' /etc/proxmox-wireguard/deployment.conf)"
    status="Unavailable"
    if [[ -n "$public" ]]; then
      if [[ "$resolved" == "$public" ]]; then status="Match"; else status="Mismatch"; fi
    fi
    printf 'Endpoint: %s\nResolved IPv4: %s\nRecorded public IPv4: %s\nStatus: %s\nResolver check: successful\n' "$endpoint" "$resolved" "${public:-Unavailable}" "$status"
    ;;
  path-test)
    [[ $# -eq 1 ]] || { echo "path-test takes no arguments" >&2; exit 2; }
    gateway="$(awk -F= '$1 == "LAN_GATEWAY" {gsub(/^"|"$/, "", $2); print $2; exit}' /etc/proxmox-wireguard/deployment.conf)"
    printf 'LAN gateway: %s\n' "$gateway"
    ping -c 4 -W 2 "$gateway" | tail -2
    printf '\nInternet path: 1.1.1.1\n'
    ping -c 4 -W 2 1.1.1.1 | tail -2
    configured_mtu="$(awk -F= '$1 == "WG_MTU" {gsub(/^"|"$/, "", $2); print $2; exit}' /etc/proxmox-wireguard/deployment.conf)"
    printf '\nConfigured WireGuard MTU: %s\n' "${configured_mtu:-Unknown}"
    printf 'Path MTU discovery: IPv4 probes with fragmentation disabled\n'
    passing_payload=""
    for payload in 1472 1464 1452 1440 1420 1400 1380 1372 1360 1320 1280; do
      if ping -c 1 -W 2 -M do -s "$payload" 1.1.1.1 >/dev/null 2>&1; then
        passing_payload="$payload"
        break
      fi
    done
    if [[ -n "$passing_payload" ]]; then
      printf 'Largest passing probe: %s-byte payload / %s-byte IPv4 packet\n' "$passing_payload" "$((passing_payload + 28))"
      printf 'MTU status: passed\n'
    else
      printf 'MTU status: failed; no tested packet size passed\n'
      exit 1
    fi
    ;;
  diagnostic-report)
    [[ $# -eq 1 ]] || { echo "diagnostic-report takes no arguments" >&2; exit 2; }
    "${ROOT_DIR}/guest/60-healthcheck.sh" >/dev/null || true
    sed -E '/(PrivateKey|PresharedKey|^peer:)/d' /var/lib/proxmox-wireguard/healthcheck.last
    ;;
  peer-metadata-list)
    [[ $# -eq 1 ]] || { echo "peer-metadata-list takes no arguments" >&2; exit 2; }
    metadata_dir="/var/lib/proxmox-wireguard/peer-metadata"
    shopt -s nullglob
    for file in "$metadata_dir"/*.meta; do
      peer="$(basename "$file" .meta)"
      valid_peer "$peer" || continue
      label="$(sed -n '1p' "$file")"; device="$(sed -n '2p' "$file")"; owner="$(sed -n '3p' "$file")"; notes="$(sed -n '4p' "$file")"; created="$(sed -n '5p' "$file")"
      printf 'META\t%s\t%s\t%s\t%s\t%s\t%s\n' "$peer" "$(printf '%s' "$label" | base64 -w0)" "$(printf '%s' "$device" | base64 -w0)" "$(printf '%s' "$owner" | base64 -w0)" "$(printf '%s' "$notes" | base64 -w0)" "$created"
    done
    ;;
  update-peer-metadata)
    [[ $# -eq 6 ]] && valid_peer "$2" || { echo "invalid peer metadata request" >&2; exit 2; }
    for value in "$3" "$4" "$5" "$6"; do
      [[ "$value" != *$'\n'* && "$value" != *$'\r'* && "$value" != *$'\t'* ]] || { echo "metadata contains unsupported control characters" >&2; exit 2; }
    done
    metadata_dir="/var/lib/proxmox-wireguard/peer-metadata"
    install -d -m 0700 "$metadata_dir"
    metadata_file="$metadata_dir/$2.meta"
    created="$(sed -n '5p' "$metadata_file" 2>/dev/null || true)"
    [[ -n "$created" ]] || created="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf '%s\n%s\n%s\n%s\n%s\n' "$3" "$4" "$5" "$6" "$created" >"$metadata_file"
    chmod 0600 "$metadata_file"
    printf 'Peer information updated.\n'
    ;;
  add-peer)
    [[ $# -eq 2 ]] && valid_peer "$2" || { echo "invalid peer name" >&2; exit 2; }
    exec "${ROOT_DIR}/peers/wireguard-peer-add.sh" --non-interactive "$2"
    ;;
  purge-export)
    [[ $# -eq 2 ]] && valid_peer "$2" || { echo "invalid peer name" >&2; exit 2; }
    exec "${ROOT_DIR}/peers/wireguard-peer-purge-export.sh" "$2"
    ;;
  revoke-peer)
    [[ $# -eq 2 ]] && valid_peer "$2" || { echo "invalid peer name" >&2; exit 2; }
    exec "${ROOT_DIR}/peers/wireguard-peer-revoke.sh" "$2"
    ;;
  export-profile)
    [[ $# -eq 3 ]] && valid_peer "$2" && valid_profile "$3" || { echo "invalid peer or profile" >&2; exit 2; }
    exec "${ROOT_DIR}/peers/wireguard-peer-export.sh" "$2" "$3"
    ;;
  qr-profile)
    [[ $# -eq 3 ]] && valid_peer "$2" && valid_profile "$3" || { echo "invalid peer or profile" >&2; exit 2; }
    profile_file="/var/lib/proxmox-wireguard/exports/$2/$2-$3.conf"
    [[ -f "$profile_file" ]] || { echo "profile export is not available" >&2; exit 1; }
    exec qrencode -t PNG -o - <"$profile_file"
    ;;
  *)
    echo "Allowed actions: snapshot | telemetry | healthcheck | schema | speedtest-servers | speedtest [server-id] | dns-check | path-test | diagnostic-report | peer-metadata-list | update-peer-metadata <peer> <label> <device> <owner> <notes> | add-peer <peer> | purge-export <peer> | revoke-peer <peer> | export-profile <peer> <profile> | qr-profile <peer> <profile>" >&2
    exit 2
    ;;
esac
