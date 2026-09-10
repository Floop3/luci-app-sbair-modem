// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Floop3

package main

import (
	"errors"
	"testing"
)

func setupWiFiAdvancedTest(t *testing.T) {
	t.Helper()
	oldUCI, oldCommand := uciRunner, wifiCommandRun
	t.Cleanup(func() { uciRunner, wifiCommandRun = oldUCI, oldCommand })
	t.Setenv("SBAIR_WIFI_DRIFT_DIR", t.TempDir())
	uciRunner = func(args ...string) ([]byte, error) {
		if len(args) >= 2 && args[0] == "get" && args[1] == "sbair.wifi_drift.enabled" {
			return nil, errors.New("drift disabled")
		}
		return nil, nil
	}
	wifiCommandRun = func(string, ...string) (string, error) { return "", nil }
}

func TestWiFiAdvancedSettersFailClosedOnSectionSetAndCommit(t *testing.T) {
	t.Run("section set", func(t *testing.T) {
		setupWiFiAdvancedTest(t)
		uciRunner = func(args ...string) ([]byte, error) {
			if len(args) >= 2 && args[0] == "get" && args[1] == "knos.network" {
				return nil, errors.New("missing section")
			}
			if len(args) >= 1 && args[0] == "set" {
				return nil, errors.New("section set failed")
			}
			return nil, errors.New("unexpected UCI command")
		}
		result := wifiEnabledSet("1")
		if result["error"] == nil || result["result"] == "ok" {
			t.Fatalf("section set failure result = %#v", result)
		}
	})

	t.Run("knos commit", func(t *testing.T) {
		setupWiFiAdvancedTest(t)
		uciRunner = func(args ...string) ([]byte, error) {
			if len(args) >= 2 && args[0] == "get" && args[1] == "knos.network" {
				return []byte("network"), nil
			}
			if len(args) >= 2 && args[0] == "commit" && args[1] == "knos" {
				return nil, errors.New("knos commit failed")
			}
			if len(args) >= 2 && args[0] == "get" && args[1] == "sbair.wifi_drift.enabled" {
				return nil, errors.New("drift disabled")
			}
			return nil, nil
		}
		result := wifiEnabledSet("1")
		if result["error"] == nil || result["result"] == "ok" {
			t.Fatalf("knos commit failure result = %#v", result)
		}
	})
}

func TestWiFiAdvancedSettersFailOnReadbackAndRuntimeApply(t *testing.T) {
	t.Run("readback mismatch", func(t *testing.T) {
		setupWiFiAdvancedTest(t)
		uciRunner = func(args ...string) ([]byte, error) {
			if len(args) >= 2 && args[0] == "get" && args[1] == "knos.network" {
				return []byte("network"), nil
			}
			if len(args) >= 2 && args[0] == "get" && args[1] == "knos.network.wlan_enabled" {
				return []byte("0"), nil
			}
			if len(args) >= 2 && args[0] == "get" && args[1] == "sbair.wifi_drift.enabled" {
				return nil, errors.New("drift disabled")
			}
			return nil, nil
		}
		result := wifiEnabledSet("1")
		if result["error"] == nil || result["result"] == "ok" {
			t.Fatalf("readback mismatch result = %#v", result)
		}
	})

	t.Run("synchronous isolation runtime failure", func(t *testing.T) {
		setupWiFiAdvancedTest(t)
		uciRunner = func(args ...string) ([]byte, error) {
			if len(args) >= 2 && args[0] == "get" && args[1] == "knos.network" {
				return []byte("network"), nil
			}
			if len(args) >= 2 && args[0] == "get" && args[1] == "knos.network.wlan_wlan2lan" {
				return []byte("1"), nil
			}
			return nil, nil
		}
		wifiCommandRun = func(name string, args ...string) (string, error) {
			if name == "sh" && len(args) == 2 && args[0] == "-c" {
				return "ebtables failed", errors.New("isolation runtime failed")
			}
			return "", nil
		}
		result := isolationSet("wlan2lan", "1")
		if result["error"] == nil || result["result"] == "ok" {
			t.Fatalf("isolation runtime failure result = %#v", result)
		}
	})
}

func TestWiFiAdvancedSetterSuccessRequiresReadback(t *testing.T) {
	setupWiFiAdvancedTest(t)
	uciRunner = func(args ...string) ([]byte, error) {
		if len(args) >= 2 && args[0] == "get" && args[1] == "knos.network" {
			return []byte("network"), nil
		}
		if len(args) >= 2 && args[0] == "get" && args[1] == "knos.network.wlan_enabled" {
			return []byte("1"), nil
		}
		if len(args) >= 2 && args[0] == "get" && args[1] == "sbair.wifi_drift.enabled" {
			return nil, errors.New("drift disabled")
		}
		return nil, nil
	}
	result := wifiEnabledSet("1")
	if result["result"] != "ok" || result["enabled"] != true {
		t.Fatalf("successful Wi-Fi update result = %#v", result)
	}
}

func TestWiFi11rCommitAndAuthoritativeReadback(t *testing.T) {
	t.Run("wireless commit failure", func(t *testing.T) {
		setupWiFiAdvancedTest(t)
		uciRunner = func(args ...string) ([]byte, error) {
			if len(args) >= 2 && args[0] == "commit" && args[1] == "wireless" {
				return nil, errors.New("wireless commit failed")
			}
			return nil, nil
		}
		result := dot11rSet("1")
		if result["error"] == nil || result["result"] == "ok" {
			t.Fatalf("wireless commit failure result = %#v", result)
		}
	})

	t.Run("readback mismatch", func(t *testing.T) {
		setupWiFiAdvancedTest(t)
		wifiCommandRun = func(name string, args ...string) (string, error) {
			if name == "knsh" && len(args) == 3 && args[0] == "wlan" && args[1] == "get" && args[2] == "11r" {
				return "0", nil
			}
			return "", nil
		}
		result := dot11rSet("1")
		if result["error"] == nil || result["result"] == "ok" {
			t.Fatalf("11r readback mismatch result = %#v", result)
		}
	})
}
