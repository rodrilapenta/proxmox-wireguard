package main

import (
	"bufio"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

type systemPaths struct {
	configFile, versionFile, healthFile, peerDir, exportDir string
}

func (p systemPaths) defaults() systemPaths {
	if p.configFile == "" {
		p.configFile = "/etc/proxmox-wireguard/deployment.conf"
	}
	if p.versionFile == "" {
		p.versionFile = "/etc/proxmox-wireguard/version"
	}
	if p.healthFile == "" {
		p.healthFile = "/var/lib/proxmox-wireguard/healthcheck.ok"
	}
	if p.peerDir == "" {
		p.peerDir = "/var/lib/proxmox-wireguard/peers"
	}
	if p.exportDir == "" {
		p.exportDir = "/var/lib/proxmox-wireguard/exports"
	}
	return p
}

func systemData(paths systemPaths) (pageData, error) {
	if paths == (systemPaths{}) {
		return systemDataFromHelper()
	}
	paths = paths.defaults()
	cfg, err := readAssignments(paths.configFile, map[string]bool{"WG_IF": true, "WG_PORT": true, "WG_CIDR": true, "WG_SERVER_IP": true, "WG_ENDPOINT": true, "VM_IP": true, "WG_CLIENT_DNS": true, "DASHBOARD_PORT": true})
	if err != nil {
		return pageData{}, err
	}
	version, _ := readAssignments(paths.versionFile, map[string]bool{"PROJECT_VERSION": true})
	data := pageData{Title: "Overview", Mode: "System data", Version: version["PROJECT_VERSION"], Interface: cfg["WG_IF"], VPNNetwork: cfg["WG_CIDR"], Endpoint: cfg["WG_ENDPOINT"] + ":" + cfg["WG_PORT"]}
	data.ServerAddress, data.LANAddress, data.ClientDNS, data.DashboardPort = cfg["WG_SERVER_IP"], cfg["VM_IP"], cfg["WG_CLIENT_DNS"], cfg["DASHBOARD_PORT"]
	data.WireGuardPort = cfg["WG_PORT"]
	if data.Version == "" {
		data.Version = "1.0.0"
	}
	if health, err := readAssignments(paths.healthFile, map[string]bool{"timestamp": true}); err == nil {
		data.Healthy = true
		data.LastCheck = health["timestamp"]
	} else {
		data.LastCheck = "No successful healthcheck"
	}
	data.Peers, err = readPeers(paths)
	if err != nil && !os.IsNotExist(err) {
		return data, err
	}
	if output, err := runTelemetry(); err == nil {
		applyWireGuardTelemetry(data.Peers, output)
	}
	summarize(&data)
	return data, nil
}

func systemDataFromHelper() (pageData, error) {
	output, err := runHelper("snapshot")
	if err != nil {
		return pageData{}, err
	}
	data := pageData{Title: "Overview", Mode: "System data", LastCheck: "No successful healthcheck"}
	cfg := map[string]string{}
	for _, line := range strings.Split(strings.TrimSpace(string(output)), "\n") {
		fields := strings.Split(line, "\t")
		if len(fields) < 2 {
			continue
		}
		switch fields[0] {
		case "CONFIG":
			if len(fields) == 3 {
				cfg[fields[1]] = fields[2]
			}
		case "VERSION":
			data.Version = fields[1]
		case "HEALTH":
			if len(fields) >= 3 && fields[2] != "" {
				data.Healthy = fields[1] == "passed"
				data.LastCheck = fields[2]
			}
		case "PEER":
			if len(fields) == 5 {
				status := "Configured"
				if fields[4] == "1" {
					status = "Export pending"
				}
				data.Peers = append(data.Peers, peer{Name: fields[1], Address: fields[2], PublicKey: fields[3], LastHandshake: "Never", Received: "0 B", Sent: "0 B", Status: status, ExportPending: fields[4] == "1"})
			}
		}
	}
	data.Interface = cfg["WG_IF"]
	data.VPNNetwork = cfg["WG_CIDR"]
	data.Endpoint = cfg["WG_ENDPOINT"] + ":" + cfg["WG_PORT"]
	data.ServerAddress, data.LANAddress, data.ClientDNS, data.DashboardPort = cfg["WG_SERVER_IP"], cfg["VM_IP"], cfg["WG_CLIENT_DNS"], cfg["DASHBOARD_PORT"]
	data.WireGuardPort = cfg["WG_PORT"]
	if data.Version == "" {
		data.Version = "1.0.0"
	}
	if telemetry, e := runHelper("telemetry"); e == nil {
		applyWireGuardTelemetry(data.Peers, telemetry)
	}
	summarize(&data)
	return data, nil
}

func readAssignments(path string, allowed map[string]bool) (map[string]string, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	values := map[string]string{}
	scanner := bufio.NewScanner(f)
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		key, value, ok := strings.Cut(line, "=")
		if !ok || !allowed[key] {
			continue
		}
		values[key] = strings.Trim(strings.TrimSpace(value), "\"")
	}
	return values, scanner.Err()
}

func readPeers(paths systemPaths) ([]peer, error) {
	entries, err := os.ReadDir(paths.peerDir)
	if err != nil {
		return nil, err
	}
	peers := []peer{}
	for _, entry := range entries {
		if entry.IsDir() || filepath.Ext(entry.Name()) != ".conf" {
			continue
		}
		values, err := readPeer(filepath.Join(paths.peerDir, entry.Name()))
		if err != nil {
			return nil, err
		}
		name := values["name"]
		if name == "" {
			name = strings.TrimSuffix(entry.Name(), ".conf")
		}
		status := "Configured"
		if _, err := os.Stat(filepath.Join(paths.exportDir, name)); err == nil {
			status = "Export pending"
		}
		peers = append(peers, peer{Name: name, Address: values["address"], LastHandshake: "Never", Received: "0 B", Sent: "0 B", Status: status, PublicKey: values["public_key"], ExportPending: status == "Export pending"})
	}
	return peers, nil
}

func readPeer(path string) (map[string]string, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	values := map[string]string{}
	s := bufio.NewScanner(f)
	for s.Scan() {
		line := strings.TrimSpace(s.Text())
		if strings.HasPrefix(line, "# peer: ") {
			values["name"] = strings.TrimSpace(strings.TrimPrefix(line, "# peer: "))
		}
		if strings.HasPrefix(line, "PublicKey = ") {
			values["public_key"] = strings.TrimSpace(strings.TrimPrefix(line, "PublicKey = "))
		}
		if strings.HasPrefix(line, "AllowedIPs = ") {
			values["address"] = strings.TrimSuffix(strings.TrimSpace(strings.TrimPrefix(line, "AllowedIPs = ")), "/32")
		}
	}
	return values, s.Err()
}

func runTelemetry() ([]byte, error) {
	return runHelper("telemetry")
}

func runHelper(action string) ([]byte, error) {
	return callHelper(helperRequest{Action: action})
}

func applyWireGuardTelemetry(peers []peer, output []byte) {
	byKey := map[string]*peer{}
	for i := range peers {
		byKey[peers[i].PublicKey] = &peers[i]
	}
	lines := strings.Split(strings.TrimSpace(string(output)), "\n")
	for _, line := range lines {
		fields := strings.Split(line, "\t")
		if len(fields) != 4 {
			continue
		}
		item := byKey[fields[0]]
		if item == nil {
			continue
		}
		handshake, _ := strconv.ParseInt(fields[1], 10, 64)
		if handshake > 0 {
			handshakeTime := time.Unix(handshake, 0)
			item.LastHandshake = relativeTime(handshakeTime)
			age := time.Since(handshakeTime)
			if age >= 0 && age <= 3*time.Minute {
				item.Status = "Connected"
			} else {
				item.Status = "Idle"
			}
		} else {
			item.Status = "Never connected"
		}
		received, _ := strconv.ParseInt(fields[2], 10, 64)
		sent, _ := strconv.ParseInt(fields[3], 10, 64)
		item.Received = formatBytes(received)
		item.Sent = formatBytes(sent)
		item.RawReceived = received
		item.RawSent = sent
	}
}

func relativeTime(t time.Time) string {
	d := time.Since(t)
	if d < time.Minute {
		return "just now"
	}
	if d < time.Hour {
		return fmt.Sprintf("%d minutes ago", int(d.Minutes()))
	}
	if d < 24*time.Hour {
		return fmt.Sprintf("%d hours ago", int(d.Hours()))
	}
	return fmt.Sprintf("%d days ago", int(d.Hours()/24))
}
func formatBytes(n int64) string {
	const unit = 1024
	if n < unit {
		return fmt.Sprintf("%d B", n)
	}
	div, exp := int64(unit), 0
	for v := n / unit; v >= unit; v /= unit {
		div *= unit
		exp++
	}
	return fmt.Sprintf("%.1f %ciB", float64(n)/float64(div), "KMGTPE"[exp])
}

func summarize(data *pageData) {
	if data.DashboardPort == "" {
		data.DashboardPort = "8443"
	}
	data.AvailableVersion = buildVersion
	data.UpdateAvailable = data.Version != data.AvailableVersion
	data.PeerCount = len(data.Peers)
	var received, sent int64
	for _, item := range data.Peers {
		if item.Status == "Connected" {
			data.ConnectedCount++
		}
		if item.ExportPending {
			data.ExportPendingCount++
		}
		received += item.RawReceived
		sent += item.RawSent
	}
	data.TotalReceived = formatBytes(received)
	data.TotalSent = formatBytes(sent)
}
