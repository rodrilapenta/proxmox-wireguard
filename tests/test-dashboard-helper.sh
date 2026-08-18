#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
test_root="$(mktemp -d)"
trap 'rm -rf "$test_root"' EXIT

fake_wg="$test_root/wg"
cat >"$fake_wg" <<'EOF'
#!/usr/bin/env bash
printf 'wg0\tSERVER_PRIVATE_SECRET\tserver-public\t51820\toff\n'
printf 'peer-public\tPRESHARED_SECRET\t198.51.100.1:1234\t10.77.77.2/32\t1700000000\t1024\t2048\t25\n'
EOF
chmod 0700 "$fake_wg"

export PWG_TEST_MODE=1
export PWG_WG_BIN="$fake_wg"
output="$(bash "$ROOT_DIR/guest/dashboard-helper.sh" telemetry)"
[[ "$output" == $'peer-public\t1700000000\t1024\t2048' ]] || { echo "Unexpected telemetry: $output" >&2; exit 1; }
[[ "$output" != *SECRET* ]] || { echo "Secret leaked from WireGuard dump." >&2; exit 1; }

mkdir -p "$test_root/peers" "$test_root/exports/phone"
printf 'WG_IF="wg0"\nWG_PORT="51820"\nWG_CIDR="10.77.77.0/24"\nWG_ENDPOINT="vpn.example.net"\nPRIVATE_KEY="CONFIG_SECRET"\n' >"$test_root/deployment.conf"
printf 'PROJECT_VERSION=1.2.0\n' >"$test_root/version"
printf 'timestamp=2026-08-18T12:00:00Z\n' >"$test_root/health"
printf '# peer: phone\nPublicKey = peer-public\nPresharedKey = PEER_SECRET\nAllowedIPs = 10.77.77.2/32\n' >"$test_root/peers/phone.conf"
export PWG_CONFIG_FILE="$test_root/deployment.conf" PWG_VERSION_FILE="$test_root/version" PWG_HEALTH_FILE="$test_root/health" PWG_PEER_DIR="$test_root/peers" PWG_EXPORT_DIR="$test_root/exports"
snapshot="$(bash "$ROOT_DIR/guest/dashboard-helper.sh" snapshot)"
[[ "$snapshot" == *$'PEER\tphone\t10.77.77.2\tpeer-public\t1'* ]] || { echo "Sanitized peer missing." >&2; exit 1; }
[[ "$snapshot" != *SECRET* ]] || { echo "Secret leaked from snapshot." >&2; exit 1; }

if bash "$ROOT_DIR/guest/dashboard-helper.sh" revoke-peer '../invalid' >/dev/null 2>&1; then
  echo "Invalid peer name was accepted." >&2
  exit 1
fi
if bash "$ROOT_DIR/guest/dashboard-helper.sh" telemetry unexpected >/dev/null 2>&1; then
  echo "Unexpected telemetry argument was accepted." >&2
  exit 1
fi

echo "Dashboard helper tests passed."
