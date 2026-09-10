// SPDX-License-Identifier: MIT
// Copyright (c) 2026 syado

package main

import (
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"sync"
	"time"
)

// SSDP(UPnPの発見プロトコル)。スマートTV・プリンター・ゲーム機等、mDNS/NBNSに
// 応答しない機器から friendlyName を拾うための3つ目の経路。
//
// M-SEARCHはローカルLANへのマルチキャストで、応答のLOCATION先(同じLAN内の機器)への
// HTTP GETも局所通信のみ。Air6自身の外向き通信問題とは無関係。

const ssdpAddr = "239.255.255.250:1900"

var ssdpRequest = "M-SEARCH * HTTP/1.1\r\n" +
	"HOST: 239.255.255.250:1900\r\n" +
	"MAN: \"ssdp:discover\"\r\n" +
	"MX: 2\r\n" +
	"ST: ssdp:all\r\n\r\n"

// ssdpDiscover は応答してきた機器の ip → friendlyName を返す(引けた分だけ)。
func ssdpDiscover() map[string]string {
	out := map[string]string{}
	networks, self, err := currentBridgeIPv4()
	if err != nil {
		return out
	}

	group, err := net.ResolveUDPAddr("udp4", ssdpAddr)
	if err != nil {
		return out
	}
	// Let the kernel select the source address for the multicast request. The
	// response source is still strictly validated against br-lan below; binding
	// to self[0] would make discovery fail on devices that retain a vendor
	// alias before the current management address in interface order.
	conn, err := net.ListenUDP("udp4", nil)
	if err != nil {
		return out
	}
	defer conn.Close()
	_ = conn.SetDeadline(time.Now().Add(2500 * time.Millisecond))

	if _, err := conn.WriteToUDP([]byte(ssdpRequest), group); err != nil {
		return out
	}

	type response struct {
		source   net.IP
		location string
	}
	locations := map[string]response{} // source IP -> validated LOCATION URL
	buf := make([]byte, 4096)
	for {
		n, from, err := conn.ReadFromUDP(buf)
		if err != nil {
			break
		}
		loc := parseSSDPLocation(buf[:n])
		if loc != "" && validateSSDPLocation(loc, from.IP, networks, self) == nil {
			locations[from.IP.String()] = response{source: append(net.IP(nil), from.IP...), location: loc}
		}
	}

	var mu sync.Mutex
	var wg sync.WaitGroup
	for ip, item := range locations {
		wg.Add(1)
		go func(ip string, item response) {
			defer wg.Done()
			if name := fetchFriendlyNameOnLAN(item.location, item.source, networks, self); name != "" {
				mu.Lock()
				out[ip] = name
				mu.Unlock()
			}
		}(ip, item)
	}
	wg.Wait()
	return out
}

// validateSSDPLocation confines the subsequent HTTP request to the network
// which received the SSDP response.  In particular, LOCATION is not allowed
// to redirect the backend to a WAN host, loopback, multicast, or another LAN.
func validateSSDPLocation(location string, source net.IP, networks []*net.IPNet, self []net.IP) error {
	u, err := url.Parse(strings.TrimSpace(location))
	if err != nil || u.Scheme != "http" || u.Host == "" || u.User != nil || u.Opaque != "" {
		return fmt.Errorf("LOCATION must be a plain http URL")
	}
	host := u.Hostname()
	hostIP := net.ParseIP(host)
	source4 := source.To4()
	if hostIP == nil || hostIP.To4() == nil || strings.Contains(host, ":") || source4 == nil {
		return fmt.Errorf("LOCATION and SSDP source must be IPv4")
	}
	if port := u.Port(); port != "" {
		if n, parseErr := strconv.Atoi(port); parseErr != nil || n < 1 || n > 65535 {
			return fmt.Errorf("LOCATION has an invalid port")
		}
	}
	if !hostIP.To4().Equal(source4) {
		return fmt.Errorf("LOCATION host differs from SSDP source")
	}
	if isSpecialIPv4(source4, networks) {
		return fmt.Errorf("SSDP source is a special IPv4 address")
	}
	for _, own := range self {
		if source4.Equal(own.To4()) {
			return fmt.Errorf("SSDP source is this router")
		}
	}
	inLAN := false
	for _, network := range networks {
		if network != nil && network.Contains(source4) {
			inLAN = true
			break
		}
	}
	if !inLAN {
		return fmt.Errorf("SSDP source is outside the current br-lan network")
	}
	return nil
}

func parseSSDPLocation(msg []byte) string {
	for _, line := range strings.Split(string(msg), "\r\n") {
		if i := strings.IndexByte(line, ':'); i > 0 {
			key := strings.ToUpper(strings.TrimSpace(line[:i]))
			if key == "LOCATION" {
				return strings.TrimSpace(line[i+1:])
			}
		}
	}
	return ""
}

// fetchFriendlyName はUPnPデバイス記述XMLを取りに行き、<friendlyName>を抜き出す。
// 厳密なXMLパースはせず、タグの間の文字列を素朴に拾うだけ(この用途には十分)。
func fetchFriendlyName(location string) string {
	u, err := url.Parse(location)
	if err != nil {
		return ""
	}
	source := net.ParseIP(u.Hostname())
	networks, self, err := currentBridgeIPv4()
	if err != nil || validateSSDPLocation(location, source, networks, self) != nil {
		return ""
	}
	return fetchFriendlyNameOnLAN(location, source, networks, self)
}

func fetchFriendlyNameOnLAN(location string, source net.IP, networks []*net.IPNet, self []net.IP) string {
	if validateSSDPLocation(location, source, networks, self) != nil {
		return ""
	}
	client := &http.Client{
		Timeout: 1500 * time.Millisecond,
		CheckRedirect: func(_ *http.Request, _ []*http.Request) error {
			return http.ErrUseLastResponse
		},
	}
	resp, err := client.Get(location)
	if err != nil {
		return ""
	}
	defer resp.Body.Close()
	if resp.StatusCode < http.StatusOK || resp.StatusCode >= http.StatusMultipleChoices {
		return ""
	}
	body, err := io.ReadAll(io.LimitReader(resp.Body, 32*1024))
	if err != nil {
		return ""
	}
	const open, close = "<friendlyName>", "</friendlyName>"
	s := string(body)
	i := strings.Index(s, open)
	if i < 0 {
		return ""
	}
	s = s[i+len(open):]
	j := strings.Index(s, close)
	if j < 0 {
		return ""
	}
	return strings.TrimSpace(s[:j])
}
