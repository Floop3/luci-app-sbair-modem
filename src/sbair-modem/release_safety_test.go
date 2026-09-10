// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Floop3

package main

import (
	"errors"
	"net"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
)

func TestPrivateRuntimeRejectsSymlinkAndAtomicWriteDoesNotFollowFinalName(t *testing.T) {
	root := t.TempDir()
	private := filepath.Join(root, "private")
	if err := ensurePrivateDir(private); err != nil {
		t.Fatal(err)
	}
	link := filepath.Join(root, "link")
	if err := os.Symlink(private, link); err != nil {
		t.Fatal(err)
	}
	if err := ensurePrivateDir(link); err == nil {
		t.Fatal("accepted a symlink as a private runtime directory")
	}

	target := filepath.Join(private, "target")
	sentinel := filepath.Join(root, "sentinel")
	if err := os.WriteFile(sentinel, []byte("unchanged"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(sentinel, target); err != nil {
		t.Fatal(err)
	}
	if err := atomicWritePrivate(target, []byte("new"), 0600); err != nil {
		t.Fatal(err)
	}
	if got, _ := os.ReadFile(sentinel); string(got) != "unchanged" {
		t.Fatalf("atomic write followed final symlink: %q", got)
	}
	info, err := os.Lstat(target)
	if err != nil || info.Mode()&os.ModeSymlink != 0 || info.Mode().Perm() != 0600 {
		t.Fatalf("final runtime file is not a private regular file: %v, mode=%v", err, info.Mode())
	}
}

func TestATConnectFailsClosedWhenLockUnavailable(t *testing.T) {
	lockPath := filepath.Join(t.TempDir(), "lock-dir")
	if err := os.Mkdir(lockPath, 0700); err != nil {
		t.Fatal(err)
	}
	t.Setenv("SBAIR_AT_LOCK_PATH", lockPath)
	ch := NewATChannel(filepath.Join(t.TempDir(), "must-not-be-dialed"))
	err := ch.Connect()
	if !errors.Is(err, ErrLockUnavailable) {
		t.Fatalf("Connect error = %v, want ErrLockUnavailable", err)
	}
}

func TestATConnectDistinguishesBusyLock(t *testing.T) {
	lockPath := filepath.Join(t.TempDir(), "at.lock")
	helper, err := acquireRuntimeLock(lockPath, 100000000)
	if err != nil {
		t.Fatal(err)
	}
	defer helper.close()
	t.Setenv("SBAIR_AT_LOCK_PATH", lockPath)
	t.Setenv("SBAIR_AT_LOCK_TIMEOUT_MS", "10")
	err = NewATChannel(filepath.Join(t.TempDir(), "must-not-be-dialed")).Connect()
	if !errors.Is(err, ErrLockBusy) {
		t.Fatalf("Connect error = %v, want ErrLockBusy", err)
	}
}

func TestStartJobSingleFlightAndSpawnFailureClearsRunning(t *testing.T) {
	t.Setenv("SBAIR_RUNTIME_DIR", t.TempDir())
	oldExecutable := jobExecutable
	oldDevice := *device
	t.Cleanup(func() { jobExecutable = oldExecutable; *device = oldDevice })
	jobExecutable = func() (string, error) { return os.Executable() }
	*device = "/dev/null"

	start := make(chan struct{})
	results := make(chan map[string]any, 2)
	var wg sync.WaitGroup
	for i := 0; i < 2; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			<-start
			results <- startJob("release-test")
		}()
	}
	close(start)
	wg.Wait()
	close(results)
	started, already := 0, 0
	for result := range results {
		if result["result"] == "started" {
			started++
		}
		if result["state"] == "running" {
			already++
		}
	}
	if started != 1 || already != 1 {
		t.Fatalf("single-flight results: started=%d already=%d", started, already)
	}

	jobExecutable = func() (string, error) { return filepath.Join(t.TempDir(), "missing"), nil }
	result := startJob("release-spawn-failure")
	if result["error"] == nil {
		t.Fatal("spawn failure was reported as success")
	}
	state := readJob("release-spawn-failure")
	if state["state"] != "error" {
		t.Fatalf("spawn failure state = %#v", state)
	}
}

func TestSMSDatabaseAndSidecarsArePrivate(t *testing.T) {
	oldPath, oldNote := smsDBResolved, smsDBNote
	t.Cleanup(func() { smsDBOnce = sync.Once{}; smsDBResolved, smsDBNote = oldPath, oldNote })
	smsDBOnce = sync.Once{}
	smsDBResolved, smsDBNote = "", ""
	path := filepath.Join(t.TempDir(), "sms", "messages.db")
	t.Setenv("SBAIR_SMS_DB", path)
	db, err := openSMSDB()
	if err != nil {
		t.Fatal(err)
	}
	if err := db.Close(); err != nil {
		t.Fatal(err)
	}
	dirInfo, err := os.Stat(filepath.Dir(path))
	if err != nil {
		t.Fatalf("SMS parent stat error = %v", err)
	}
	if dirInfo.Mode().Perm() != 0700 {
		t.Fatalf("SMS parent mode = %v", dirInfo.Mode())
	}
	dbInfo, err := os.Stat(path)
	if err != nil {
		t.Fatalf("SMS db stat error = %v", err)
	}
	if dbInfo.Mode().Perm() != 0600 {
		t.Fatalf("SMS db mode = %v", dbInfo.Mode())
	}
	if err := os.Chmod(path, 0644); err != nil {
		t.Fatal(err)
	}
	smsDBOnce = sync.Once{}
	smsDBResolved, smsDBNote = "", ""
	db, err = openSMSDB()
	if err != nil {
		t.Fatal(err)
	}
	_ = db.Close()
	dbInfo, err = os.Stat(path)
	if err != nil {
		t.Fatalf("existing SMS db stat after tightening: %v", err)
	}
	if dbInfo.Mode().Perm() != 0600 {
		t.Fatalf("existing SMS db was not tightened: mode=%v", dbInfo.Mode())
	}

	smsDBOnce = sync.Once{}
	smsDBResolved, smsDBNote = "", ""
	if err := os.Symlink(filepath.Join(t.TempDir(), "outside"), path+"-wal"); err != nil {
		t.Fatal(err)
	}
	if db, err := openSMSDB(); err == nil {
		_ = db.Close()
		t.Fatal("accepted a SQLite sidecar symlink")
	}
}

func testLANNetworks() ([]*net.IPNet, []net.IP) {
	_, network, _ := net.ParseCIDR("192.168.0.0/24")
	return []*net.IPNet{network}, []net.IP{net.ParseIP("192.168.0.1")}
}

func TestSSDPAndPortScanLANBoundaries(t *testing.T) {
	networks, self := testLANNetworks()
	valid := []struct {
		location string
		source   string
	}{
		{"http://192.168.0.20:80/device.xml", "192.168.0.20"},
	}
	for _, tc := range valid {
		if err := validateSSDPLocation(tc.location, net.ParseIP(tc.source), networks, self); err != nil {
			t.Errorf("valid SSDP location rejected: %v", err)
		}
	}
	invalid := []struct {
		location string
		source   string
	}{
		{"https://192.168.0.20/device.xml", "192.168.0.20"},
		{"http://192.168.0.21/device.xml", "192.168.0.20"},
		{"http://192.168.1.20/device.xml", "192.168.1.20"},
		{"http://192.168.0.1/device.xml", "192.168.0.1"},
		{"http://192.168.0.255/device.xml", "192.168.0.255"},
		{"http://127.0.0.1/device.xml", "127.0.0.1"},
	}
	for _, tc := range invalid {
		if err := validateSSDPLocation(tc.location, net.ParseIP(tc.source), networks, self); err == nil {
			t.Errorf("unsafe SSDP location accepted: %+v", tc)
		}
	}
	if _, err := validateLANPeer("192.168.0.1", networks, self); err == nil {
		t.Error("port scan accepted router address")
	}
	if _, err := validateLANPeer("192.168.1.20", networks, self); err == nil {
		t.Error("port scan accepted outside address")
	}
	if ip, err := validateLANPeer("192.168.0.20", networks, self); err != nil || !observedClientIP(ip.String(), []clientEntry{{IP: "192.168.0.20"}}) {
		t.Errorf("observed LAN client was not accepted: %v", err)
	}
	if observedClientIP("192.168.0.21", []clientEntry{{IP: "192.168.0.20"}}) {
		t.Error("unobserved LAN client was accepted")
	}
}

func TestAdblockPartialRuleFailureRemovesDNAT(t *testing.T) {
	oldRun, oldOutput, oldReady, oldMACs, oldIP := adblockIptablesRun, adblockIptablesOutput, adblockDNSReadyFn, adblockMACsFn, adblockBrlanIPFn
	t.Cleanup(func() {
		adblockIptablesRun, adblockIptablesOutput, adblockDNSReadyFn, adblockMACsFn, adblockBrlanIPFn = oldRun, oldOutput, oldReady, oldMACs, oldIP
	})
	var calls [][]string
	chainExists, jumpPresent := false, false
	addCount := 0
	adblockIptablesRun = func(args ...string) error {
		calls = append(calls, append([]string(nil), args...))
		for _, arg := range args {
			switch arg {
			case "-N":
				chainExists = true
			case "-I":
				jumpPresent = true
			case "-D":
				jumpPresent = false
			case "-X":
				chainExists = false
			}
			if arg == "-A" {
				addCount++
				if addCount == 2 {
					return errors.New("simulated iptables append failure")
				}
			}
			if arg == "-C" {
				return errors.New("jump not present")
			}
		}
		return nil
	}
	adblockIptablesOutput = func(args ...string) (string, error) {
		if !chainExists {
			return "", nil
		}
		if jumpPresent {
			return "-N sbair_adblock\n-A PREROUTING -j sbair_adblock\n", nil
		}
		return "-N sbair_adblock\n", nil
	}
	adblockDNSReadyFn = func() bool { return true }
	adblockMACsFn = func() map[string]bool { return map[string]bool{"02:00:00:00:00:01": true} }
	adblockBrlanIPFn = func() string { return "192.168.0.1" }

	if err := applyAdblockRules(); err == nil {
		t.Fatal("partial iptables append was reported as success")
	}
	hasDelete, hasFlush, hasDeleteChain := false, false, false
	for _, call := range calls {
		joined := " " + strings.Join(call, " ") + " "
		if strings.Contains(joined, " -D PREROUTING ") {
			hasDelete = true
		}
		if strings.Contains(joined, " -F "+adblockChain+" ") {
			hasFlush = true
		}
		if strings.Contains(joined, " -X "+adblockChain+" ") {
			hasDeleteChain = true
		}
	}
	if !hasDelete || !hasFlush || !hasDeleteChain {
		t.Fatalf("partial DNAT cleanup incomplete: %#v", calls)
	}
}

func TestAdblockHostsAtomicReplaceDoesNotFollowSymlink(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "hosts.txt")
	sentinel := filepath.Join(dir, "sentinel")
	if err := os.WriteFile(sentinel, []byte("do not overwrite"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(sentinel, path); err != nil {
		t.Fatal(err)
	}
	t.Setenv("SBAIR_ADBLOCK_HOSTS", path)
	if err := writeAdblockHosts(); err != nil {
		t.Fatal(err)
	}
	if got, _ := os.ReadFile(sentinel); string(got) != "do not overwrite" {
		t.Fatalf("adblock hosts write followed symlink: %q", got)
	}
	info, err := os.Lstat(path)
	if err != nil {
		t.Fatalf("adblock hosts stat error: %v", err)
	}
	if info.Mode()&os.ModeSymlink != 0 || info.Mode().Perm() != 0644 {
		t.Fatalf("adblock hosts is not a public regular file: mode=%v", info.Mode())
	}
}

func TestWifiApplyBatchRevertsWhenUCISetFails(t *testing.T) {
	oldRunner := uciRunner
	t.Cleanup(func() { uciRunner = oldRunner })
	setCalls := 0
	reverted := false
	uciRunner = func(args ...string) ([]byte, error) {
		if len(args) == 2 && args[0] == "show" && args[1] == "wireless" {
			return []byte("wireless.radio0=wifi-device\n" +
				"wireless.radio0.band='2.4G'\n" +
				"wireless.radio0.htmode='HE20'\n" +
				"wireless.ra0=wifi-iface\n" +
				"wireless.ra0.mode='ap'\n" +
				"wireless.ra0.device='radio0'\n" + "wireless.ra0.ssid='old'\n"), nil
		}
		if len(args) == 2 && args[0] == "changes" && args[1] == "wireless" {
			return nil, nil
		}
		if len(args) > 0 && args[0] == "set" {
			setCalls++
			if setCalls == 2 {
				return nil, errors.New("simulated UCI set failure")
			}
			return nil, nil
		}
		if len(args) == 2 && args[0] == "revert" && args[1] == "wireless" {
			reverted = true
		}
		return nil, nil
	}

	result := wifiApplyBatch(`{"interfaces":[{"iface":"ra0","ssid":"new","hidden":"1"}]}`)
	if result["error"] == nil {
		t.Fatal("UCI set failure was reported as success")
	}
	if !reverted {
		t.Fatal("UCI set failure did not revert the complete wireless batch")
	}
}

func TestWifiTxPowerMaxIsNoopWhenFirmwareScaleAlreadyMax(t *testing.T) {
	oldRunner := uciRunner
	t.Cleanup(func() { uciRunner = oldRunner })
	uciRunner = func(args ...string) ([]byte, error) {
		if len(args) == 2 && args[0] == "show" && args[1] == "wireless" {
			return []byte("wireless.radio0=wifi-device\n" +
				"wireless.radio0.band='2.4G'\n" +
				"wireless.radio0.txpower='100'\n" +
				"wireless.radio1=wifi-device\n" +
				"wireless.radio1.band='5G'\n" +
				"wireless.radio1.txpower='100'\n"), nil
		}
		if len(args) == 2 && args[0] == "changes" && args[1] == "wireless" {
			return nil, nil
		}
		return nil, errors.New("unexpected UCI command")
	}

	result := wifiTxPowerMax()
	if result["result"] != "already_max" || result["txpower"] != maxFirmwareTxPower {
		t.Fatalf("already-max result = %#v", result)
	}
	if result["regulatory_settings_kept"] != true {
		t.Fatalf("regulatory settings were not reported as preserved: %#v", result)
	}
}

func TestWifiTxPowerDefaultDeletesExplicitScale(t *testing.T) {
	oldRunner := uciRunner
	t.Cleanup(func() { uciRunner = oldRunner })
	fakeBin := t.TempDir()
	knsh := filepath.Join(fakeBin, "knsh")
	if err := os.WriteFile(knsh, []byte("#!/bin/sh\nexit 0\n"), 0755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", fakeBin+string(os.PathListSeparator)+os.Getenv("PATH"))
	t.Setenv("SBAIR_WIFI_DRIFT_DIR", t.TempDir())

	var deleted []string
	uciRunner = func(args ...string) ([]byte, error) {
		if len(args) == 2 && args[0] == "show" && args[1] == "wireless" {
			return []byte("wireless.radio0=wifi-device\n" +
				"wireless.radio0.band='2.4G'\n" +
				"wireless.radio0.txpower='100'\n" +
				"wireless.radio1=wifi-device\n" +
				"wireless.radio1.band='5G'\n" +
				"wireless.radio1.txpower='80'\n"), nil
		}
		if len(args) == 2 && args[0] == "changes" && args[1] == "wireless" {
			return nil, nil
		}
		if len(args) == 2 && args[0] == "get" && args[1] == "sbair.wifi_drift.enabled" {
			return nil, errors.New("drift disabled in test")
		}
		if len(args) == 2 && args[0] == "delete" {
			deleted = append(deleted, args[1])
			return nil, nil
		}
		if len(args) == 2 && args[0] == "commit" && args[1] == "wireless" {
			return nil, nil
		}
		return nil, errors.New("unexpected UCI command")
	}

	result := wifiTxPowerDefault()
	if result["result"] != "started" || result["txpower"] != "default" {
		t.Fatalf("default result = %#v", result)
	}
	want := []string{"wireless.radio0.txpower", "wireless.radio1.txpower"}
	if strings.Join(deleted, "\n") != strings.Join(want, "\n") {
		t.Fatalf("delete calls = %#v, want %#v", deleted, want)
	}
	if result["regulatory_settings_kept"] != true {
		t.Fatalf("regulatory settings were not reported as preserved: %#v", result)
	}
}
