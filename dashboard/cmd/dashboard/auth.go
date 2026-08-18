package main

import (
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"golang.org/x/crypto/bcrypt"
	"html/template"
	"net"
	"net/http"
	"strings"
	"sync"
	"time"
)

const sessionCookie = "pwg_session"

type session struct {
	csrf    string
	expires time.Time
}
type authStore struct {
	password []byte
	mu       sync.Mutex
	sessions map[string]session
	attempts map[string]loginAttempt
}
type loginAttempt struct {
	failures     int
	blockedUntil time.Time
}

func newAuthStore(p []byte) *authStore {
	return &authStore{password: []byte(strings.TrimSpace(string(p))), sessions: map[string]session{}, attempts: map[string]loginAttempt{}}
}
func clientIP(r *http.Request) string {
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err == nil {
		return host
	}
	return r.RemoteAddr
}
func (a *authStore) loginAllowed(ip string) bool {
	a.mu.Lock()
	defer a.mu.Unlock()
	return time.Now().After(a.attempts[ip].blockedUntil)
}
func (a *authStore) loginFailed(ip string) {
	a.mu.Lock()
	defer a.mu.Unlock()
	item := a.attempts[ip]
	item.failures++
	if item.failures >= 5 {
		item.blockedUntil = time.Now().Add(5 * time.Minute)
		item.failures = 0
	}
	a.attempts[ip] = item
}
func (a *authStore) loginSucceeded(ip string) { a.mu.Lock(); delete(a.attempts, ip); a.mu.Unlock() }
func randomToken() (string, error) {
	b := make([]byte, 32)
	if _, e := rand.Read(b); e != nil {
		return "", e
	}
	return base64.RawURLEncoding.EncodeToString(b), nil
}
func (a *authStore) create() (string, error) {
	t, e := randomToken()
	if e != nil {
		return "", e
	}
	c, e := randomToken()
	if e != nil {
		return "", e
	}
	a.mu.Lock()
	a.sessions[t] = session{c, time.Now().Add(30 * time.Minute)}
	a.mu.Unlock()
	return t, nil
}
func (a *authStore) get(r *http.Request) (session, bool) {
	c, e := r.Cookie(sessionCookie)
	if e != nil {
		return session{}, false
	}
	a.mu.Lock()
	defer a.mu.Unlock()
	s, ok := a.sessions[c.Value]
	if !ok || time.Now().After(s.expires) {
		delete(a.sessions, c.Value)
		return session{}, false
	}
	s.expires = time.Now().Add(30 * time.Minute)
	a.sessions[c.Value] = s
	return s, true
}
func (a *authStore) remove(r *http.Request) {
	if c, e := r.Cookie(sessionCookie); e == nil {
		a.mu.Lock()
		delete(a.sessions, c.Value)
		a.mu.Unlock()
	}
}
func authenticatedHandler(data pageData, hash []byte) (http.Handler, error) {
	index, e := template.ParseFS(webFS, "web/index.html")
	if e != nil {
		return nil, e
	}
	login, e := template.ParseFS(webFS, "web/login.html")
	if e != nil {
		return nil, e
	}
	auth := newAuthStore(hash)
	mux := http.NewServeMux()
	mux.Handle("GET /static/", http.StripPrefix("/static/", http.FileServer(http.FS(webFS))))
	mux.HandleFunc("GET /login", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Cache-Control", "no-store")
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		_ = login.Execute(w, nil)
	})
	mux.HandleFunc("POST /login", func(w http.ResponseWriter, r *http.Request) {
		ip := clientIP(r)
		if !auth.loginAllowed(ip) {
			http.Error(w, "Too many attempts. Try again later.", http.StatusTooManyRequests)
			return
		}
		r.Body = http.MaxBytesReader(w, r.Body, 4096)
		_ = r.ParseForm()
		if bcrypt.CompareHashAndPassword(auth.password, []byte(r.FormValue("password"))) != nil {
			auth.loginFailed(ip)
			time.Sleep(250 * time.Millisecond)
			http.Error(w, "Invalid credentials", 401)
			return
		}
		auth.loginSucceeded(ip)
		token, e := auth.create()
		if e != nil {
			http.Error(w, "Unable to create session", 500)
			return
		}
		http.SetCookie(w, &http.Cookie{Name: sessionCookie, Value: token, Path: "/", HttpOnly: true, Secure: true, SameSite: http.SameSiteStrictMode, MaxAge: 1800})
		http.Redirect(w, r, "/", 303)
	})
	protected := http.NewServeMux()
	protected.HandleFunc("GET /", func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/" {
			http.NotFound(w, r)
			return
		}
		s, _ := auth.get(r)
		page := data
		if refreshed, err := systemData(systemPaths{}); err == nil {
			page = refreshed
		}
		page.CSRFToken = s.csrf
		w.Header().Set("Cache-Control", "no-store")
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		_ = index.Execute(w, page)
	})
	protected.HandleFunc("GET /healthz", func(w http.ResponseWriter, _ *http.Request) { w.WriteHeader(204) })
	protected.HandleFunc("POST /logout", func(w http.ResponseWriter, r *http.Request) {
		s, _ := auth.get(r)
		if !validCSRF(r, s) {
			http.Error(w, "Invalid CSRF token", 403)
			return
		}
		auth.remove(r)
		w.WriteHeader(204)
	})
	protected.HandleFunc("POST /api/actions/{action}", func(w http.ResponseWriter, r *http.Request) {
		s, _ := auth.get(r)
		if !validCSRF(r, s) {
			http.Error(w, "Invalid CSRF token", 403)
			return
		}
		r.Body = http.MaxBytesReader(w, r.Body, 4096)
		_ = r.ParseForm()
		actionName := r.PathValue("action")
		var out string
		var e error
		if actionName == "update-peer-metadata" {
			out, e = runHelperMetadata(r.FormValue("peer"), r.FormValue("label"), r.FormValue("device"), r.FormValue("owner"), r.FormValue("notes"))
		} else {
			out, e = runHelperAction(actionName, r.FormValue("peer"))
		}
		w.Header().Set("Content-Type", "application/json")
		if e != nil {
			auditEvent(r, r.PathValue("action"), r.FormValue("peer"), "failed")
			w.WriteHeader(400)
			_ = json.NewEncoder(w).Encode(map[string]string{"error": e.Error()})
			return
		}
		auditEvent(r, r.PathValue("action"), r.FormValue("peer"), "success")
		_ = json.NewEncoder(w).Encode(map[string]string{"status": "ok", "output": out})
	})
	protected.HandleFunc("POST /api/profiles/{peer}/{profile}/{format}", func(w http.ResponseWriter, r *http.Request) {
		s, _ := auth.get(r)
		if !validCSRF(r, s) {
			http.Error(w, "Invalid CSRF token", 403)
			return
		}
		format := r.PathValue("format")
		action := "export-profile"
		contentType := "text/plain; charset=utf-8"
		extension := ".conf"
		if format == "qr" {
			action = "qr-profile"
			contentType = "image/png"
			extension = ".png"
		} else if format != "config" {
			http.NotFound(w, r)
			return
		}
		out, err := runHelperProfile(action, r.PathValue("peer"), r.PathValue("profile"))
		if err != nil {
			auditEvent(r, action, r.PathValue("peer"), "failed")
			http.Error(w, err.Error(), 404)
			return
		}
		auditEvent(r, action, r.PathValue("peer"), "success")
		w.Header().Set("Content-Type", contentType)
		w.Header().Set("Cache-Control", "no-store")
		w.Header().Set("Content-Disposition", "attachment; filename=\""+r.PathValue("peer")+"-"+r.PathValue("profile")+extension+"\"")
		_, _ = w.Write(out)
	})
	mux.Handle("/", http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if _, ok := auth.get(r); !ok {
			http.Redirect(w, r, "/login", 303)
			return
		}
		protected.ServeHTTP(w, r)
	}))
	return securityHeaders(mux), nil
}
func validCSRF(r *http.Request, s session) bool {
	return s.csrf != "" && r.Header.Get("X-CSRF-Token") == s.csrf
}
