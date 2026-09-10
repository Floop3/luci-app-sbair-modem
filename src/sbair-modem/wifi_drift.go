// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Floop3

package main

// Wi-Fi configuration drift monitor. This file is deliberately read-only
// during normal operation: it observes persistent layers and runtime state,
// but never repairs Wi-Fi, calls knsh save, or restarts WLAN.

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"syscall"
	"time"
)

const (
	driftMaxLog            = 512 * 1024
	driftLogTail           = 48 * 1024
	driftDefaultLua        = "/lib/wifi/mtwifi.lua"
	driftDefaultDir        = "/var/run/sbair/wifi-drift"
	driftDefaultGood       = "/etc/sbair/wifi-drift-baseline.json"
	driftRestartDelay      = 5 * time.Second
	driftRestartStaleAfter = 10 * time.Minute
)

type driftFile struct {
	Path  string `json:"path"`
	Hash  string `json:"sha256"`
	MTime int64  `json:"mtime"`
	Size  int64  `json:"size"`
}

type driftHostapd struct {
	Available bool   `json:"available"`
	State     string `json:"state,omitempty"`
	Protocol  string `json:"protocol,omitempty"`
	Frequency string `json:"frequency,omitempty"`
	Channel   string `json:"channel,omitempty"`
	BSSID     string `json:"bssid,omitempty"`
	Airtime   string `json:"airtime,omitempty"`
}

type driftRuntime struct {
	Present          bool         `json:"present"`
	Interface        string       `json:"interface,omitempty"`
	Channel          string       `json:"channel,omitempty"`
	Width            string       `json:"width,omitempty"`
	PrimaryFreq      string       `json:"primary_frequency,omitempty"`
	CenterFreq       string       `json:"center_frequency,omitempty"`
	MAC              string       `json:"mac,omitempty"`
	Hostapd          driftHostapd `json:"hostapd"`
	IwinfoTxPower    string       `json:"iwinfo_tx_power,omitempty"`
	BeaconCounter    string       `json:"beacon_counter,omitempty"`
	AssociationCount string       `json:"association_count,omitempty"`
}

type driftBand struct {
	Band                string       `json:"band"`
	Radio               string       `json:"radio,omitempty"`
	APInterface         string       `json:"ap_interface,omitempty"`
	Enabled             string       `json:"enabled"`
	Protocol            string       `json:"protocol,omitempty"`
	HTMode              string       `json:"htmode,omitempty"`
	ChannelPolicy       string       `json:"channel_policy"`
	ConfiguredChannel   string       `json:"configured_channel"`
	BandwidthPolicy     string       `json:"bandwidth_policy"`
	ConfiguredBandwidth string       `json:"configured_bandwidth"`
	Runtime             driftRuntime `json:"runtime"`
}

type driftSnapshot struct {
	Timestamp       string               `json:"timestamp"`
	UptimeSec       int64                `json:"uptime_sec"`
	Files           map[string]driftFile `json:"files"`
	Bands           map[string]driftBand `json:"bands"`
	Features        map[string]string    `json:"features"`
	VendorDiscovery string               `json:"vendor_discovery"`
}

type driftBaseline struct {
	RecordedAt string        `json:"recorded_at"`
	Snapshot   driftSnapshot `json:"snapshot"`
}

type driftDifference struct {
	Layer     string `json:"layer"`
	Band      string `json:"band,omitempty"`
	Field     string `json:"field"`
	Old       string `json:"old"`
	New       string `json:"new"`
	UptimeSec int64  `json:"uptime_sec"`
}

type driftEvent struct {
	Timestamp string            `json:"timestamp"`
	Event     string            `json:"event"`
	UptimeSec int64             `json:"uptime_sec"`
	Changes   []driftDifference `json:"changes"`
}

type driftRestartState struct {
	ID               string            `json:"id"`
	State            string            `json:"state"`
	PID              int               `json:"pid,omitempty"`
	StartedAt        string            `json:"started_at"`
	CompletedAt      string            `json:"completed_at,omitempty"`
	CommandSucceeded bool              `json:"command_succeeded"`
	Error            string            `json:"error,omitempty"`
	Before           driftSnapshot     `json:"before"`
	After            *driftSnapshot    `json:"after,omitempty"`
	Differences      []driftDifference `json:"differences,omitempty"`
}

var (
	iwInterfaceRe         = regexp.MustCompile(`^\s*Interface\s+(\S+)`)
	iwAddrRe              = regexp.MustCompile(`^\s*addr\s+([0-9A-Fa-f:]{17})`)
	iwTypeRe              = regexp.MustCompile(`^\s*type\s+(\S+)`)
	iwChannelRe           = regexp.MustCompile(`channel\s+([0-9]+)\s+\(([0-9]+)\s+MHz\)(?:,\s*width:\s*([^,]+))?(?:,\s*center1:\s*([0-9]+)\s+MHz)?`)
	macAddressRe          = regexp.MustCompile(`(?i)(?:^|\s)([0-9a-f]{2}(?::[0-9a-f]{2}){5})(?:\s|$)`)
	hostapdKVRe           = regexp.MustCompile(`^([A-Za-z0-9_]+)=(.*)$`)
	datPathRe             = regexp.MustCompile(`(?:["'])(/[^"']+\.dat)(?:["'])`)
	diagnosticSecretKeyRe = regexp.MustCompile(`(?i)(^|[^[:alnum:]_])(key|password|passphrase|psk|wpa[_-]?psk|wps[_-]?pin|secret|token|activation[_-]?code|confirmation[_-]?code)([^[:alnum:]_]|$)`)
	diagnosticSSIDKeyRe   = regexp.MustCompile(`(?i)(^|[^[:alnum:]_])ssid([^[:alnum:]_]|$)`)
	beaconRe              = regexp.MustCompile(`(?i)beacon[^0-9]*([0-9]+)`)
)

func driftDir() string {
	if v := os.Getenv("SBAIR_WIFI_DRIFT_DIR"); v != "" {
		return v
	}
	return driftDefaultDir
}

func driftGoodPath() string {
	if v := os.Getenv("SBAIR_WIFI_DRIFT_BASELINE"); v != "" {
		return v
	}
	return driftDefaultGood
}

func driftLuaPath() string {
	if v := os.Getenv("SBAIR_MTWIFI_LUA"); v != "" {
		return v
	}
	return driftDefaultLua
}

func driftUCIFile(name string) string {
	if dir := os.Getenv("SBAIR_WIFI_DRIFT_UCI_DIR"); dir != "" {
		return filepath.Join(dir, name)
	}
	return filepath.Join("/etc/config", name)
}

func driftBeaconPath() string {
	if path := os.Getenv("SBAIR_WIFI_DRIFT_BEACON"); path != "" {
		return path
	}
	return "/sys/kernel/knos/wlan/bcn_info"
}

func driftLastPath() string    { return filepath.Join(driftDir(), "last.json") }
func driftEventPath() string   { return filepath.Join(driftDir(), "last-event.json") }
func driftRestartPath() string { return filepath.Join(driftDir(), "restart-test.json") }
func driftLockPath() string    { return filepath.Join(driftDir(), ".lock") }
func driftLogPath() string     { return filepath.Join(driftDir(), "events.jsonl") }

func withDriftLock(fn func() error) error {
	if err := ensurePrivateDir(driftDir()); err != nil {
		return err
	}
	f, err := secureRuntimePath(driftLockPath(), 0600)
	if err != nil {
		return err
	}
	defer f.Close()
	if err := syscall.Flock(int(f.Fd()), syscall.LOCK_EX); err != nil {
		return err
	}
	defer syscall.Flock(int(f.Fd()), syscall.LOCK_UN)
	return fn()
}

func driftWriteJSON(path string, value any, mode os.FileMode) error {
	b, err := json.MarshalIndent(value, "", "  ")
	if err != nil {
		return err
	}
	if err := ensurePrivateDir(filepath.Dir(path)); err != nil {
		return err
	}
	return atomicWritePrivate(path, append(b, '\n'), mode)
}

func driftReadJSON(path string, value any) error {
	if info, err := os.Lstat(path); err != nil {
		return err
	} else if info.Mode()&os.ModeSymlink != 0 || !info.Mode().IsRegular() {
		return fmt.Errorf("drift file %s is not a regular file", path)
	}
	b, err := os.ReadFile(path)
	if err != nil {
		return err
	}
	return json.Unmarshal(b, value)
}

func driftUptime() int64 {
	b, err := os.ReadFile("/proc/uptime")
	if err != nil {
		return 0
	}
	fields := strings.Fields(string(b))
	if len(fields) == 0 {
		return 0
	}
	seconds, _ := strconv.ParseFloat(fields[0], 64)
	return int64(seconds)
}

func driftFileInfo(path string) (driftFile, bool) {
	info, err := os.Stat(path)
	if err != nil || !info.Mode().IsRegular() {
		return driftFile{}, false
	}
	f, err := os.Open(path)
	if err != nil {
		return driftFile{}, false
	}
	h := sha256.New()
	_, copyErr := io.Copy(h, f)
	_ = f.Close()
	if copyErr != nil {
		return driftFile{}, false
	}
	return driftFile{Path: path, Hash: hex.EncodeToString(h.Sum(nil)), MTime: info.ModTime().Unix(), Size: info.Size()}, true
}

func canonicalDriftBand(value string) string {
	switch strings.ToLower(strings.TrimSpace(value)) {
	case "2.4g", "2.4ghz", "2g", "g2":
		return "2.4G"
	case "5g", "5ghz", "g5":
		return "5G"
	case "6g", "6ghz", "g6":
		return "6G"
	default:
		return ""
	}
}

func driftPolicy(value string) string {
	switch strings.ToLower(strings.TrimSpace(value)) {
	case "", "0", "auto", "automatic":
		return "auto"
	default:
		return "fixed"
	}
}

func driftChannel(value string) string {
	if driftPolicy(value) == "auto" {
		return "auto"
	}
	return strings.TrimSpace(value)
}

func driftWidth(htmode string) string {
	if driftPolicy(htmode) == "auto" {
		return "auto"
	}
	return htmodeWidth(htmode)
}

func driftFlag(value string) string {
	switch strings.ToLower(strings.TrimSpace(value)) {
	case "1", "true", "on", "enabled":
		return "on"
	case "0", "false", "off", "disabled":
		return "off"
	default:
		return "unknown"
	}
}

func driftConfigBands(sections map[string]map[string]string, order []string) map[string]driftBand {
	var out = map[string]driftBand{}
	for _, name := range order {
		f := sections[name]
		band := canonicalDriftBand(f["band"])
		if band == "" {
			continue
		}
		b := driftBand{
			Band: band, Radio: name, Enabled: "on", HTMode: f["htmode"],
			ChannelPolicy: driftPolicy(f["channel"]), ConfiguredChannel: driftChannel(f["channel"]),
			BandwidthPolicy: driftPolicy(f["htmode"]), ConfiguredBandwidth: driftWidth(f["htmode"]),
			Protocol: protocolValueFromHtmode(band, f["htmode"], f["pure_11b"]),
		}
		if f["disabled"] == "1" {
			b.Enabled = "off"
		}
		for _, iface := range order {
			g := sections[iface]
			if strings.HasPrefix(iface, "apmld") ||
				(g["ssid"] != "" && g["ssid"] == g["multi_ap_backhaul_ssid"]) {
				continue
			}
			if g["mode"] == "ap" && g["device"] == name {
				b.APInterface = iface
				if g["disabled"] == "1" {
					b.Enabled = "off"
				}
				break
			}
		}
		out[band] = b
	}
	return out
}

func driftFeatures(sections map[string]map[string]string) map[string]string {
	features := map[string]string{}
	wlan, _ := uci("get", "knos.network.wlan_enabled")
	features["wifi_enabled"] = "on"
	if wlan != "" {
		features["wifi_enabled"] = driftFlag(wlan)
	}
	bandsteering, _ := uci("get", "knos.network.bandsteering")
	if bandsteering == "" {
		// Read-only vendor query; never use its output as a write command.
		if out, err := knshOutput("wlan", "bandsteering"); err == nil {
			if m := modeDigitRe.FindStringSubmatch(out); len(m) > 1 {
				bandsteering = m[1]
			}
		}
	}
	features["bandsteering"] = driftFlag(bandsteering)
	mlo := sections["apmld1"]
	if mlo != nil {
		features["mlo"] = "on"
		if mlo["disabled"] == "1" || mlo["mode"] != "ap" {
			features["mlo"] = "off"
		}
	} else {
		mloValue, _ := uci("get", "knos.network.mlo")
		features["mlo"] = driftFlag(mloValue)
	}
	for _, key := range []string{"mesh", "easymesh", "mesh_enabled"} {
		if v, _ := uci("get", "knos.network."+key); v != "" {
			features["mesh"] = driftFlag(v)
			break
		}
	}
	if features["mesh"] == "" {
		features["mesh"] = "unknown"
	}
	return features
}

func discoverVendorFiles() ([]string, string) {
	b, err := os.ReadFile(driftLuaPath())
	if err != nil {
		return nil, "mtwifi.lua unavailable"
	}
	seen := map[string]bool{}
	var paths []string
	for _, m := range datPathRe.FindAllStringSubmatch(string(b), -1) {
		path := m[1]
		if strings.ContainsAny(path, "$%{}") { // unresolved script variable
			continue
		}
		if _, ok := driftFileInfo(path); ok && !seen[path] {
			seen[path] = true
			paths = append(paths, path)
		}
	}
	sort.Strings(paths)
	if len(paths) == 0 {
		return nil, "mtwifi.lua contained no existing .dat path"
	}
	return paths, "mtwifi.lua"
}

func parseIWDev(raw string) map[string]driftRuntime {
	type parsed struct {
		driftRuntime
		typeName string
	}
	out := map[string]parsed{}
	var current string
	for _, line := range strings.Split(raw, "\n") {
		if m := iwInterfaceRe.FindStringSubmatch(line); len(m) > 1 {
			current = m[1]
			out[current] = parsed{driftRuntime: driftRuntime{Interface: current}}
			continue
		}
		p, ok := out[current]
		if !ok {
			continue
		}
		if m := iwAddrRe.FindStringSubmatch(line); len(m) > 1 {
			p.MAC = strings.ToLower(m[1])
		}
		if m := iwTypeRe.FindStringSubmatch(line); len(m) > 1 {
			p.typeName = m[1]
		}
		if m := iwChannelRe.FindStringSubmatch(line); len(m) > 2 {
			p.Channel, p.PrimaryFreq = m[1], m[2]
			if len(m) > 3 {
				p.Width = strings.TrimSpace(strings.TrimSuffix(m[3], "MHz"))
			}
			if len(m) > 4 {
				p.CenterFreq = m[4]
			}
		}
		out[current] = p
	}
	result := map[string]driftRuntime{}
	for name, p := range out {
		if p.typeName == "" || p.typeName == "AP" {
			result[name] = p.driftRuntime
		}
	}
	return result
}

func readHostapd(iface string) driftHostapd {
	if iface == "" {
		return driftHostapd{}
	}
	out, err := exec.Command("hostapd_cli", "-i", iface, "get_status").Output()
	if err != nil {
		return driftHostapd{}
	}
	h := driftHostapd{Available: true}
	for _, line := range strings.Split(string(out), "\n") {
		m := hostapdKVRe.FindStringSubmatch(strings.TrimSpace(line))
		if len(m) < 3 {
			continue
		}
		switch m[1] {
		case "state":
			h.State = m[2]
		case "ieee80211n":
			if m[2] == "1" {
				h.Protocol = "n"
			}
		case "ieee80211ac":
			if m[2] == "1" {
				h.Protocol = "ac"
			}
		case "ieee80211ax":
			if m[2] == "1" {
				h.Protocol = "ax"
			}
		case "ieee80211be":
			if m[2] == "1" {
				h.Protocol = "be"
			}
		case "freq":
			h.Frequency = m[2]
		case "channel":
			h.Channel = m[2]
		case "bssid":
			h.BSSID = strings.ToLower(m[2])
		case "airtime":
			h.Airtime = m[2]
		}
	}
	return h
}

func readIwinfoPower(iface string) string {
	if iface == "" {
		return ""
	}
	out, err := exec.Command("iwinfo", iface, "info").Output()
	if err != nil {
		return ""
	}
	for _, line := range strings.Split(string(out), "\n") {
		if i := strings.Index(line, "Tx-Power:"); i >= 0 {
			fields := strings.Fields(line[i+len("Tx-Power:"):])
			if len(fields) > 0 {
				return fields[0]
			}
		}
	}
	return ""
}

func readAssociationCount(iface string) string {
	if iface == "" {
		return ""
	}
	out, err := exec.Command("iwinfo", iface, "assoclist").Output()
	if err != nil {
		return ""
	}
	count := 0
	for _, line := range strings.Split(string(out), "\n") {
		if macAddressRe.MatchString(line) {
			count++
		}
	}
	return strconv.Itoa(count)
}

func readBeaconCounter() string {
	b, err := os.ReadFile(driftBeaconPath())
	if err != nil {
		return ""
	}
	if m := beaconRe.FindStringSubmatch(string(b)); len(m) > 1 {
		return m[1]
	}
	return ""
}

func collectRuntime(bands map[string]driftBand) {
	raw, _ := exec.Command("iw", "dev").Output()
	runtime := parseIWDev(string(raw))
	beacon := readBeaconCounter()
	for band, value := range bands {
		found := false
		if value.APInterface != "" {
			if candidate, ok := runtime[value.APInterface]; ok {
				value.Runtime = candidate
				found = true
			}
		} else {
			for _, candidate := range runtime {
				if candidate.PrimaryFreq != "" && canonicalFreqBand(candidate.PrimaryFreq) == band {
					value.Runtime = candidate
					found = true
					break
				}
			}
		}
		if !found {
			// Do not substitute the configured AP interface here: that would make
			// a vanished runtime interface look present to health checks.
			value.Runtime = driftRuntime{}
			bands[band] = value
			continue
		}
		value.Runtime.Present = true
		value.Runtime.Hostapd = readHostapd(value.Runtime.Interface)
		if value.Runtime.Channel == "" {
			value.Runtime.Channel = value.Runtime.Hostapd.Channel
		}
		if value.Runtime.PrimaryFreq == "" {
			value.Runtime.PrimaryFreq = value.Runtime.Hostapd.Frequency
		}
		value.Runtime.IwinfoTxPower = readIwinfoPower(value.APInterface)
		value.Runtime.BeaconCounter = beacon
		value.Runtime.AssociationCount = readAssociationCount(value.APInterface)
		bands[band] = value
	}
}

func canonicalFreqBand(freq string) string {
	n, err := strconv.Atoi(strings.TrimSpace(freq))
	if err != nil {
		return ""
	}
	switch {
	case n >= 2300 && n < 2500:
		return "2.4G"
	case n >= 4900 && n < 5925:
		return "5G"
	case n >= 5925 && n < 7200:
		return "6G"
	default:
		return ""
	}
}

func collectDriftSnapshot() (driftSnapshot, error) {
	sections, order, err := parseWireless()
	if err != nil {
		return driftSnapshot{}, fmt.Errorf("wireless UCI: %v", err)
	}
	files := map[string]driftFile{}
	for _, path := range []string{driftUCIFile("wireless"), driftUCIFile("knos")} {
		if f, ok := driftFileInfo(path); ok {
			files[path] = f
		}
	}
	vendorPaths, discovery := discoverVendorFiles()
	for _, path := range vendorPaths {
		if f, ok := driftFileInfo(path); ok {
			files[path] = f
		}
	}
	bands := driftConfigBands(sections, order)
	collectRuntime(bands)
	return driftSnapshot{
		Timestamp: time.Now().Format(time.RFC3339), UptimeSec: driftUptime(),
		Files: files, Bands: bands, Features: driftFeatures(sections), VendorDiscovery: discovery,
	}, nil
}

func driftValue(value string) string {
	if value == "" {
		return "unknown"
	}
	return value
}

func unusableBSSID(value string) bool {
	value = strings.ToLower(strings.ReplaceAll(strings.TrimSpace(value), ":", ""))
	return value == "" || value == "unknown" || value == "000000000000"
}

func addDriftDifference(out *[]driftDifference, layer, band, field, oldValue, newValue string, uptime int64) {
	if oldValue == newValue {
		return
	}
	*out = append(*out, driftDifference{Layer: layer, Band: band, Field: field, Old: driftValue(oldValue), New: driftValue(newValue), UptimeSec: uptime})
}

func snapshotDifferences(old, current driftSnapshot) []driftDifference {
	var out []driftDifference
	paths := map[string]bool{}
	for path := range old.Files {
		paths[path] = true
	}
	for path := range current.Files {
		paths[path] = true
	}
	for path := range paths {
		a, b := old.Files[path], current.Files[path]
		layer := "Vendor persistent"
		if path == driftUCIFile("wireless") || path == driftUCIFile("knos") {
			layer = "UCI"
		}
		addDriftDifference(&out, layer, "", path+":sha256", a.Hash, b.Hash, current.UptimeSec)
		if a.Hash == b.Hash {
			addDriftDifference(&out, layer, "", path+":mtime", strconv.FormatInt(a.MTime, 10), strconv.FormatInt(b.MTime, 10), current.UptimeSec)
		}
		addDriftDifference(&out, layer, "", path+":size", strconv.FormatInt(a.Size, 10), strconv.FormatInt(b.Size, 10), current.UptimeSec)
	}

	bands := map[string]bool{}
	for band := range old.Bands {
		bands[band] = true
	}
	for band := range current.Bands {
		bands[band] = true
	}
	bandNames := make([]string, 0, len(bands))
	for band := range bands {
		bandNames = append(bandNames, band)
	}
	sort.Strings(bandNames)
	for _, band := range bandNames {
		a, b := old.Bands[band], current.Bands[band]
		for _, field := range []struct {
			name string
			old  string
			new  string
		}{
			{"radio", a.Radio, b.Radio}, {"ap_interface", a.APInterface, b.APInterface},
			{"enabled", a.Enabled, b.Enabled}, {"protocol", a.Protocol, b.Protocol},
			{"htmode", a.HTMode, b.HTMode}, {"channel_policy", a.ChannelPolicy, b.ChannelPolicy},
			{"configured_channel", a.ConfiguredChannel, b.ConfiguredChannel},
			{"bandwidth_policy", a.BandwidthPolicy, b.BandwidthPolicy},
			{"configured_bandwidth", a.ConfiguredBandwidth, b.ConfiguredBandwidth},
			{"runtime_channel", a.Runtime.Channel, b.Runtime.Channel},
			{"runtime_width", a.Runtime.Width, b.Runtime.Width},
			{"primary_frequency", a.Runtime.PrimaryFreq, b.Runtime.PrimaryFreq},
			{"center_frequency", a.Runtime.CenterFreq, b.Runtime.CenterFreq},
			{"runtime_mac", a.Runtime.MAC, b.Runtime.MAC},
			{"hostapd_state", a.Runtime.Hostapd.State, b.Runtime.Hostapd.State},
			{"hostapd_protocol", a.Runtime.Hostapd.Protocol, b.Runtime.Hostapd.Protocol},
			{"hostapd_frequency", a.Runtime.Hostapd.Frequency, b.Runtime.Hostapd.Frequency},
			{"hostapd_bssid", a.Runtime.Hostapd.BSSID, b.Runtime.Hostapd.BSSID},
			{"airtime", a.Runtime.Hostapd.Airtime, b.Runtime.Hostapd.Airtime},
			{"iwinfo_tx_power", a.Runtime.IwinfoTxPower, b.Runtime.IwinfoTxPower},
			{"beacon_counter", a.Runtime.BeaconCounter, b.Runtime.BeaconCounter},
			{"association_count", a.Runtime.AssociationCount, b.Runtime.AssociationCount},
		} {
			layer := "UCI"
			if strings.HasPrefix(field.name, "runtime_") || field.name == "primary_frequency" || field.name == "center_frequency" || field.name == "hostapd_state" || field.name == "hostapd_protocol" || field.name == "hostapd_frequency" || field.name == "hostapd_bssid" || field.name == "airtime" || field.name == "iwinfo_tx_power" || field.name == "beacon_counter" || field.name == "association_count" {
				layer = "Runtime"
			}
			addDriftDifference(&out, layer, band, field.name, field.old, field.new, current.UptimeSec)
		}
	}
	for _, key := range []string{"wifi_enabled", "mlo", "bandsteering", "mesh"} {
		addDriftDifference(&out, "Vendor feature state", "", key, old.Features[key], current.Features[key], current.UptimeSec)
	}
	return out
}

func baselineDifferences(base, current driftSnapshot) []driftDifference {
	all := snapshotDifferences(base, current)
	var out []driftDifference
	for _, diff := range all {
		if diff.Layer != "Runtime" || diff.Band == "" {
			out = append(out, diff)
			continue
		}
		b := base.Bands[diff.Band]
		if (diff.Field == "runtime_channel" || diff.Field == "primary_frequency" || diff.Field == "center_frequency") && b.ChannelPolicy == "auto" {
			continue
		}
		if diff.Field == "runtime_width" && b.BandwidthPolicy == "auto" {
			continue
		}
		if diff.Field == "hostapd_bssid" && (unusableBSSID(diff.Old) || unusableBSSID(diff.New)) {
			continue
		}
		if diff.Field == "association_count" {
			continue
		}
		if diff.Field == "hostapd_state" || diff.Field == "hostapd_protocol" || diff.Field == "hostapd_frequency" || diff.Field == "airtime" || diff.Field == "iwinfo_tx_power" || diff.Field == "beacon_counter" {
			continue
		}
		out = append(out, diff)
	}
	return out
}

func sixGAttention(snapshot driftSnapshot) bool {
	b, ok := snapshot.Bands["6G"]
	if !ok || b.Enabled != "on" {
		return false
	}
	runtimePresent := b.Runtime.Present || b.Runtime.Interface != "" || b.Runtime.Channel != "" || b.Runtime.Width != ""
	if !runtimePresent || b.Runtime.Channel == "" || b.Runtime.Width == "" {
		return true
	}
	return strings.EqualFold(b.Runtime.Hostapd.State, "DISABLED")
}

func driftStatus(base *driftBaseline, current driftSnapshot) (string, []driftDifference) {
	if base == nil {
		return "no_baseline", nil
	}
	diffs := baselineDifferences(base.Snapshot, current)
	if sixGAttention(current) {
		return "6g_attention", diffs
	}
	for _, diff := range diffs {
		if diff.Layer == "Runtime" {
			return "runtime_drift", diffs
		}
	}
	if len(diffs) > 0 {
		return "config_drift", diffs
	}
	return "ok", diffs
}

func appendDriftEvent(event string, current driftSnapshot, changes []driftDifference) error {
	if len(changes) == 0 {
		return nil
	}
	record := driftEvent{Timestamp: current.Timestamp, Event: event, UptimeSec: current.UptimeSec, Changes: changes}
	b, err := json.Marshal(record)
	if err != nil {
		return err
	}
	f, err := openDriftAppend()
	if err != nil {
		return err
	}
	_, writeErr := f.Write(append(b, '\n'))
	_ = f.Close()
	if writeErr != nil {
		return writeErr
	}
	context := map[string]any{"type": "context", "timestamp": current.Timestamp, "event": event,
		"uptime_sec": current.UptimeSec, "logread": relevantLogread(), "processes": processSnapshot()}
	cb, _ := json.Marshal(context)
	if f, err = openDriftAppend(); err == nil {
		_, _ = f.Write(append(cb, '\n'))
		_ = f.Close()
	}
	if err := rotateDriftLog(); err != nil {
		return err
	}
	return driftWriteJSON(driftEventPath(), record, 0600)
}

func openDriftAppend() (*os.File, error) {
	probe, err := secureRuntimePath(driftLogPath(), 0600)
	if err != nil {
		return nil, err
	}
	if err := probe.Close(); err != nil {
		return nil, err
	}
	return os.OpenFile(driftLogPath(), os.O_WRONLY|os.O_APPEND|syscall.O_NOFOLLOW, 0600)
}

func rotateDriftLog() error {
	info, err := os.Stat(driftLogPath())
	if err != nil || info.Size() <= driftMaxLog {
		return nil
	}
	b, err := os.ReadFile(driftLogPath())
	if err != nil {
		return err
	}
	if len(b) > driftMaxLog/2 {
		b = b[len(b)-driftMaxLog/2:]
	}
	return atomicWritePrivate(driftLogPath(), b, 0600)
}

func sanitizeDiagnostic(value string) string {
	var lines []string
	for _, line := range strings.Split(value, "\n") {
		switch {
		case diagnosticSecretKeyRe.MatchString(line):
			// Drop the complete line instead of trying to guess where an
			// unquoted, JSON, shell, or query value ends.
			lines = append(lines, "<redacted diagnostic line>")
		case diagnosticSSIDKeyRe.MatchString(line):
			lines = append(lines, "<masked diagnostic line>")
		default:
			lines = append(lines, line)
		}
	}
	return strings.Join(lines, "\n")
}

func relevantLogread() string {
	out, err := exec.Command("logread").Output()
	if err != nil {
		return ""
	}
	keys := []string{"knsh", "wapp", "mapd", "1905", "mt_wifi", "mtk", "netifd", "firewall"}
	counts := make(map[string]int)
	for _, line := range strings.Split(string(out), "\n") {
		lower := strings.ToLower(line)
		for _, key := range keys {
			if strings.Contains(lower, key) {
				counts[key]++
				break
			}
		}
	}
	var components []string
	for _, key := range keys {
		if counts[key] > 0 {
			components = append(components, fmt.Sprintf("%s:%d", key, counts[key]))
		}
	}
	return strings.Join(components, " ")
}

func processSnapshot() string {
	out, err := exec.Command("ps", "-eo", "pid,comm").Output()
	if err != nil {
		out, _ = exec.Command("ps").Output()
	}
	var lines []string
	for _, line := range strings.Split(string(out), "\n") {
		fields := strings.Fields(line)
		if len(fields) >= 2 && fields[0] != "PID" {
			lines = append(lines, fields[0]+" "+sanitizeDiagnostic(fields[1]))
		}
	}
	if len(lines) > 80 {
		lines = lines[:80]
	}
	return strings.Join(lines, "\n")
}

func captureDriftSnapshot(event string, record bool) (driftSnapshot, []driftDifference, error) {
	var current driftSnapshot
	var changes []driftDifference
	err := withDriftLock(func() error {
		var err error
		current, err = collectDriftSnapshot()
		if err != nil {
			return err
		}
		var previous driftSnapshot
		if record && driftReadJSON(driftLastPath(), &previous) == nil {
			changes = snapshotDifferences(previous, current)
			if err := appendDriftEvent(event, current, changes); err != nil {
				return err
			}
		}
		if record {
			if err := driftWriteJSON(driftLastPath(), current, 0600); err != nil {
				return err
			}
		}
		return nil
	})
	return current, changes, err
}

func wifiDriftEnabled() bool {
	v, err := uci("get", "sbair.wifi_drift.enabled")
	return err == nil && v == "1"
}

func readDriftBaseline() *driftBaseline {
	var baseline driftBaseline
	if driftReadJSON(driftGoodPath(), &baseline) != nil || baseline.Snapshot.Timestamp == "" {
		return nil
	}
	return &baseline
}

func wifiDriftStatus() map[string]any {
	enabled := wifiDriftEnabled()
	current, changes, err := captureDriftSnapshot("poll", enabled)
	if err != nil {
		return map[string]any{"error": err.Error(), "monitor": map[string]any{"enabled": enabled, "mode": "monitor"}}
	}
	base := readDriftBaseline()
	state, diffs := driftStatus(base, current)
	last := driftEvent{}
	_ = driftReadJSON(driftEventPath(), &last)
	if len(changes) > 0 {
		last = driftEvent{Timestamp: current.Timestamp, Event: "poll", UptimeSec: current.UptimeSec, Changes: changes}
	}
	result := map[string]any{
		"monitor": map[string]any{"enabled": enabled, "mode": "monitor"},
		"status":  state, "current": current, "differences": diffs,
		"baseline_recorded_at": "", "last_change": last,
		"summary": map[string]any{"uci_hash_changed": false, "vendor_persistent_changed": false, "runtime_only_changed": false},
	}
	if base != nil {
		result["baseline_recorded_at"] = base.RecordedAt
	}
	uciHashChanged := false
	vendorChanged := false
	runtimeChanged := false
	for _, diff := range diffs {
		switch diff.Layer {
		case "UCI":
			if strings.HasSuffix(diff.Field, ":sha256") {
				uciHashChanged = true
			}
		case "Vendor persistent", "Vendor feature state":
			vendorChanged = true
		case "Runtime":
			runtimeChanged = true
		}
	}
	summary := result["summary"].(map[string]any)
	summary["uci_hash_changed"] = uciHashChanged
	summary["vendor_persistent_changed"] = vendorChanged
	summary["runtime_only_changed"] = runtimeChanged && !uciHashChanged && !vendorChanged
	if r := readDriftRestart(); r != nil {
		result["restart_test"] = r
	}
	return result
}

func wifiDriftSnapshot(event string) map[string]any {
	if !wifiDriftEnabled() {
		return map[string]any{"result": "disabled", "monitor": "off"}
	}
	snapshot, changes, err := captureDriftSnapshot(event, true)
	if err != nil {
		return map[string]any{"error": err.Error()}
	}
	return map[string]any{"result": "ok", "timestamp": snapshot.Timestamp, "changes": changes}
}

func wifiDriftMarkGood() map[string]any {
	snapshot, _, err := captureDriftSnapshot("baseline", false)
	if err != nil {
		return map[string]any{"error": err.Error()}
	}
	base := driftBaseline{RecordedAt: time.Now().Format(time.RFC3339), Snapshot: snapshot}
	if err := driftWriteJSON(driftGoodPath(), base, 0600); err != nil {
		return map[string]any{"error": fmt.Sprintf("baseline: %v", err)}
	}
	return map[string]any{"result": "ok", "recorded_at": base.RecordedAt}
}

func wifiDriftSet(enabled string) map[string]any {
	if enabled != "0" && enabled != "1" {
		return map[string]any{"error": "enabled must be 0 or 1"}
	}
	if err := ensureConfig(); err != nil {
		return map[string]any{"error": fmt.Sprintf("sbair config: %v", err)}
	}
	if _, err := uci("set", "sbair.wifi_drift=monitor"); err != nil {
		return map[string]any{"error": fmt.Sprintf("uci set wifi_drift: %v", err)}
	}
	if _, err := uci("set", "sbair.wifi_drift.enabled="+enabled); err != nil {
		return map[string]any{"error": fmt.Sprintf("uci set wifi_drift.enabled: %v", err)}
	}
	if _, err := uci("commit", "sbair"); err != nil {
		return map[string]any{"error": fmt.Sprintf("uci commit sbair: %v", err)}
	}
	action := "stop"
	if enabled == "1" {
		action = "start"
	}
	_ = exec.Command("/etc/init.d/sbair-wifidrift", action).Run()
	return map[string]any{"result": "ok", "enabled": enabled == "1"}
}

func wifiDriftLogs() map[string]any {
	b, err := os.ReadFile(driftLogPath())
	if err != nil && !os.IsNotExist(err) {
		return map[string]any{"error": err.Error()}
	}
	if len(b) > driftLogTail {
		b = b[len(b)-driftLogTail:]
	}
	return map[string]any{"result": "ok", "log": sanitizeDiagnostic(string(b))}
}

func wifiDriftSaveTest() map[string]any {
	before, _, err := captureDriftSnapshot("knsh_save_before", false)
	if err != nil {
		return map[string]any{"error": err.Error()}
	}
	cmdErr := exec.Command("knsh", "save").Run()
	after, _, afterErr := captureDriftSnapshot("knsh_save_after", false)
	if afterErr != nil {
		return map[string]any{"error": afterErr.Error(), "command_succeeded": cmdErr == nil}
	}
	diffs := snapshotDifferences(before, after)
	if wifiDriftEnabled() && len(diffs) > 0 {
		_ = withDriftLock(func() error { return appendDriftEvent("knsh_save_test", after, diffs) })
		_ = driftWriteJSON(driftLastPath(), after, 0600)
	}
	return map[string]any{"result": "ok", "command": "knsh save", "command_succeeded": cmdErr == nil,
		"restart_performed": false, "differences": diffs}
}

func readDriftRestart() *driftRestartState {
	var state driftRestartState
	if driftReadJSON(driftRestartPath(), &state) != nil || state.ID == "" {
		return nil
	}
	return &state
}

var errDriftRestartBusy = errors.New("wifi restart test already running")

func driftRestartProcessAlive(pid int) bool {
	if pid <= 0 {
		return false
	}
	err := syscall.Kill(pid, 0)
	return err == nil || errors.Is(err, syscall.EPERM)
}

func driftRestartRunning(state *driftRestartState) bool {
	if state == nil || state.State != "running" {
		return false
	}
	if state.PID > 0 {
		if !driftRestartProcessAlive(state.PID) {
			return false
		}
	}
	started, err := time.Parse(time.RFC3339, state.StartedAt)
	if err != nil {
		return false
	}
	age := time.Since(started)
	return age >= 0 && age < driftRestartStaleAfter
}

func wifiDriftRestartTest() map[string]any {
	var result map[string]any
	err := withDriftLock(func() error {
		if existing := readDriftRestart(); driftRestartRunning(existing) {
			return errDriftRestartBusy
		} else if existing != nil && existing.State == "running" {
			existing.State = "error"
			existing.Error = "previous restart test was stale"
			existing.CompletedAt = time.Now().Format(time.RFC3339)
			if err := driftWriteJSON(driftRestartPath(), existing, 0600); err != nil {
				return err
			}
		}

		before, err := collectDriftSnapshot()
		if err != nil {
			return err
		}
		self, err := os.Executable()
		if err != nil {
			return err
		}
		id := fmt.Sprintf("%d-%d", time.Now().UnixNano(), os.Getpid())
		state := driftRestartState{ID: id, State: "running", StartedAt: time.Now().Format(time.RFC3339), Before: before}
		if err := driftWriteJSON(driftRestartPath(), state, 0600); err != nil {
			return err
		}
		cmd := exec.Command(self, "wifi-drift-restart-worker", id)
		cmd.SysProcAttr = &syscall.SysProcAttr{Setsid: true}
		if err := cmd.Start(); err != nil {
			state.State, state.Error = "error", err.Error()
			_ = driftWriteJSON(driftRestartPath(), state, 0600)
			return err
		}
		state.PID = cmd.Process.Pid
		if err := driftWriteJSON(driftRestartPath(), state, 0600); err != nil {
			_ = cmd.Process.Kill()
			return err
		}
		result = map[string]any{"result": "started", "id": id, "restart_performed": true}
		return nil
	})
	if errors.Is(err, errDriftRestartBusy) {
		return map[string]any{"error": err.Error(), "busy": true}
	}
	if err != nil {
		return map[string]any{"error": err.Error()}
	}
	return result
}

func wifiDriftRestartWorker(id string) int {
	var state driftRestartState
	var cmdErr error
	if err := withDriftLock(func() error {
		current := readDriftRestart()
		if current == nil || current.ID != id {
			return errors.New("restart test state not found")
		}
		state = *current
		// Keep the existing drift lock for the complete restart command so a
		// second explicit diagnostic cannot overlap knsh wlan restart.
		cmdErr = exec.Command("knsh", "wlan", "restart").Run()
		return nil
	}); err != nil {
		return 1
	}
	time.Sleep(driftRestartDelay)
	after, diffs, err := captureDriftSnapshot("knsh_restart_after", true)
	state.State = "done"
	state.CompletedAt = time.Now().Format(time.RFC3339)
	state.CommandSucceeded = cmdErr == nil
	state.After = &after
	state.Differences = diffs
	state.Error = ""
	if cmdErr != nil {
		state.Error = "knsh wlan restart failed"
	}
	if err != nil {
		state.State = "error"
		state.Error = err.Error()
	}
	_ = withDriftLock(func() error {
		current := readDriftRestart()
		if current == nil || current.ID != id {
			return nil
		}
		return driftWriteJSON(driftRestartPath(), state, 0600)
	})
	return 0
}

func wifiDriftRecord(event string) {
	if wifiDriftEnabled() {
		_, _, _ = captureDriftSnapshot(event, true)
	}
}
