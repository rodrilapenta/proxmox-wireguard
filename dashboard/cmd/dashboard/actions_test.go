package main

import "testing"

func TestActionValidationRejectsInjection(t *testing.T) {
	for _, peer := range []string{"../root", "phone;id", "", "name with spaces"} {
		if _, err := runHelperAction("revoke-peer", peer); err == nil {
			t.Fatalf("accepted peer %q", peer)
		}
	}
	if _, err := runHelperAction("shell", "phone"); err == nil {
		t.Fatal("accepted unsupported action")
	}
}

func TestProfileValidationRejectsInjection(t *testing.T) {
	if _, err := runHelperProfile("export-profile", "phone", "../../server.key"); err == nil {
		t.Fatal("accepted invalid profile")
	}
	if _, err := runHelperProfile("export-profile", "phone;id", "split-ddns"); err == nil {
		t.Fatal("accepted invalid peer")
	}
}
