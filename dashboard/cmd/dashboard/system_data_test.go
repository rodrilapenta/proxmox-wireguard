package main

import (
	"fmt"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestSystemDataReadsOnlyRequiredPeerFields(t *testing.T) {
	root := t.TempDir()
	peers := filepath.Join(root, "peers")
	exports := filepath.Join(root, "exports")
	if err := os.MkdirAll(filepath.Join(exports, "phone"), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(peers, 0o700); err != nil {
		t.Fatal(err)
	}
	write := func(path, body string) {
		if err := os.WriteFile(path, []byte(body), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	config := filepath.Join(root, "deployment.conf")
	version := filepath.Join(root, "version")
	health := filepath.Join(root, "healthcheck.ok")
	write(config, "WG_IF=wg0\nWG_PORT=51820\nWG_CIDR=10.77.77.0/24\nWG_ENDPOINT=vpn.example.net\n")
	write(version, "PROJECT_VERSION=1.2.0\n")
	write(health, "timestamp=2026-08-18T12:00:00Z\n")
	write(filepath.Join(peers, "phone.conf"), "# peer: phone\n[Peer]\nPublicKey = public-value\nPresharedKey = must-never-be-returned\nAllowedIPs = 10.77.77.2/32\n")

	data, err := systemData(systemPaths{configFile: config, versionFile: version, healthFile: health, peerDir: peers, exportDir: exports})
	if err != nil {
		t.Fatal(err)
	}
	if data.Version != "1.2.0" || data.Endpoint != "vpn.example.net:51820" {
		t.Fatalf("unexpected data: %+v", data)
	}
	if len(data.Peers) != 1 || data.Peers[0].Name != "phone" || data.Peers[0].Address != "10.77.77.2" {
		t.Fatalf("unexpected peers: %+v", data.Peers)
	}
	if data.Peers[0].PublicKey != "public-value" || data.Peers[0].Status != "Export pending" {
		t.Fatalf("unexpected peer metadata: %+v", data.Peers[0])
	}
}

func TestReadAssignmentsIgnoresSecrets(t *testing.T) {
	path := filepath.Join(t.TempDir(), "deployment.conf")
	if err := os.WriteFile(path, []byte("WG_IF=wg0\nPRIVATE_KEY=secret\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	values, err := readAssignments(path, map[string]bool{"WG_IF": true})
	if err != nil {
		t.Fatal(err)
	}
	if values["WG_IF"] != "wg0" {
		t.Fatal("allowed value missing")
	}
	if _, exists := values["PRIVATE_KEY"]; exists {
		t.Fatal("secret value was parsed")
	}
}

func TestTelemetryUsesSanitizedColumns(t *testing.T) {
	peers := []peer{{Name: "phone", PublicKey: "peer-public", Status: "Configured"}}
	applyWireGuardTelemetry(peers, []byte(fmt.Sprintf("peer-public\t%d\t1024\t2048\n", time.Now().Add(-time.Minute).Unix())))
	if peers[0].Received != "1.0 KiB" || peers[0].Sent != "2.0 KiB" {
		t.Fatalf("unexpected transfer: %+v", peers[0])
	}
	if peers[0].Status != "Connected" {
		t.Fatalf("unexpected status: %+v", peers[0])
	}
}

func TestTelemetryMarksStaleHandshakeIdle(t *testing.T) {
	peers := []peer{{Name: "phone", PublicKey: "peer-public", Status: "Configured"}}
	applyWireGuardTelemetry(peers, []byte(fmt.Sprintf("peer-public\t%d\t0\t0\n", time.Now().Add(-10*time.Minute).Unix())))
	if peers[0].Status != "Idle" {
		t.Fatalf("stale peer status = %q", peers[0].Status)
	}
}
