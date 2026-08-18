package main

import (
	"fmt"
	"regexp"
	"strings"
)

var peerName = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._-]{0,47}$`)
var profileName = regexp.MustCompile(`^(split-ddns|full-ddns|split-ip|full-ip)$`)
var serverID = regexp.MustCompile(`^[0-9]{1,10}$`)

func validMetadata(values ...string) bool {
	limits := []int{80, 80, 80, 240}
	if len(values) != len(limits) {
		return false
	}
	for index, value := range values {
		if len(value) > limits[index] || strings.ContainsAny(value, "\r\n\t") {
			return false
		}
	}
	return true
}

func runHelperAction(action, peer string) (string, error) {
	request := helperRequest{Action: action}
	switch action {
	case "healthcheck", "speedtest-servers", "dns-check", "path-test", "diagnostic-report", "schema", "peer-metadata-list":
		request.Action = action
	case "speedtest":
		if peer != "" && !serverID.MatchString(peer) {
			return "", fmt.Errorf("invalid speedtest server ID")
		}
		request.Peer = peer
	case "add-peer", "purge-export", "revoke-peer":
		if !peerName.MatchString(peer) {
			return "", fmt.Errorf("invalid peer name")
		}
		request.Peer = peer
	default:
		return "", fmt.Errorf("unsupported action")
	}
	out, e := callHelper(request)
	if e != nil {
		return "", fmt.Errorf("%s", e)
	}
	return strings.TrimSpace(string(out)), nil
}

func runHelperMetadata(peer, label, device, owner, notes string) (string, error) {
	if !peerName.MatchString(peer) || !validMetadata(label, device, owner, notes) {
		return "", fmt.Errorf("invalid peer information")
	}
	out, err := callHelper(helperRequest{Action: "update-peer-metadata", Peer: peer, Label: label, Device: device, Owner: owner, Notes: notes})
	if err != nil {
		return "", fmt.Errorf("%s", err)
	}
	return strings.TrimSpace(string(out)), nil
}

func runHelperProfile(action, peer, profile string) ([]byte, error) {
	if action != "export-profile" && action != "qr-profile" {
		return nil, fmt.Errorf("unsupported profile action")
	}
	if !peerName.MatchString(peer) || !profileName.MatchString(profile) {
		return nil, fmt.Errorf("invalid peer or profile")
	}
	out, err := callHelper(helperRequest{Action: action, Peer: peer, Profile: profile})
	if err != nil {
		return nil, fmt.Errorf("profile is unavailable")
	}
	return out, nil
}
