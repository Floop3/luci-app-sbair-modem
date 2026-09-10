// SPDX-License-Identifier: MIT
// Copyright (c) 2026 syado

package main

import (
	"encoding/binary"
	"fmt"
	"net"
	"os/exec"
	"strconv"
	"strings"
)

// sbair-netmode owns the network-side implementation. Keeping the UCI and
// runtime checks in one small, installed helper also lets recovery work before
// the Go binary has been rebuilt on a device.

func netmodeFields(args ...string) (map[string]string, error) {
	out, err := exec.Command("sbair-netmode", args...).CombinedOutput()
	if err != nil {
		return nil, fmt.Errorf("sbair-netmode %s: %v: %s", strings.Join(args, " "), err, strings.TrimSpace(string(out)))
	}
	return parseNetmodeFields(string(out)), nil
}

// cellularWANAllowed keeps existing modem operations useful in SIM mode while
// preventing an AP-mode reset/APN change from reintroducing a default route.
func cellularWANAllowed() bool {
	managed, managedErr := uci("get", "sbair.bridge.managed")
	mode, err := uci("get", "sbair.bridge.mode")
	if managedErr == nil && managed == "1" && err == nil {
		return mode != "ap"
	}
	// Before an explicit mode apply, retain the old AP hint. This also covers
	// configurations created by the pre-snapshot release.
	ignore, _ := uci("get", "dhcp.lan.ignore")
	return ignore != "1"
}

func ifupWAN() ([]byte, error) {
	if !cellularWANAllowed() {
		return nil, nil
	}
	return exec.Command("ifup", "wan").CombinedOutput()
}

func parseNetmodeFields(raw string) map[string]string {
	fields := map[string]string{}
	for _, line := range strings.Split(raw, "\n") {
		parts := strings.SplitN(strings.TrimSpace(line), "=", 2)
		if len(parts) == 2 && parts[0] != "" {
			fields[parts[0]] = parts[1]
		}
	}
	return fields
}

func netmodeStatus() map[string]any {
	fields, err := netmodeFields("show")
	if err != nil {
		return map[string]any{"error": err.Error()}
	}

	managed := netmodeBool(fields, "managed")
	mode := netmodeString(fields, "mode", "sim")
	configuredMode := netmodeString(fields, "configured_mode", mode)
	if !managed {
		mode = "unmanaged"
	}
	status := map[string]any{
		"mode":            mode,
		"configured_mode": configuredMode,
		"managed":         managed,
		"health":          netmodeString(fields, "health", "warn"),
		"healthy":         netmodeBool(fields, "healthy"),
		"management": map[string]any{
			"proto":              netmodeString(fields, "management.proto", "-"),
			"address":            netmodeString(fields, "management.address", "-"),
			"gateway":            netmodeString(fields, "management.gateway", "-"),
			"dns":                netmodeString(fields, "management.dns", "-"),
			"oem_baseline_ready": netmodeBool(fields, "management.oem_baseline_ready"),
			"oem": map[string]any{
				"ipaddr":  netmodeString(fields, "management.oem.ipaddr", ""),
				"netmask": netmodeString(fields, "management.oem.netmask", ""),
				"gateway": netmodeString(fields, "management.oem.gateway", ""),
				"dns":     netmodeString(fields, "management.oem.dns", ""),
			},
			"effective": map[string]any{
				"ipaddr":         netmodeString(fields, "management.effective.ipaddr", ""),
				"netmask":        netmodeString(fields, "management.effective.netmask", ""),
				"gateway":        netmodeString(fields, "management.effective.gateway", ""),
				"dns":            netmodeString(fields, "management.effective.dns", ""),
				"ipaddr_source":  netmodeString(fields, "management.effective.ipaddr_source", ""),
				"netmask_source": netmodeString(fields, "management.effective.netmask_source", ""),
				"gateway_source": netmodeString(fields, "management.effective.gateway_source", ""),
				"dns_source":     netmodeString(fields, "management.effective.dns_source", ""),
			},
			"fallback_ip":       netmodeString(fields, "management.fallback_ip", "-"),
			"fallback_netmask":  netmodeString(fields, "management.fallback_netmask", "-"),
			"fallback_active":   netmodeBool(fields, "management.fallback_active"),
			"fallback_conflict": netmodeBool(fields, "management.fallback_conflict"),
		},
		"dhcp_server": map[string]any{
			"configured":      netmodeBool(fields, "dhcp.configured"),
			"udp67_listening": netmodeBool(fields, "dhcp.udp67_listening"),
			"udp67_scope":     netmodeString(fields, "dhcp.udp67_scope", "system"),
			"uci_ignore":      netmodeBool(fields, "dhcp.uci_ignore"),
			"guard_active":    netmodeBool(fields, "dhcp.guard_active"),
		},
		"bridge": map[string]any{
			"device":        netmodeString(fields, "bridge.device", "br-lan"),
			"up":            netmodeBool(fields, "bridge.up"),
			"members":       netmodeString(fields, "bridge.members", "-"),
			"members_count": netmodeInt(fields, "bridge.members_count"),
		},
		"cellular": map[string]any{
			"interface":       netmodeString(fields, "cellular.interface", "-"),
			"routing_enabled": netmodeBool(fields, "cellular.routing_enabled"),
			"default_route":   netmodeBool(fields, "cellular.default_route"),
		},
		"wifi": map[string]any{
			"mlo":          netmodeFlag(fields, "wifi.mlo"),
			"bandsteering": netmodeFlag(fields, "wifi.bandsteering"),
			"2g":           netmodeFlag(fields, "wifi.2g"),
			"5g":           netmodeFlag(fields, "wifi.5g"),
			"6g":           netmodeFlag(fields, "wifi.6g"),
		},
		"vendor_alias": "172.16.255.254 (network.lan1; 保持)",
		"repair": map[string]any{
			"last":  netmodeString(fields, "repair.last", "-"),
			"count": netmodeInt(fields, "repair.count"),
		},
	}

	warnings := netmodeString(fields, "warnings", "")
	if warnings != "" {
		var list []string
		for _, warning := range strings.Split(warnings, "|") {
			if warning = strings.TrimSpace(warning); warning != "" {
				list = append(list, warning)
			}
		}
		status["warnings"] = list
	}
	if pending := netmodeString(fields, "pending.id", ""); pending != "" {
		status["pending"] = map[string]any{
			"id":        pending,
			"mode":      netmodeString(fields, "pending.mode", "-"),
			"remaining": netmodeInt(fields, "pending.remaining"),
		}
	}
	return status
}

func netmodeString(fields map[string]string, key, fallback string) string {
	if value, ok := fields[key]; ok && value != "" {
		return value
	}
	return fallback
}

func netmodeBool(fields map[string]string, key string) bool {
	return fields[key] == "1" || strings.EqualFold(fields[key], "true")
}

func netmodeFlag(fields map[string]string, key string) any {
	value := fields[key]
	if value == "1" || strings.EqualFold(value, "true") {
		return true
	}
	if value == "0" || strings.EqualFold(value, "false") {
		return false
	}
	return "unknown"
}

func netmodeInt(fields map[string]string, key string) int {
	n, _ := strconv.Atoi(fields[key])
	return n
}

func netmodeStaticConfig(fields map[string]string) map[string]any {
	return map[string]any{
		"ipaddr":             netmodeString(fields, "ipaddr", ""),
		"netmask":            netmodeString(fields, "netmask", ""),
		"gateway":            netmodeString(fields, "gateway", ""),
		"dns":                netmodeString(fields, "dns", ""),
		"oem_baseline_ready": netmodeBool(fields, "oem_baseline_ready"),
		"oem": map[string]any{
			"ipaddr":  netmodeString(fields, "oem.ipaddr", ""),
			"netmask": netmodeString(fields, "oem.netmask", ""),
			"gateway": netmodeString(fields, "oem.gateway", ""),
			"dns":     netmodeString(fields, "oem.dns", ""),
		},
		"effective": map[string]any{
			"ipaddr":         netmodeString(fields, "effective.ipaddr", ""),
			"netmask":        netmodeString(fields, "effective.netmask", ""),
			"gateway":        netmodeString(fields, "effective.gateway", ""),
			"dns":            netmodeString(fields, "effective.dns", ""),
			"ipaddr_source":  netmodeString(fields, "effective.ipaddr_source", ""),
			"netmask_source": netmodeString(fields, "effective.netmask_source", ""),
			"gateway_source": netmodeString(fields, "effective.gateway_source", ""),
			"dns_source":     netmodeString(fields, "effective.dns_source", ""),
			"error":          netmodeString(fields, "effective.error", ""),
		},
	}
}

func netmodeResult(args ...string) map[string]any {
	fields, err := netmodeFields(args...)
	if err != nil {
		return map[string]any{"error": err.Error()}
	}
	result := map[string]any{}
	for key, value := range fields {
		result[key] = value
	}
	if result["result"] == nil {
		result["result"] = "ok"
	}
	return result
}

func netmodeSet(mode string) map[string]any {
	if mode != "sim" && mode != "ap" {
		return map[string]any{"error": fmt.Sprintf("unknown mode %q", mode)}
	}
	return netmodeResult("apply", mode)
}

func netmodeApply(in rpcdArgs) map[string]any {
	if in.Mode != "sim" && in.Mode != "ap" {
		return map[string]any{"error": fmt.Sprintf("unknown mode %q", in.Mode)}
	}
	args := []string{"apply", in.Mode}
	fallbackEnabled := "0"
	if in.FallbackEnabled {
		fallbackEnabled = "1"
	}
	// LuCI sends the complete draft in one call. Always pass every field so a
	// false/empty value cannot accidentally fall back to an older draft.
	args = append(args,
		"proto="+in.Proto,
		"ipaddr="+in.IPAddr,
		"netmask="+in.Netmask,
		"gateway="+in.Gateway,
		"dns="+in.DNS,
		"fallback_enabled="+fallbackEnabled,
		"fallback_ip="+in.FallbackIP,
		"fallback_netmask="+in.FallbackNetmask,
		"fallback_timeout="+strconv.Itoa(in.FallbackTimeout),
	)
	if in.Mode == "sim" {
		poolArgs, err := netmodePoolArgs(in.DHCPStartIP, in.DHCPEndIP, in.DHCLeasetime)
		if err != nil {
			return map[string]any{"error": err.Error()}
		}
		args = append(args, poolArgs...)
	}
	return netmodeResult(args...)
}

func netmodePoolContext(mode string) (map[string]string, error) {
	if mode != "sim" {
		return nil, fmt.Errorf("DHCP pool context is only available for SIM mode")
	}
	return netmodeFields("pool-context", mode)
}

func validDHCPLeasetime(value string) bool {
	if value == "" || strings.TrimSpace(value) != value || strings.ContainsAny(value, "\r\n=") {
		return false
	}
	if value == "infinite" {
		return true
	}
	number := value
	if last := value[len(value)-1]; strings.ContainsRune("smhdw", rune(last)) {
		number = value[:len(value)-1]
	}
	seconds, err := strconv.ParseUint(number, 10, 64)
	return err == nil && seconds > 0
}

func ipv4Uint32(value string) (uint32, error) {
	if !validIPv4(value) {
		return 0, fmt.Errorf("%q is not a valid IPv4 address", value)
	}
	return binary.BigEndian.Uint32(net.ParseIP(value).To4()), nil
}

func ipv4Text(value uint32) string {
	var ip [4]byte
	binary.BigEndian.PutUint32(ip[:], value)
	return net.IPv4(ip[0], ip[1], ip[2], ip[3]).String()
}

func dhcpNetworkBounds(network, netmask string) (uint32, uint32, error) {
	ip, err := ipv4Uint32(network)
	if err != nil {
		return 0, 0, fmt.Errorf("DHCP network: %v", err)
	}
	if !validNetmask(netmask) {
		return 0, 0, fmt.Errorf("DHCP netmask %q is invalid", netmask)
	}
	maskIP := net.ParseIP(netmask).To4()
	mask := binary.BigEndian.Uint32(maskIP)
	base := ip & mask
	broadcast := base | ^mask
	ones, _ := net.IPMask(maskIP).Size()
	if ones >= 31 {
		return 0, 0, fmt.Errorf("DHCP subnet %s/%d has no usable host pool", ipv4Text(base), ones)
	}
	return base, broadcast, nil
}

func dhcpPoolToUCI(startIP, endIP, network, netmask, router string) (string, string, error) {
	base, broadcast, err := dhcpNetworkBounds(network, netmask)
	if err != nil {
		return "", "", err
	}
	start, err := ipv4Uint32(startIP)
	if err != nil {
		return "", "", fmt.Errorf("DHCP開始アドレス: %v", err)
	}
	end, err := ipv4Uint32(endIP)
	if err != nil {
		return "", "", fmt.Errorf("DHCP終了アドレス: %v", err)
	}
	if start > end {
		return "", "", fmt.Errorf("DHCP開始アドレスは終了アドレス以下にしてください")
	}
	if start <= base || end >= broadcast {
		return "", "", fmt.Errorf("DHCP範囲はnetwork address/broadcastを含められません")
	}
	if router != "" {
		routerValue, routerErr := ipv4Uint32(router)
		if routerErr != nil {
			return "", "", fmt.Errorf("ルーターのIPが不正です: %v", routerErr)
		}
		if routerValue < base || routerValue > broadcast {
			return "", "", fmt.Errorf("ルーターのIPがDHCPサブネット外です")
		}
		if routerValue >= start && routerValue <= end {
			return "", "", fmt.Errorf("DHCP範囲にルーター自身のIPを含められません")
		}
	}
	return strconv.FormatUint(uint64(start-base), 10), strconv.FormatUint(uint64(end-start+1), 10), nil
}

func dhcpPoolRange(network, netmask, startOffset, limit string) (string, string, bool) {
	base, broadcast, err := dhcpNetworkBounds(network, netmask)
	if err != nil {
		return "", "", false
	}
	start, err := strconv.ParseUint(startOffset, 10, 32)
	if err != nil || start == 0 {
		return "", "", false
	}
	count, err := strconv.ParseUint(limit, 10, 32)
	if err != nil || count == 0 || start > uint64(broadcast-base-1) {
		return "", "", false
	}
	first := uint64(base) + start
	last := first + count - 1
	if last >= uint64(broadcast) || last < first {
		return "", "", false
	}
	return ipv4Text(uint32(first)), ipv4Text(uint32(last)), true
}

func netmodePoolArgs(startIP, endIP, leasetime string) ([]string, error) {
	if startIP == "" && endIP == "" {
		if leasetime == "" {
			return nil, nil
		}
		if !validDHCPLeasetime(leasetime) {
			return nil, fmt.Errorf("DHCPリース時間が不正です")
		}
		return []string{"dhcp_leasetime=" + leasetime}, nil
	}
	if startIP == "" || endIP == "" {
		return nil, fmt.Errorf("DHCP開始アドレスと終了アドレスは両方指定してください")
	}
	context, err := netmodePoolContext("sim")
	if err != nil {
		return nil, fmt.Errorf("SIM LANのDHCP範囲を確認できません: %v", err)
	}
	start, limit, err := dhcpPoolToUCI(startIP, endIP, context["network"], context["netmask"], context["router"])
	if err != nil {
		return nil, err
	}
	args := []string{"dhcp_start=" + start, "dhcp_limit=" + limit}
	if leasetime != "" {
		if !validDHCPLeasetime(leasetime) {
			return nil, fmt.Errorf("DHCPリース時間が不正です")
		}
		args = append(args, "dhcp_leasetime="+leasetime)
	}
	return args, nil
}

func netmodeGetConfig() map[string]any {
	fields, err := netmodeFields("get-config")
	if err != nil {
		return map[string]any{"error": err.Error()}
	}
	managed := netmodeBool(fields, "managed")
	configuredMode := netmodeString(fields, "configured_mode", netmodeString(fields, "mode", "sim"))
	poolNetwork := netmodeString(fields, "dhcp.network", "")
	poolNetmask := netmodeString(fields, "dhcp.netmask", "")
	if managed && configuredMode == "sim" && (poolNetwork == "" || poolNetmask == "") {
		if context, contextErr := netmodePoolContext("sim"); contextErr == nil {
			poolNetwork = context["network"]
			poolNetmask = context["netmask"]
		}
	}
	poolStart := netmodeString(fields, "dhcp.start", "")
	poolLimit := netmodeString(fields, "dhcp.limit", "")
	poolLeasetime := netmodeString(fields, "dhcp.leasetime", "")
	if netmodeBool(fields, "draft") {
		if desired := netmodeString(fields, "desired_dhcp.start", ""); desired != "" {
			poolStart = desired
		}
		if desired := netmodeString(fields, "desired_dhcp.limit", ""); desired != "" {
			poolLimit = desired
		}
		if desired := netmodeString(fields, "desired_dhcp.leasetime", ""); desired != "" {
			poolLeasetime = desired
		}
	}
	poolStartIP, poolEndIP := "", ""
	if poolNetwork != "" && poolNetmask != "" {
		poolStartIP, poolEndIP, _ = dhcpPoolRange(poolNetwork, poolNetmask, poolStart, poolLimit)
	}
	simNetwork, simNetmask := "", ""
	if context, contextErr := netmodePoolContext("sim"); contextErr == nil {
		simNetwork = context["network"]
		simNetmask = context["netmask"]
	}
	config := map[string]any{
		"mode":                netmodeString(fields, "mode", "sim"),
		"configured_mode":     configuredMode,
		"managed":             managed,
		"draft":               netmodeBool(fields, "draft"),
		"ap_dhcp_enabled":     netmodeBool(fields, "ap_dhcp_enabled"),
		"proto":               netmodeString(fields, "proto", "dhcp"),
		"fallback_enabled":    netmodeBool(fields, "fallback_enabled"),
		"fallback_ip":         netmodeString(fields, "fallback_ip", "192.168.3.1"),
		"fallback_netmask":    netmodeString(fields, "fallback_netmask", "255.255.255.0"),
		"fallback_timeout":    netmodeInt(fields, "fallback_timeout"),
		"dhcp_start_ip":       poolStartIP,
		"dhcp_end_ip":         poolEndIP,
		"dhcp_leasetime":      poolLeasetime,
		"dhcp_start":          poolStart,
		"dhcp_limit":          poolLimit,
		"dhcp_pool_network":   poolNetwork,
		"dhcp_pool_netmask":   poolNetmask,
		"dhcp_pool_available": poolStartIP != "" && poolEndIP != "",
		"sim_network":         simNetwork,
		"sim_netmask":         simNetmask,
	}
	for key, value := range netmodeStaticConfig(fields) {
		config[key] = value
	}
	return config
}

func validIPv4(value string) bool {
	value = strings.TrimSpace(value)
	ip := net.ParseIP(value)
	return ip != nil && ip.To4() != nil && ip.To4().String() == value
}

func validNetmask(value string) bool {
	value = strings.TrimSpace(value)
	ip := net.ParseIP(value)
	if ip == nil || ip.To4() == nil || ip.To4().String() != value {
		return false
	}
	ones, bits := net.IPMask(ip.To4()).Size()
	return bits == 32 && ones >= 1 && ones <= 32
}

func netmodeSetConfig(in rpcdArgs) map[string]any {
	if in.Proto != "dhcp" && in.Proto != "static" {
		return map[string]any{"error": "管理IP方式は dhcp または static です"}
	}
	if in.FallbackIP == "" {
		in.FallbackIP = "192.168.3.1"
	}
	if in.FallbackNetmask == "" {
		in.FallbackNetmask = "255.255.255.0"
	}
	if in.FallbackTimeout == 0 {
		in.FallbackTimeout = 15
	}
	if in.Proto == "static" && in.IPAddr != "" && !validIPv4(in.IPAddr) {
		return map[string]any{"error": "固定IPは空欄または有効なIPv4値が必要です（空欄は純正設定を継承）"}
	}
	if in.Proto == "static" && in.Netmask != "" && !validNetmask(in.Netmask) {
		return map[string]any{"error": "ネットマスクは空欄または有効なIPv4値が必要です（空欄は純正設定を継承）"}
	}
	if in.Gateway != "" && !validIPv4(in.Gateway) {
		return map[string]any{"error": "Gateway は有効なIPv4値が必要です"}
	}
	if in.FallbackIP != "" && !validIPv4(in.FallbackIP) {
		return map[string]any{"error": "Fallback IP は有効なIPv4値が必要です"}
	}
	if in.FallbackIP == "172.16.255.254" {
		return map[string]any{"error": "172.16.255.254 はvendor aliasのためFallbackに使えません"}
	}
	if in.FallbackNetmask != "" && !validNetmask(in.FallbackNetmask) {
		return map[string]any{"error": "Fallback netmask は有効なIPv4値が必要です"}
	}
	if in.FallbackTimeout < 5 || in.FallbackTimeout > 3600 {
		return map[string]any{"error": "Fallback待機時間は5〜3600秒です"}
	}

	fallbackEnabled := "0"
	if in.FallbackEnabled {
		fallbackEnabled = "1"
	}
	args := []string{
		"set-config",
		"proto=" + in.Proto,
		"ipaddr=" + in.IPAddr,
		"netmask=" + in.Netmask,
		"gateway=" + in.Gateway,
		"dns=" + in.DNS,
		"fallback_enabled=" + fallbackEnabled,
		"fallback_ip=" + in.FallbackIP,
		"fallback_netmask=" + in.FallbackNetmask,
		"fallback_timeout=" + strconv.Itoa(in.FallbackTimeout),
	}
	poolArgs, err := netmodePoolArgs(in.DHCPStartIP, in.DHCPEndIP, in.DHCLeasetime)
	if err != nil {
		return map[string]any{"error": err.Error()}
	}
	args = append(args, poolArgs...)
	return netmodeResult(args...)
}

func netmodeConfirm() map[string]any { return netmodeResult("confirm") }

func netmodeRollback() map[string]any { return netmodeResult("rollback") }

func netmodeUnmanage() map[string]any { return netmodeResult("unmanage") }

func netmodeRepair() map[string]any { return netmodeResult("repair") }
