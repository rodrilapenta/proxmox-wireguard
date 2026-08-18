package main

import (
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"

	"golang.org/x/crypto/bcrypt"
)

func TestAuthenticationAndCSRF(t *testing.T) {
	hash, err := bcrypt.GenerateFromPassword([]byte("correct horse battery staple"), bcrypt.MinCost)
	if err != nil {
		t.Fatal(err)
	}
	h, err := authenticatedHandler(demoData(), hash)
	if err != nil {
		t.Fatal(err)
	}

	w := httptest.NewRecorder()
	h.ServeHTTP(w, httptest.NewRequest(http.MethodGet, "/", nil))
	if w.Code != http.StatusSeeOther || w.Header().Get("Location") != "/login" {
		t.Fatalf("unauthenticated status = %d", w.Code)
	}

	form := url.Values{"password": {"correct horse battery staple"}}
	w = httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodPost, "/login", strings.NewReader(form.Encode()))
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	h.ServeHTTP(w, req)
	if w.Code != http.StatusSeeOther {
		t.Fatalf("login status = %d", w.Code)
	}
	var cookie *http.Cookie
	for _, candidate := range w.Result().Cookies() {
		if candidate.Name == sessionCookie {
			cookie = candidate
		}
	}
	if cookie == nil || !cookie.HttpOnly || !cookie.Secure || cookie.SameSite != http.SameSiteStrictMode {
		t.Fatalf("insecure session cookie: %+v", cookie)
	}

	w = httptest.NewRecorder()
	req = httptest.NewRequest(http.MethodGet, "/", nil)
	req.AddCookie(cookie)
	h.ServeHTTP(w, req)
	if w.Code != http.StatusOK || !strings.Contains(w.Body.String(), "csrf-token") {
		t.Fatalf("authenticated page failed: %d", w.Code)
	}

	w = httptest.NewRecorder()
	req = httptest.NewRequest(http.MethodPost, "/api/actions/healthcheck", nil)
	req.AddCookie(cookie)
	h.ServeHTTP(w, req)
	if w.Code != http.StatusForbidden {
		t.Fatalf("missing CSRF status = %d", w.Code)
	}
}

func TestInvalidPassword(t *testing.T) {
	hash, _ := bcrypt.GenerateFromPassword([]byte("right"), bcrypt.MinCost)
	h, _ := authenticatedHandler(demoData(), hash)
	form := url.Values{"password": {"wrong"}}
	w := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodPost, "/login", strings.NewReader(form.Encode()))
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	h.ServeHTTP(w, req)
	if w.Code != http.StatusUnauthorized {
		t.Fatalf("status = %d", w.Code)
	}
}
