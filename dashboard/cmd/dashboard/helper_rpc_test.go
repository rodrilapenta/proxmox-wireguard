package main

import "testing"

func TestPrivilegedHelperProtocolWhitelist(t *testing.T) {
	valid := []helperRequest{{Action: "snapshot"}, {Action: "healthcheck"}, {Action: "add-peer", Peer: "phone"}, {Action: "export-profile", Peer: "phone", Profile: "split-ddns"}}
	for _, request := range valid {
		if _, err := validatedHelperArgs(request); err != nil {
			t.Fatalf("valid request rejected: %+v: %v", request, err)
		}
	}
	invalid := []helperRequest{{Action: "shell"}, {Action: "healthcheck", Peer: "extra"}, {Action: "add-peer", Peer: "../root"}, {Action: "export-profile", Peer: "phone", Profile: "../../key"}, {Action: "revoke-peer", Peer: "phone", Profile: "extra"}}
	for _, request := range invalid {
		if _, err := validatedHelperArgs(request); err == nil {
			t.Fatalf("invalid request accepted: %+v", request)
		}
	}
}
