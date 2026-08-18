package main

import (
	"embed"
	"flag"
	"fmt"
	"html/template"
	"io"
	"log"
	"net/http"
	"os"
	"strings"
	"time"

	"golang.org/x/crypto/bcrypt"
)

//go:embed web/*
var webFS embed.FS
var buildVersion = "1.2.0"

type check struct{ Name, Status string }
type peer struct {
	Name, Address, LastHandshake, Received, Sent, Status, PublicKey string
	ExportPending                                                   bool
	RawReceived, RawSent                                            int64
}
type pageData struct {
	Title, Mode, Version, Interface, Endpoint, VPNNetwork, LastCheck, CSRFToken string
	ServerAddress, LANAddress, ClientDNS, DashboardPort                         string
	WireGuardPort                                                               string
	AvailableVersion                                                            string
	TotalReceived, TotalSent                                                    string
	PeerCount, ConnectedCount, ExportPendingCount                               int
	Healthy                                                                     bool
	Demo                                                                        bool
	UpdateAvailable                                                             bool
	Checks                                                                      []check
	Peers                                                                       []peer
}

func demoData() pageData {
	return pageData{
		Title: "Overview", Mode: "Local preview", Version: "1.1.0", AvailableVersion: buildVersion, TotalReceived: "2.8 GB", TotalSent: "824 MB", PeerCount: 3, ConnectedCount: 2, ExportPendingCount: 2,
		Interface: "wg0", Endpoint: "vpn.example.net:51820", VPNNetwork: "10.77.77.0/24", ServerAddress: "10.77.77.1", LANAddress: "192.0.2.11", ClientDNS: "192.0.2.10", DashboardPort: "8443", WireGuardPort: "51820",
		LastCheck: time.Now().Add(-2 * time.Minute).Format("02 Jan 2006, 15:04"), Healthy: true, Demo: true, UpdateAvailable: true,
		Checks: []check{{"WireGuard", "Healthy"}, {"Firewall", "Healthy"}, {"DNS", "Healthy"}, {"Internet", "Healthy"}},
		Peers: []peer{
			{Name: "phone", Address: "10.77.77.2", LastHandshake: "42 seconds ago", Received: "184 MB", Sent: "76 MB", Status: "Connected", ExportPending: true},
			{Name: "laptop", Address: "10.77.77.3", LastHandshake: "18 minutes ago", Received: "1.4 GB", Sent: "392 MB", Status: "Idle", ExportPending: true},
			{Name: "tablet", Address: "10.77.77.4", LastHandshake: "Never", Received: "0 B", Sent: "0 B", Status: "Never connected"},
		},
	}
}

func handler() (http.Handler, error) {
	return handlerWithData(demoData())
}

func handlerWithData(data pageData) (http.Handler, error) {
	t, err := template.ParseFS(webFS, "web/index.html")
	if err != nil {
		return nil, err
	}
	mux := http.NewServeMux()
	mux.Handle("GET /static/", http.StripPrefix("/static/", http.FileServer(http.FS(webFS))))
	mux.HandleFunc("GET /", func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/" {
			http.NotFound(w, r)
			return
		}
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		if err := t.Execute(w, data); err != nil {
			http.Error(w, "Unable to render dashboard", http.StatusInternalServerError)
		}
	})
	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, _ *http.Request) { w.WriteHeader(http.StatusNoContent) })
	return securityHeaders(mux), nil
}

func securityHeaders(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Security-Policy", "default-src 'self'; style-src 'self'; img-src 'self' blob: data:; frame-ancestors 'none'; form-action 'self'; base-uri 'none'")
		w.Header().Set("Referrer-Policy", "no-referrer")
		w.Header().Set("X-Content-Type-Options", "nosniff")
		w.Header().Set("Permissions-Policy", "camera=(), microphone=(), geolocation=()")
		next.ServeHTTP(w, r)
	})
}

func main() {
	listen := flag.String("listen", "127.0.0.1:8080", "HTTP listen address")
	mode := flag.String("mode", "auto", "data mode: auto, demo, or system")
	tlsCert := flag.String("tls-cert", "", "TLS certificate path")
	tlsKey := flag.String("tls-key", "", "TLS private-key path")
	passwordFile := flag.String("password-file", "/etc/proxmox-wireguard/dashboard-password", "bcrypt password file")
	hashPassword := flag.Bool("hash-password", false, "read a password from stdin and print its bcrypt hash")
	helperServer := flag.Bool("helper-server", false, "run the privileged Unix-socket helper")
	helperSocket := flag.String("helper-socket", "/run/proxmox-wireguard-dashboard/helper.sock", "privileged helper Unix socket")
	flag.Parse()
	if *helperServer {
		if err := serveHelper(*helperSocket); err != nil {
			log.Fatal(err)
		}
		return
	}
	if *hashPassword {
		password, err := io.ReadAll(io.LimitReader(os.Stdin, 1025))
		if err != nil {
			log.Fatal(err)
		}
		password = []byte(strings.TrimSpace(string(password)))
		if len(password) < 16 || len(password) > 1024 {
			log.Fatal("password must contain 16 to 1024 characters")
		}
		hash, err := bcrypt.GenerateFromPassword(password, bcrypt.DefaultCost)
		if err != nil {
			log.Fatal(err)
		}
		fmt.Println(string(hash))
		return
	}
	data := demoData()
	useSystem := *mode == "system" || (*mode == "auto" && fileExists("/etc/proxmox-wireguard/deployment.conf"))
	if useSystem {
		var err error
		data, err = systemData(systemPaths{})
		if err != nil {
			log.Printf("system data unavailable, using degraded view: %v", err)
			data.Mode = "Degraded system view"
		}
	} else if *mode != "auto" && *mode != "demo" {
		log.Fatalf("invalid mode %q", *mode)
	}
	var h http.Handler
	var err error
	if useSystem {
		hash, readErr := os.ReadFile(*passwordFile)
		if readErr != nil {
			log.Fatalf("read dashboard password: %v", readErr)
		}
		h, err = authenticatedHandler(data, hash)
	} else {
		h, err = handlerWithData(data)
	}
	if err != nil {
		log.Fatal(err)
	}
	server := &http.Server{Addr: *listen, Handler: h, ReadHeaderTimeout: 5 * time.Second, ReadTimeout: 15 * time.Second, WriteTimeout: 150 * time.Second, IdleTimeout: 60 * time.Second, MaxHeaderBytes: 16 << 10}
	if useSystem {
		if *tlsCert == "" || *tlsKey == "" {
			log.Fatal("system mode requires --tls-cert and --tls-key")
		}
		log.Printf("Proxmox WireGuard dashboard: https://%s", *listen)
		log.Fatal(server.ListenAndServeTLS(*tlsCert, *tlsKey))
	}
	log.Printf("Proxmox WireGuard dashboard preview: http://%s", *listen)
	log.Fatal(server.ListenAndServe())
}

func fileExists(path string) bool {
	_, err := os.Stat(path)
	return err == nil
}
