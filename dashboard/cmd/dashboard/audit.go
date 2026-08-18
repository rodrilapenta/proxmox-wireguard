package main

import (
	"fmt"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"time"
)

func auditEvent(r *http.Request, action, target, outcome string) {
	path := os.Getenv("PWG_AUDIT_FILE")
	if path == "" {
		path = "/var/lib/proxmox-wireguard-dashboard/audit.log"
	}
	if !peerName.MatchString(target) {
		target = "-"
	}
	for _, value := range []*string{&action, &outcome} {
		*value = strings.Map(func(r rune) rune {
			if r == '\n' || r == '\r' || r == '\t' {
				return ' '
			}
			return r
		}, *value)
	}
	_ = os.MkdirAll(filepath.Dir(path), 0o700)
	f, err := os.OpenFile(path, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o600)
	if err != nil {
		return
	}
	defer f.Close()
	_, _ = fmt.Fprintf(f, "%s\tip=%s\taction=%s\ttarget=%s\toutcome=%s\n", time.Now().UTC().Format(time.RFC3339), clientIP(r), action, target, outcome)
}
