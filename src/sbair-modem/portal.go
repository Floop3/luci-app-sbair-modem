// SPDX-License-Identifier: MIT
// Copyright (c) 2026 syado

package main

import (
	"crypto/rand"
	"crypto/subtle"
	"encoding/base64"
	"fmt"
	"log"
	"net"
	"net/http"
	"os/exec"
	"strings"
)

// 広告ブロックの自己登録ページ。認証は無い(自分の端末しか操作できない設計のため
// 不要と判断した)。LuCIとは独立した専用ポートで公開する。
//
// 仕組み: アクセスしてきたHTTP接続の送信元IP(r.RemoteAddr)を、clients.goと同じ
// `ip neigh` でMACに変換する。表示・操作の対象は「今アクセスしてきた本人の端末」
// だけに限定されるので、他人の端末を勝手に操作されることはない。

const (
	portalPort       = "8090"
	portalCSRFCookie = "sbair_portal_csrf"
)

var (
	portalBrlanIPFn     = brlanIP
	portalMACFromIPFn   = macFromIP
	portalAdblockSetFn  = adblockSet
	portalAdblockMACsFn = adblockMacs
	portalListenFn      = func(addr string, handler http.Handler) error { return http.ListenAndServe(addr, handler) }
	portalTokenFn       = generatePortalToken
)

func generatePortalToken() (string, error) {
	buf := make([]byte, 32)
	if _, err := rand.Read(buf); err != nil {
		return "", err
	}
	return base64.RawURLEncoding.EncodeToString(buf), nil
}

// macFromIP は clients.go の clientList と同じ ip neigh を使って、
// 指定IPに対応するMACアドレスを引く。見つからなければ空文字。
func macFromIP(ip string) string {
	out, err := exec.Command("ip", "neigh", "show", "dev", "br-lan").Output()
	if err != nil {
		return ""
	}
	for _, line := range strings.Split(string(out), "\n") {
		f := strings.Fields(line)
		if len(f) < 1 || f[0] != ip {
			continue
		}
		for i, tok := range f {
			if tok == "lladdr" && i+1 < len(f) {
				return strings.ToLower(f[i+1])
			}
		}
	}
	return ""
}

func portalRequesterMAC(r *http.Request) (mac, ip string) {
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		host = r.RemoteAddr
	}
	return portalMACFromIPFn(host), host
}

func portalPage(mac, ip string, enabled bool, message, csrfToken string) string {
	status := "無効"
	statusColor := "#888"
	toggleLabel := "広告ブロックを有効にする"
	nextVal := "1"
	if enabled {
		status = "有効"
		statusColor = "#5cb85c"
		toggleLabel = "広告ブロックを無効にする"
		nextVal = "0"
	}

	body := fmt.Sprintf(`<h2>この端末の広告ブロック設定</h2>`)
	if mac == "" {
		body += fmt.Sprintf(`<p style="color:#c00">この端末(IP: %s)のMACアドレスを特定できませんでした。
			少し待ってからページを再読み込みしてください。</p>`, ip)
	} else {
		body += fmt.Sprintf(`<p>あなたの端末: <code>%s</code></p>`, mac)
		body += fmt.Sprintf(`<p>現在の状態: <b style="color:%s">%s</b></p>`, statusColor, status)
		body += fmt.Sprintf(`<form method="post" action="/toggle">
			<input type="hidden" name="enabled" value="%s">
			<input type="hidden" name="csrf_token" value="%s">
			<button type="submit" style="font-size:1.1em;padding:.6em 1.2em;">%s</button>
		</form>`, nextVal, csrfToken, toggleLabel)
		body += `<p style="opacity:.7;margin-top:1em">DNS over HTTPS/TLSを使うアプリ・ブラウザには効きません。</p>`
	}
	if message != "" {
		body += fmt.Sprintf(`<p style="color:#5cb85c">%s</p>`, message)
	}

	return fmt.Sprintf(`<!doctype html><html><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>広告ブロック設定</title>
<style>body{font-family:sans-serif;max-width:32em;margin:2em auto;padding:0 1em}
code{background:#eee;padding:.1em .4em;border-radius:.2em}</style>
</head><body>%s</body></html>`, body)
}

func portalHandler(w http.ResponseWriter, r *http.Request) {
	if r.URL.Path != "/" && r.URL.Path != "/toggle" {
		http.NotFound(w, r)
		return
	}
	if (r.URL.Path == "/" && r.Method != http.MethodGet) ||
		(r.URL.Path == "/toggle" && r.Method != http.MethodPost) {
		w.Header().Set("Allow", map[bool]string{true: http.MethodGet, false: http.MethodPost}[r.URL.Path == "/"])
		http.Error(w, http.StatusText(http.StatusMethodNotAllowed), http.StatusMethodNotAllowed)
		return
	}

	mac, ip := portalRequesterMAC(r)
	message := ""

	if r.Method == http.MethodGet {
		cookie, err := r.Cookie(portalCSRFCookie)
		if err != nil || cookie.Value == "" {
			token, err := portalTokenFn()
			if err != nil {
				http.Error(w, "CSRFトークンを生成できません", http.StatusInternalServerError)
				return
			}
			cookie = &http.Cookie{
				Name:     portalCSRFCookie,
				Value:    token,
				Path:     "/",
				HttpOnly: true,
				SameSite: http.SameSiteStrictMode,
				Secure:   false,
			}
			http.SetCookie(w, cookie)
		}
		csrfToken := cookie.Value
		enabled := mac != "" && portalAdblockMACsFn()[mac]
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		_, _ = fmt.Fprint(w, portalPage(mac, ip, enabled, "", csrfToken))
		return
	}

	csrfCookie, err := r.Cookie(portalCSRFCookie)
	if err != nil || csrfCookie.Value == "" {
		http.Error(w, "CSRFトークンがありません", http.StatusForbidden)
		return
	}
	if err := r.ParseForm(); err != nil {
		http.Error(w, "フォームを解析できません", http.StatusBadRequest)
		return
	}
	formToken := r.Form.Get("csrf_token")
	if formToken == "" || len(formToken) != len(csrfCookie.Value) ||
		subtle.ConstantTimeCompare([]byte(formToken), []byte(csrfCookie.Value)) != 1 {
		http.Error(w, "CSRFトークンが不正です", http.StatusForbidden)
		return
	}
	if enabledValue := r.Form.Get("enabled"); enabledValue != "0" && enabledValue != "1" {
		http.Error(w, "enabledは0または1で指定してください", http.StatusBadRequest)
		return
	}

	if r.Method == http.MethodPost && r.URL.Path == "/toggle" {
		if mac == "" {
			http.Error(w, "MACアドレスを特定できません", http.StatusServiceUnavailable)
			return
		}
		res := portalAdblockSetFn(mac, r.Form.Get("enabled"))
		if e, ok := res["error"]; ok {
			message = fmt.Sprintf("エラー: %v", e)
		} else {
			message = "設定を反映しました。"
		}
	}

	enabled := mac != "" && portalAdblockMACsFn()[mac]
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	_, _ = fmt.Fprint(w, portalPage(mac, ip, enabled, message, csrfCookie.Value))
}

func runPortal() int {
	ip := portalBrlanIPFn()
	parsed := net.ParseIP(ip)
	if parsed == nil || parsed.To4() == nil {
		log.Printf("sbair-portal: br-lan IPv4 address is unavailable")
		return 1
	}
	addr := net.JoinHostPort(parsed.To4().String(), portalPort)
	mux := http.NewServeMux()
	mux.HandleFunc("/", portalHandler)
	log.Printf("sbair-portal listening on %s", addr)
	if err := portalListenFn(addr, mux); err != nil {
		log.Printf("sbair-portal: %v", err)
		return 1
	}
	return 0
}
