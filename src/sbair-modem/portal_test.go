// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Floop3

package main

import (
	"errors"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"
)

func setupPortalTest(t *testing.T) {
	t.Helper()
	oldIP, oldMAC, oldSet, oldMACs, oldListen, oldToken := portalBrlanIPFn, portalMACFromIPFn, portalAdblockSetFn, portalAdblockMACsFn, portalListenFn, portalTokenFn
	t.Cleanup(func() {
		portalBrlanIPFn, portalMACFromIPFn, portalAdblockSetFn, portalAdblockMACsFn, portalListenFn, portalTokenFn = oldIP, oldMAC, oldSet, oldMACs, oldListen, oldToken
	})
	portalBrlanIPFn = func() string { return "198.51.100.1" }
	portalMACFromIPFn = func(string) string { return "aa:bb:cc:dd:ee:ff" }
	portalAdblockSetFn = func(mac, enabled string) map[string]any {
		return map[string]any{"result": "ok", "mac": mac, "enabled": enabled}
	}
	portalAdblockMACsFn = func() map[string]bool { return map[string]bool{} }
	portalTokenFn = func() (string, error) { return "fixed-csrf-token", nil }
}

func portalGet(t *testing.T) (*httptest.ResponseRecorder, *http.Cookie) {
	t.Helper()
	req := httptest.NewRequest(http.MethodGet, "http://198.51.100.20/", nil)
	req.RemoteAddr = "198.51.100.20:12345"
	rr := httptest.NewRecorder()
	portalHandler(rr, req)
	if rr.Code != http.StatusOK {
		t.Fatalf("GET / status = %d, want 200", rr.Code)
	}
	res := rr.Result()
	if len(res.Cookies()) != 1 {
		t.Fatalf("GET / cookies = %d, want one", len(res.Cookies()))
	}
	cookie := res.Cookies()[0]
	if cookie.Name != portalCSRFCookie || !cookie.HttpOnly || cookie.SameSite != http.SameSiteStrictMode || cookie.Path != "/" || cookie.Secure {
		t.Fatalf("unexpected CSRF cookie: %#v", cookie)
	}
	if !strings.Contains(rr.Body.String(), `name="csrf_token" value="fixed-csrf-token"`) {
		t.Fatal("GET / did not render the CSRF token in the form")
	}
	return rr, cookie
}

func TestPortalGetSetsCSRFAndValidPostMutates(t *testing.T) {
	setupPortalTest(t)
	_, cookie := portalGet(t)
	called := false
	portalAdblockSetFn = func(mac, enabled string) map[string]any {
		called = true
		if mac != "aa:bb:cc:dd:ee:ff" || enabled != "1" {
			t.Fatalf("adblockSet args = %q, %q", mac, enabled)
		}
		return map[string]any{"result": "ok"}
	}
	form := url.Values{"enabled": {"1"}, "csrf_token": {cookie.Value}}
	req := httptest.NewRequest(http.MethodPost, "http://198.51.100.20/toggle", strings.NewReader(form.Encode()))
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	req.RemoteAddr = "198.51.100.20:12345"
	req.AddCookie(cookie)
	rr := httptest.NewRecorder()
	portalHandler(rr, req)
	if rr.Code != http.StatusOK || !called {
		t.Fatalf("valid POST status=%d called=%v", rr.Code, called)
	}
}

func TestPortalRejectsCSRFAndBadEnabledBeforeMutation(t *testing.T) {
	setupPortalTest(t)
	_, cookie := portalGet(t)
	called := false
	portalAdblockSetFn = func(string, string) map[string]any {
		called = true
		return map[string]any{"result": "ok"}
	}

	tests := []struct {
		name       string
		cookie     *http.Cookie
		form       url.Values
		wantStatus int
	}{
		{"no cookie", nil, url.Values{"enabled": {"1"}, "csrf_token": {cookie.Value}}, http.StatusForbidden},
		{"cookie only", cookie, url.Values{"enabled": {"1"}}, http.StatusForbidden},
		{"form only", nil, url.Values{"enabled": {"1"}, "csrf_token": {cookie.Value}}, http.StatusForbidden},
		{"mismatch", cookie, url.Values{"enabled": {"1"}, "csrf_token": {"wrong"}}, http.StatusForbidden},
		{"invalid enabled", cookie, url.Values{"enabled": {"2"}, "csrf_token": {cookie.Value}}, http.StatusBadRequest},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			if tc.name == "form only" {
				// The table intentionally has no cookie; keep the case distinct from
				// the no-cookie case by documenting that only the form is supplied.
			}
			req := httptest.NewRequest(http.MethodPost, "http://198.51.100.20/toggle", strings.NewReader(tc.form.Encode()))
			req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
			req.RemoteAddr = "198.51.100.20:12345"
			if tc.cookie != nil {
				req.AddCookie(tc.cookie)
			}
			rr := httptest.NewRecorder()
			portalHandler(rr, req)
			if rr.Code != tc.wantStatus {
				t.Fatalf("status = %d, want %d; body=%s", rr.Code, tc.wantStatus, rr.Body.String())
			}
		})
	}
	if called {
		t.Fatal("adblockSet was called for an invalid portal request")
	}
}

func TestPortalRejectsMalformedFormAndWrongRouteMethods(t *testing.T) {
	setupPortalTest(t)
	_, cookie := portalGet(t)
	called := false
	portalAdblockSetFn = func(string, string) map[string]any {
		called = true
		return map[string]any{"result": "ok"}
	}

	malformed := httptest.NewRequest(http.MethodPost, "http://198.51.100.20/toggle", strings.NewReader("%zz"))
	malformed.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	malformed.RemoteAddr = "198.51.100.20:12345"
	malformed.AddCookie(cookie)
	rr := httptest.NewRecorder()
	portalHandler(rr, malformed)
	if rr.Code != http.StatusBadRequest || called {
		t.Fatalf("malformed form status=%d called=%v", rr.Code, called)
	}

	for _, tc := range []struct {
		method string
		path   string
		code   int
	}{
		{http.MethodPost, "/", http.StatusMethodNotAllowed},
		{http.MethodGet, "/toggle", http.StatusMethodNotAllowed},
		{http.MethodGet, "/unknown", http.StatusNotFound},
	} {
		req := httptest.NewRequest(tc.method, "http://198.51.100.20"+tc.path, nil)
		rr := httptest.NewRecorder()
		portalHandler(rr, req)
		if rr.Code != tc.code {
			t.Errorf("%s %s status=%d, want %d", tc.method, tc.path, rr.Code, tc.code)
		}
	}
}

func TestRunPortalBindsToBrLanIPv4AndFailsClosed(t *testing.T) {
	setupPortalTest(t)
	var addr string
	portalListenFn = func(got string, _ http.Handler) error {
		addr = got
		return errors.New("stop test listener")
	}
	if got := runPortal(); got != 1 {
		t.Fatalf("runPortal() = %d, want 1 after listener error", got)
	}
	if addr != "198.51.100.1:8090" {
		t.Fatalf("listener address = %q", addr)
	}

	called := false
	portalBrlanIPFn = func() string { return "" }
	portalListenFn = func(string, http.Handler) error {
		called = true
		return nil
	}
	if got := runPortal(); got != 1 || called {
		t.Fatalf("runPortal without br-lan IP = %d, listener called=%v", got, called)
	}
}
