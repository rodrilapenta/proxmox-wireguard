$ErrorActionPreference = 'Stop'
$dashboardRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$outputDir = Join-Path $dashboardRoot 'dist\linux-amd64'
$versionLine = Get-Content (Join-Path $dashboardRoot '..\VERSION') | Where-Object { $_ -like 'PROJECT_VERSION=*' } | Select-Object -First 1
$projectVersion = $versionLine.Split('=', 2)[1]
New-Item -ItemType Directory -Force -Path $outputDir | Out-Null
$oldGOOS = $env:GOOS; $oldGOARCH = $env:GOARCH; $oldCGO = $env:CGO_ENABLED
try {
  $env:GOOS = 'linux'
  $env:GOARCH = 'amd64'
  $env:CGO_ENABLED = '0'
  go build -trimpath -ldflags "-s -w -X main.buildVersion=$projectVersion" -o (Join-Path $outputDir 'proxmox-wireguard-dashboard') ./cmd/dashboard
} finally {
  $env:GOOS = $oldGOOS; $env:GOARCH = $oldGOARCH; $env:CGO_ENABLED = $oldCGO
}
Write-Output (Join-Path $outputDir 'proxmox-wireguard-dashboard')
