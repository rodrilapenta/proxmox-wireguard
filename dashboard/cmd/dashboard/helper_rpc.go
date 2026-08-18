package main

import (
	"encoding/json"
	"fmt"
	"io"
	"net"
	"os"
	"os/exec"
	"strings"
	"sync"
	"time"
)

type helperRequest struct{ Action, Peer, Profile, Label, Device, Owner, Notes string }
type helperResponse struct {
	Data  []byte
	Error string
}

var helperExecution sync.Mutex

func callHelper(r helperRequest) ([]byte, error) {
	socket := os.Getenv("PWG_HELPER_SOCKET")
	if socket == "" {
		socket = "/run/proxmox-wireguard-dashboard/helper.sock"
	}
	c, e := net.DialTimeout("unix", socket, 3*time.Second)
	if e != nil {
		return nil, e
	}
	defer c.Close()
	_ = c.SetDeadline(time.Now().Add(130 * time.Second))
	if e = json.NewEncoder(c).Encode(r); e != nil {
		return nil, e
	}
	var response helperResponse
	if e = json.NewDecoder(c).Decode(&response); e != nil {
		return nil, e
	}
	if response.Error != "" {
		return nil, fmt.Errorf("%s", response.Error)
	}
	return response.Data, nil
}
func serveHelper(socket string) error {
	_ = os.Remove(socket)
	listener, e := net.Listen("unix", socket)
	if e != nil {
		return e
	}
	defer listener.Close()
	if e = os.Chmod(socket, 0o660); e != nil {
		return e
	}
	for {
		connection, e := listener.Accept()
		if e != nil {
			return e
		}
		go handleHelperConnection(connection)
	}
}
func handleHelperConnection(c net.Conn) {
	defer c.Close()
	_ = c.SetDeadline(time.Now().Add(130 * time.Second))
	var r helperRequest
	if e := json.NewDecoder(io.LimitReader(c, 8192)).Decode(&r); e != nil {
		_ = json.NewEncoder(c).Encode(helperResponse{Error: "invalid request"})
		return
	}
	args, e := validatedHelperArgs(r)
	if e != nil {
		_ = json.NewEncoder(c).Encode(helperResponse{Error: e.Error()})
		return
	}
	helperExecution.Lock()
	output, runErr := exec.Command("/usr/local/libexec/proxmox-wireguard-dashboard-helper", args...).CombinedOutput()
	helperExecution.Unlock()
	response := helperResponse{Data: output}
	if runErr != nil {
		response.Data = nil
		detail := strings.TrimSpace(string(output))
		if detail == "" {
			detail = runErr.Error()
		}
		response.Error = "operation failed: " + detail
	}
	_ = json.NewEncoder(c).Encode(response)
}
func validatedHelperArgs(r helperRequest) ([]string, error) {
	switch r.Action {
	case "snapshot", "telemetry", "healthcheck", "speedtest-servers", "dns-check", "path-test", "diagnostic-report", "schema", "peer-metadata-list":
		if r.Peer != "" || r.Profile != "" {
			return nil, fmt.Errorf("unexpected arguments")
		}
		return []string{r.Action}, nil
	case "speedtest":
		if r.Profile != "" || (r.Peer != "" && !serverID.MatchString(r.Peer)) {
			return nil, fmt.Errorf("invalid speedtest server ID")
		}
		if r.Peer == "" {
			return []string{r.Action}, nil
		}
		return []string{r.Action, r.Peer}, nil
	case "add-peer", "purge-export", "revoke-peer":
		if !peerName.MatchString(r.Peer) || r.Profile != "" {
			return nil, fmt.Errorf("invalid peer")
		}
		return []string{r.Action, r.Peer}, nil
	case "update-peer-metadata":
		if !peerName.MatchString(r.Peer) || r.Profile != "" || !validMetadata(r.Label, r.Device, r.Owner, r.Notes) {
			return nil, fmt.Errorf("invalid peer information")
		}
		return []string{r.Action, r.Peer, r.Label, r.Device, r.Owner, r.Notes}, nil
	case "export-profile", "qr-profile":
		if !peerName.MatchString(r.Peer) || !profileName.MatchString(r.Profile) {
			return nil, fmt.Errorf("invalid peer or profile")
		}
		return []string{r.Action, r.Peer, r.Profile}, nil
	default:
		return nil, fmt.Errorf("unsupported action")
	}
}
