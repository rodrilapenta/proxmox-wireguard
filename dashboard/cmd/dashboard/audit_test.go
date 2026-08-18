package main

import (
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestAuditLogContainsNoUntrustedLines(t *testing.T) {
	path := filepath.Join(t.TempDir(), "audit.log")
	t.Setenv("PWG_AUDIT_FILE", path)
	request := httptest.NewRequest("POST", "https://gateway/api/actions/revoke-peer", nil)
	request.RemoteAddr = "10.77.77.2:1234"
	auditEvent(request, "revoke-peer\nforged", "phone", "success\nforged")
	content, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if strings.Count(strings.TrimSpace(string(content)), "\n") != 0 {
		t.Fatalf("audit injection created extra lines: %q", content)
	}
	if strings.Contains(string(content), "\nforged") {
		t.Fatal("audit value was not sanitized")
	}
}
