#!/usr/bin/env bash
set -Eeuo pipefail
ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
mkdir -p "${ROOT_DIR}/dist/linux-amd64"
cd "$ROOT_DIR"
PROJECT_VERSION="$(awk -F= '$1 == "PROJECT_VERSION" {print $2}' ../VERSION)"
CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -trimpath -ldflags "-s -w -X main.buildVersion=${PROJECT_VERSION}" -o dist/linux-amd64/proxmox-wireguard-dashboard ./cmd/dashboard
echo "${ROOT_DIR}/dist/linux-amd64/proxmox-wireguard-dashboard"
