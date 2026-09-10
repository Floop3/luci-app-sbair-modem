// SPDX-License-Identifier: MIT
// Copyright (c) 2026 syado

package main

import "testing"

func TestParseNetmodeFields(t *testing.T) {
	got := parseNetmodeFields(" mode=ap\nbridge.members=eth0.1 ra0\ninvalid\n=ignored\n")
	if got["mode"] != "ap" || got["bridge.members"] != "eth0.1 ra0" {
		t.Fatalf("parsed fields = %#v", got)
	}
	if _, ok := got["invalid"]; ok {
		t.Fatal("invalid line was accepted")
	}
}

func TestNetmodeStaticConfigKeepsRawBlankAndSeparatesFallback(t *testing.T) {
	config := netmodeStaticConfig(map[string]string{
		"ipaddr":                  "",
		"netmask":                 "",
		"fallback_ip":             "192.168.3.1",
		"fallback_netmask":        "255.255.255.0",
		"oem_baseline_ready":      "1",
		"oem.ipaddr":              "198.51.100.11",
		"oem.netmask":             "255.255.255.0",
		"oem.gateway":             "198.51.100.1",
		"oem.dns":                 "198.51.100.1",
		"effective.ipaddr":        "198.51.100.11",
		"effective.netmask":       "255.255.255.0",
		"effective.gateway":       "198.51.100.1",
		"effective.dns":           "198.51.100.1",
		"effective.ipaddr_source": "純正設定を継承",
	})
	if config["ipaddr"] != "" || config["netmask"] != "" {
		t.Fatalf("raw static fields were filled: %#v", config)
	}
	if config["fallback_ip"] != nil {
		t.Fatal("fallback leaked into raw static config")
	}
	effective := config["effective"].(map[string]any)
	if effective["ipaddr"] != "198.51.100.11" || effective["ipaddr_source"] != "純正設定を継承" {
		t.Fatalf("effective inherited values = %#v", effective)
	}
}

func TestNetmodeIPv4Validation(t *testing.T) {
	for _, value := range []string{"0.0.0.0", "192.168.3.1", "255.255.255.255"} {
		if !validIPv4(value) {
			t.Errorf("validIPv4(%q) = false", value)
		}
	}
	for _, value := range []string{"", "192.168.3", "256.1.1.1", "::1", "::ffff:192.168.3.1"} {
		if validIPv4(value) {
			t.Errorf("validIPv4(%q) = true", value)
		}
	}
}

func TestNetmodeNetmaskValidation(t *testing.T) {
	for _, value := range []string{"255.255.255.0", "255.255.255.254", "255.255.255.255"} {
		if !validNetmask(value) {
			t.Errorf("validNetmask(%q) = false", value)
		}
	}
	for _, value := range []string{"0.0.0.0", "255.255.0.255", "255.255.255.1", "255.255.255.00"} {
		if validNetmask(value) {
			t.Errorf("validNetmask(%q) = true", value)
		}
	}
}

func TestDHCPPoolConversion(t *testing.T) {
	start, limit, err := dhcpPoolToUCI("192.168.3.10", "192.168.3.100", "192.168.3.1", "255.255.255.0", "192.168.3.1")
	if err != nil || start != "10" || limit != "91" {
		t.Fatalf("/24 pool = %q/%q, %v", start, limit, err)
	}
	start, limit, err = dhcpPoolToUCI("10.10.4.5", "10.10.7.250", "10.10.4.1", "255.255.252.0", "10.10.4.1")
	if err != nil || start != "5" || limit != "1014" {
		t.Fatalf("/22 pool = %q/%q, %v", start, limit, err)
	}
	if gotStart, gotEnd, ok := dhcpPoolRange("10.10.4.1", "255.255.252.0", start, limit); !ok || gotStart != "10.10.4.5" || gotEnd != "10.10.7.250" {
		t.Fatalf("pool range = %q-%q, %v", gotStart, gotEnd, ok)
	}
}

func TestDHCPPoolRejectsUnsafeRanges(t *testing.T) {
	cases := [][2]string{
		{"192.168.3.100", "192.168.3.10"},
		{"192.168.3.0", "192.168.3.10"},
		{"192.168.3.10", "192.168.3.255"},
		{"192.168.4.10", "192.168.4.20"},
	}
	for _, values := range cases {
		if _, _, err := dhcpPoolToUCI(values[0], values[1], "192.168.3.1", "255.255.255.0", "192.168.3.1"); err == nil {
			t.Errorf("accepted unsafe pool %q-%q", values[0], values[1])
		}
	}
	if _, _, err := dhcpPoolToUCI("192.168.3.10", "192.168.3.20", "192.168.3.1", "255.255.255.0", "192.168.4.1"); err == nil {
		t.Error("accepted router outside the DHCP subnet")
	}
	if _, _, err := dhcpPoolToUCI("192.168.3.10", "192.168.3.20", "192.168.3.1", "255.255.255.0", "192.168.3.15"); err == nil {
		t.Error("accepted pool containing the router")
	}
	if _, _, ok := dhcpPoolRange("192.168.3.1", "255.255.255.0", "254", "2"); ok {
		t.Error("accepted pool containing broadcast")
	}
}

func TestDHCPLeasetimeValidation(t *testing.T) {
	for _, value := range []string{"1", "12h", "30m", "1d", "infinite"} {
		if !validDHCPLeasetime(value) {
			t.Errorf("validDHCPLeasetime(%q) = false", value)
		}
	}
	for _, value := range []string{"", "0", "0s", "12x", "12 h", "12\n"} {
		if validDHCPLeasetime(value) {
			t.Errorf("validDHCPLeasetime(%q) = true", value)
		}
	}
}

func TestNetdevRoleDoesNotTreatUSBEthernetAsCellular(t *testing.T) {
	if got := netdevRole("usb0", "none", "br-lan", map[string]bool{"ccmni0": true}, true); got != "standalone" {
		t.Fatalf("usb Ethernet role = %q", got)
	}
	if got := netdevRole("ccmni0", "none", "br-lan", map[string]bool{"ccmni0": true}, true); got != "cellular" {
		t.Fatalf("cellular role = %q", got)
	}
	if got := netdevRole("ccmni0", "none", "br-lan", map[string]bool{}, false); got != "standalone" {
		t.Fatalf("untrusted cellular-looking role = %q", got)
	}
}
