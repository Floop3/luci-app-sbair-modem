// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Floop3

package main

import (
	"fmt"
	"os/exec"
	"strings"
)

// The target helper owns all ConfigFS/UDC mutation. rpcd only transports its
// small key=value protocol into structured JSON for LuCI.
func usbNICFields(args ...string) (map[string]string, error) {
	out, runErr := exec.Command("sbair-usb-nic", args...).CombinedOutput()
	fields, parseErr := parseUSBNICFields(string(out))
	if parseErr != nil {
		return nil, parseErr
	}
	if message := fields["error"]; message != "" {
		return fields, fmt.Errorf("%s", message)
	}
	if runErr != nil {
		return fields, fmt.Errorf("sbair-usb-nic %s: %v", strings.Join(args, " "), runErr)
	}
	return fields, nil
}

func parseUSBNICFields(raw string) (map[string]string, error) {
	fields := map[string]string{}
	for _, line := range strings.Split(raw, "\n") {
		line = strings.TrimSpace(line)
		if line == "" {
			continue
		}
		parts := strings.SplitN(line, "=", 2)
		if len(parts) != 2 || strings.TrimSpace(parts[0]) == "" {
			return nil, fmt.Errorf("sbair-usb-nic returned malformed output: %q", line)
		}
		key := strings.TrimSpace(parts[0])
		if _, exists := fields[key]; exists {
			return nil, fmt.Errorf("sbair-usb-nic returned duplicate field: %s", key)
		}
		fields[key] = parts[1]
	}
	return fields, nil
}

func usbNICBool(value string) bool {
	switch strings.ToLower(value) {
	case "1", "true", "yes", "on", "enabled", "up", "active", "ok":
		return true
	default:
		return false
	}
}

func usbNICStructured(fields map[string]string) map[string]any {
	result := map[string]any{
		"result": fields["result"],
		"bundle": map[string]any{
			"state":  fields["bundle"],
			"reason": fields["bundle_reason"],
		},
		"driver": map[string]any{
			"name":              fields["module_name"],
			"sha256":            fields["driver_sha256"],
			"vermagic":          fields["driver_vermagic"],
			"kernel":            fields["kernel"],
			"architecture":      fields["architecture"],
			"license":           fields["license"],
			"support_level":     fields["support_level"],
			"upstream_revision": fields["upstream_revision"],
		},
		"udc": map[string]any{
			"name":          fields["udc"],
			"present":       usbNICBool(fields["udc_present"]),
			"state":         fields["udc_state"],
			"current_speed": fields["udc_current_speed"],
			"bound_gadget":  fields["udc_bound_gadget"],
			"vendor_gadget": fields["vendor_gadget"],
			"custom_gadget": fields["custom_gadget"],
		},
		"profile": map[string]any{
			"state":  fields["profile"],
			"path":   fields["profile_path"],
			"reason": fields["profile_reason"],
		},
		"runtime": map[string]any{
			"state":         fields["runtime"],
			"module_loaded": usbNICBool(fields["module_loaded"]),
			"snapshot":      fields["snapshot"],
			"rollback":      fields["rollback"],
		},
		"loaded_usb_modules": fields["loaded_usb_modules"],
		"usb0": map[string]any{
			"state":   fields["usb0_state"],
			"carrier": fields["usb0_carrier"],
		},
		"management_path": fields["management_path"],
		"preflight": map[string]any{
			"state":  fields["preflight"],
			"reason": fields["preflight_reason"],
		},
	}
	if result["result"] == "" {
		result["result"] = "ok"
	}
	for _, key := range []string{"warning", "error", "rollback", "vendor_restore"} {
		if fields[key] != "" {
			result[key] = fields[key]
		}
	}
	return result
}

func usbNICCall(args ...string) map[string]any {
	fields, err := usbNICFields(args...)
	if fields == nil {
		return map[string]any{"error": err.Error()}
	}
	result := usbNICStructured(fields)
	if err != nil {
		result["error"] = err.Error()
	}
	return result
}

func usbNICStatus() map[string]any {
	return usbNICCall("status")
}

func usbNICEnable(ack bool) map[string]any {
	if !ack {
		return map[string]any{"error": "USB NIC enable requires explicit acknowledgement"}
	}
	return usbNICCall("enable", "--ack")
}

func usbNICDisable() map[string]any {
	return usbNICCall("disable")
}
