// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Floop3

package main

import (
	"fmt"
	"os/exec"
	"strings"
)

// maintenanceFields is intentionally a small key=value protocol. The helper
// runs on the Air 6 and remains directly usable from SSH/UART, while this Go
// layer turns the result into the structured JSON expected by LuCI.
func maintenanceFields(args ...string) (map[string]string, error) {
	out, runErr := exec.Command("sbair-maintenance", args...).CombinedOutput()
	fields, parseErr := parseMaintenanceFields(string(out))
	if parseErr != nil {
		return nil, parseErr
	}
	if message := fields["error"]; message != "" {
		return fields, fmt.Errorf("%s", message)
	}
	if runErr != nil {
		return fields, fmt.Errorf("sbair-maintenance %s: %v", strings.Join(args, " "), runErr)
	}
	return fields, nil
}

func parseMaintenanceFields(raw string) (map[string]string, error) {
	fields := map[string]string{}
	for _, line := range strings.Split(raw, "\n") {
		line = strings.TrimSpace(line)
		if line == "" {
			continue
		}
		parts := strings.SplitN(line, "=", 2)
		if len(parts) != 2 || strings.TrimSpace(parts[0]) == "" {
			return nil, fmt.Errorf("sbair-maintenance returned malformed output: %q", line)
		}
		key := strings.TrimSpace(parts[0])
		if _, exists := fields[key]; exists {
			return nil, fmt.Errorf("sbair-maintenance returned duplicate field: %s", key)
		}
		fields[key] = parts[1]
	}
	return fields, nil
}

func maintenanceRequired(fields map[string]string, keys ...string) error {
	for _, key := range keys {
		if _, ok := fields[key]; !ok {
			return fmt.Errorf("sbair-maintenance status missing field: %s", key)
		}
	}
	return nil
}

func maintenanceTyped(value string) any {
	switch strings.ToLower(value) {
	case "1", "true", "yes", "on", "enabled", "running":
		return true
	case "0", "false", "no", "off", "disabled", "stopped":
		return false
	default:
		return value
	}
}

func maintenanceStatus() map[string]any {
	fields, err := maintenanceFields("status")
	if err != nil {
		return map[string]any{"error": err.Error()}
	}
	required := []string{
		"result",
		"dhcp_server.uci_ignore", "dhcp_server.enabled",
		"dhcp_server.udp67_listening", "dhcp_server.udp67_scope",
		"dhcp_server.dnsmasq", "dhcp_server.port53_listening",
		"dhcp_server.port53_tcp_scope", "dhcp_server.port53_udp_scope",
		"dhcp_server.odhcpd", "dhcp_server.ra", "dhcp_server.dhcpv6",
		"dhcp_server.ndp", "dhcp_server.owner", "dhcp_server.guard_active",
		"dhcp_server.pending",
		"fota.config_enabled", "fota.provision_enabled", "fota.config_respawn",
		"fota.kn_fotad", "fota.autostart",
	}
	if err := maintenanceRequired(fields, required...); err != nil {
		return map[string]any{"error": err.Error()}
	}
	return map[string]any{
		"dhcp_server": map[string]any{
			"uci_ignore":       fields["dhcp_server.uci_ignore"],
			"enabled":          maintenanceTyped(fields["dhcp_server.enabled"]),
			"udp67_listening":  maintenanceTyped(fields["dhcp_server.udp67_listening"]),
			"udp67_scope":      fields["dhcp_server.udp67_scope"],
			"dnsmasq":          fields["dhcp_server.dnsmasq"],
			"port53_listening": maintenanceTyped(fields["dhcp_server.port53_listening"]),
			"port53_tcp_scope": fields["dhcp_server.port53_tcp_scope"],
			"port53_udp_scope": fields["dhcp_server.port53_udp_scope"],
			"odhcpd":           fields["dhcp_server.odhcpd"],
			"ra":               fields["dhcp_server.ra"],
			"dhcpv6":           fields["dhcp_server.dhcpv6"],
			"ndp":              fields["dhcp_server.ndp"],
			"owner":            fields["dhcp_server.owner"],
			"guard_active":     maintenanceTyped(fields["dhcp_server.guard_active"]),
			"pending":          maintenanceTyped(fields["dhcp_server.pending"]),
		},
		"fota": map[string]any{
			"config_enabled":    fields["fota.config_enabled"],
			"provision_enabled": fields["fota.provision_enabled"],
			"config_respawn":    fields["fota.config_respawn"],
			"kn_fotad":          fields["fota.kn_fotad"],
			"autostart":         fields["fota.autostart"],
		},
	}
}

func maintenanceEnabled(value rpcdEnabled) bool {
	switch strings.ToLower(value.String()) {
	case "1", "true", "yes", "on", "enabled":
		return true
	default:
		return false
	}
}

func maintenanceSet(kind string, enabled bool) map[string]any {
	action := "disable"
	if enabled {
		action = "enable"
	}
	fields, err := maintenanceFields(kind, action)
	if err != nil {
		return map[string]any{"error": err.Error()}
	}
	result := map[string]any{
		"result": fields["result"],
	}
	if result["result"] == "" {
		result["result"] = "ok"
	}
	for key, value := range fields {
		switch {
		case key == "warning":
			result["warning"] = value
		case key == "backup":
			result["backup"] = value
		case strings.HasPrefix(key, "verification."):
			verification, ok := result["verification"].(map[string]any)
			if !ok {
				verification = map[string]any{}
				result["verification"] = verification
			}
			verification[strings.TrimPrefix(key, "verification.")] = maintenanceTyped(value)
		case strings.HasPrefix(key, "fota."):
			fota, ok := result["fota"].(map[string]any)
			if !ok {
				fota = map[string]any{}
				result["fota"] = fota
			}
			fota[strings.TrimPrefix(key, "fota.")] = maintenanceTyped(value)
		}
	}
	return result
}
