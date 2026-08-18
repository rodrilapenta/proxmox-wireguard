package main

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestOverview(t *testing.T) {
	h, err := handler()
	if err != nil {
		t.Fatal(err)
	}
	r := httptest.NewRequest(http.MethodGet, "/", nil)
	w := httptest.NewRecorder()
	h.ServeHTTP(w, r)
	if w.Code != http.StatusOK {
		t.Fatalf("status = %d", w.Code)
	}
	if !strings.Contains(w.Body.String(), "Home Gateway") {
		t.Fatal("overview content missing")
	}
	if w.Header().Get("Content-Security-Policy") == "" {
		t.Fatal("security headers missing")
	}
}

func TestStaticAssets(t *testing.T) {
	h, err := handler()
	if err != nil {
		t.Fatal(err)
	}
	for _, path := range []string{"/static/web/style.css", "/static/web/login.css", "/static/web/modal.css", "/static/web/app.js"} {
		w := httptest.NewRecorder()
		h.ServeHTTP(w, httptest.NewRequest(http.MethodGet, path, nil))
		if w.Code != http.StatusOK {
			t.Fatalf("%s status = %d", path, w.Code)
		}
	}
}

func TestHealth(t *testing.T) {
	h, err := handler()
	if err != nil {
		t.Fatal(err)
	}
	w := httptest.NewRecorder()
	h.ServeHTTP(w, httptest.NewRequest(http.MethodGet, "/healthz", nil))
	if w.Code != http.StatusNoContent {
		t.Fatalf("status = %d", w.Code)
	}
}
