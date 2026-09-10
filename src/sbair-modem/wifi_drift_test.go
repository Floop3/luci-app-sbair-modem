// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Floop3

package main

import (
	"os"
	"strings"
	"testing"
	"time"
)

func TestParseIWDevRuntimeFixture(t *testing.T) {
	r := parseIWDev("phy#0\n\tInterface rax0\n\t\taddr 02:00:00:00:00:06\n\t\ttype AP\n\t\tchannel 5 (5975 MHz), width: 160 MHz, center1: 6055 MHz\n")
	got := r["rax0"]
	if got.Channel != "5" || got.Width != "160" || got.PrimaryFreq != "5975" || got.CenterFreq != "6055" {
		t.Fatalf("runtime = %+v", got)
	}
	if got.MAC != "02:00:00:00:00:06" {
		t.Fatalf("MAC = %q", got.MAC)
	}
}

func TestDriftPolicyDoesNotFlagACS(t *testing.T) {
	base := driftSnapshot{Bands: map[string]driftBand{"6G": {
		Band: "6G", Enabled: "on", ChannelPolicy: "auto", ConfiguredChannel: "auto",
		BandwidthPolicy: "fixed", ConfiguredBandwidth: "160", Runtime: driftRuntime{Channel: "5", Width: "160"},
	}}}
	current := base
	current.Bands = map[string]driftBand{"6G": base.Bands["6G"]}
	band := current.Bands["6G"]
	band.Runtime.Channel = "21"
	current.Bands["6G"] = band
	status, diffs := driftStatus(&driftBaseline{Snapshot: base}, current)
	if status != "ok" || len(diffs) != 0 {
		t.Fatalf("ACS channel was treated as drift: status=%s diffs=%+v", status, diffs)
	}
}

func TestDriftClassifiesPersistentAndRuntimeChanges(t *testing.T) {
	base := driftSnapshot{
		Files: map[string]driftFile{
			"/etc/config/wireless": {Path: "/etc/config/wireless", Hash: "uci-old"},
			"/tmp/radio.dat":       {Path: "/tmp/radio.dat", Hash: "vendor-old"},
		},
		Bands: map[string]driftBand{"5G": {
			Band: "5G", Enabled: "on", Protocol: "ax", ChannelPolicy: "fixed", ConfiguredChannel: "36",
			BandwidthPolicy: "fixed", ConfiguredBandwidth: "160", Runtime: driftRuntime{Channel: "36", Width: "160"},
		}},
	}
	current := base
	current.Files = map[string]driftFile{
		"/etc/config/wireless": {Path: "/etc/config/wireless", Hash: "uci-new"},
		"/tmp/radio.dat":       {Path: "/tmp/radio.dat", Hash: "vendor-new"},
	}
	current.Bands = map[string]driftBand{"5G": base.Bands["5G"]}
	band := current.Bands["5G"]
	band.Runtime.Channel = "40"
	current.Bands["5G"] = band
	status, diffs := driftStatus(&driftBaseline{Snapshot: base}, current)
	if status != "runtime_drift" || len(diffs) < 3 {
		t.Fatalf("persistent/runtime changes = status %s diffs %+v", status, diffs)
	}
	var uci, vendor, runtime bool
	for _, diff := range diffs {
		uci = uci || diff.Layer == "UCI"
		vendor = vendor || diff.Layer == "Vendor persistent"
		runtime = runtime || diff.Layer == "Runtime"
	}
	if !uci || !vendor || !runtime {
		t.Fatalf("layers not separated: %+v", diffs)
	}
}

func TestDriftPolicyChangeIsPersistentDrift(t *testing.T) {
	base := driftSnapshot{Bands: map[string]driftBand{"6G": {
		Band: "6G", Enabled: "on", ChannelPolicy: "auto", ConfiguredChannel: "auto",
		BandwidthPolicy: "fixed", ConfiguredBandwidth: "160", Runtime: driftRuntime{Channel: "5", Width: "160"},
	}}}
	current := base
	current.Bands = map[string]driftBand{"6G": base.Bands["6G"]}
	band := current.Bands["6G"]
	band.ChannelPolicy = "fixed"
	band.ConfiguredChannel = "1"
	current.Bands["6G"] = band
	status, diffs := driftStatus(&driftBaseline{Snapshot: base}, current)
	if status != "config_drift" || len(diffs) == 0 {
		t.Fatalf("policy change = status %s diffs %+v", status, diffs)
	}
}

func TestZeroHostapdBSSIDIsNotDrift(t *testing.T) {
	base := driftSnapshot{Bands: map[string]driftBand{"5G": {
		Band: "5G", Enabled: "on", ChannelPolicy: "fixed", ConfiguredChannel: "36",
		BandwidthPolicy: "fixed", ConfiguredBandwidth: "160", Runtime: driftRuntime{
			Channel: "36", Width: "160", Hostapd: driftHostapd{BSSID: "02:00:00:00:00:05"},
		},
	}}}
	current := base
	current.Bands = map[string]driftBand{"5G": base.Bands["5G"]}
	band := current.Bands["5G"]
	band.Runtime.Hostapd.BSSID = "00:00:00:00:00:00"
	current.Bands["5G"] = band
	status, diffs := driftStatus(&driftBaseline{Snapshot: base}, current)
	if status != "ok" || len(diffs) != 0 {
		t.Fatalf("zero BSSID was treated as drift: status=%s diffs=%+v", status, diffs)
	}
}

func TestSixGAttentionUsesRuntimePresenceAndExplicitDisabledState(t *testing.T) {
	base := driftSnapshot{Bands: map[string]driftBand{"6G": {
		Band: "6G", Enabled: "on", Runtime: driftRuntime{
			Present: true, Interface: "rax0", Channel: "5", Width: "160",
			Hostapd:       driftHostapd{State: "ENABLED", BSSID: "00:00:00:00:00:00", Airtime: "0"},
			IwinfoTxPower: "0", AssociationCount: "0",
		},
	}}}
	if sixGAttention(base) {
		t.Fatal("valid runtime with zero-valued secondary counters was flagged")
	}

	missing := base
	missing.Bands = map[string]driftBand{"6G": base.Bands["6G"]}
	band := missing.Bands["6G"]
	band.Runtime = driftRuntime{}
	missing.Bands["6G"] = band
	if !sixGAttention(missing) {
		t.Fatal("missing 6G runtime was not flagged")
	}

	disabled := base
	disabled.Bands = map[string]driftBand{"6G": base.Bands["6G"]}
	band = disabled.Bands["6G"]
	band.Runtime.Hostapd.State = "DISABLED"
	disabled.Bands["6G"] = band
	if !sixGAttention(disabled) {
		t.Fatal("explicit hostapd DISABLED state was not flagged")
	}
}

func TestDriftRestartLegacyStateDoesNotStayBusy(t *testing.T) {
	if driftRestartRunning(&driftRestartState{State: "running", StartedAt: "invalid"}) {
		t.Fatal("invalid legacy restart state stayed busy")
	}
	if driftRestartRunning(&driftRestartState{State: "running", StartedAt: time.Now().Add(-driftRestartStaleAfter - time.Second).Format(time.RFC3339)}) {
		t.Fatal("stale legacy restart state stayed busy")
	}
	if driftRestartRunning(&driftRestartState{State: "running", PID: os.Getpid(), StartedAt: time.Now().Add(-driftRestartStaleAfter - time.Second).Format(time.RFC3339)}) {
		t.Fatal("stale PID-bearing restart state stayed busy")
	}
}

func TestSanitizeDiagnosticNeverKeepsSecrets(t *testing.T) {
	input := "password=\"my secret password\"\n" +
		"psk='secret with spaces'\n" +
		"ssid=\"My Home WiFi\"\n" +
		"key = value with spaces\n" +
		"export PASSWORD='shell-secret'\n" +
		`{"password":"json-secret"}` + "\n" +
		"https://example.invalid/?token=query-secret\n" +
		"activation_code=confirmation-secret"
	got := sanitizeDiagnostic(input)
	for _, secret := range []string{"my secret password", "secret with spaces", "My Home WiFi", "value with spaces", "shell-secret", "json-secret", "query-secret", "confirmation-secret"} {
		if strings.Contains(got, secret) {
			t.Fatalf("secret leaked in %q", got)
		}
	}
	if !strings.Contains(got, "<redacted diagnostic line>") || !strings.Contains(got, "<masked diagnostic line>") {
		t.Fatalf("redaction markers missing: %q", got)
	}
}
