// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Floop3

package main

import (
	"errors"
	"strings"
	"testing"
)

func saveAdblockRuleHooks(t *testing.T) {
	t.Helper()
	oldRun, oldOutput, oldReady, oldMACs, oldIP := adblockIptablesRun, adblockIptablesOutput, adblockDNSReadyFn, adblockMACsFn, adblockBrlanIPFn
	oldIPOutput := adblockIPOutput
	t.Cleanup(func() {
		adblockIptablesRun, adblockIptablesOutput, adblockDNSReadyFn, adblockMACsFn, adblockBrlanIPFn = oldRun, oldOutput, oldReady, oldMACs, oldIP
		adblockIPOutput = oldIPOutput
	})
}

func TestRemoveAdblockRulesAllowsAnAbsentChainAfterSuccessfulEnumeration(t *testing.T) {
	saveAdblockRuleHooks(t)
	called := false
	adblockIptablesOutput = func(args ...string) (string, error) {
		if strings.Join(args, " ") != "-t nat -S" {
			t.Fatalf("unexpected table enumeration: %v", args)
		}
		return "", nil
	}
	adblockIptablesRun = func(args ...string) error {
		called = true
		return nil
	}
	if err := removeAdblockRules(); err != nil {
		t.Fatal(err)
	}
	if called {
		t.Fatal("ran cleanup commands for a chain absent from a successful -S")
	}
}

func TestRemoveAdblockRulesPropagatesEnumerationAndCleanupFailures(t *testing.T) {
	t.Run("enumeration", func(t *testing.T) {
		saveAdblockRuleHooks(t)
		enumerationErr := errors.New("iptables table unavailable")
		adblockIptablesOutput = func(...string) (string, error) { return "permission denied", enumerationErr }
		if err := removeAdblockRules(); !errors.Is(err, enumerationErr) {
			t.Fatalf("error = %v, want enumeration error", err)
		}
	})

	t.Run("delete flush and chain delete", func(t *testing.T) {
		saveAdblockRuleHooks(t)
		adblockIptablesOutput = func(...string) (string, error) {
			return "-N sbair_adblock\n-A PREROUTING -j sbair_adblock\n", nil
		}
		adblockIptablesRun = func(args ...string) error {
			for _, arg := range args {
				switch arg {
				case "-D":
					return errors.New("jump delete failed")
				case "-F":
					return errors.New("chain flush failed")
				case "-X":
					return errors.New("chain delete failed")
				}
			}
			return nil
		}
		err := removeAdblockRules()
		for _, want := range []string{"jump delete failed", "chain flush failed", "chain delete failed"} {
			if !strings.Contains(err.Error(), want) {
				t.Errorf("error %q does not include %q", err, want)
			}
		}
	})
}

func TestApplyAdblockRulesJoinsDNSAndCleanupErrors(t *testing.T) {
	saveAdblockRuleHooks(t)
	adblockMACsFn = func() map[string]bool { return map[string]bool{"02:00:00:00:00:01": true} }
	adblockDNSReadyFn = func() bool { return false }
	enumerationErr := errors.New("iptables -S failed")
	adblockIptablesOutput = func(...string) (string, error) { return "", enumerationErr }
	err := applyAdblockRules()
	if !errors.Is(err, enumerationErr) || !strings.Contains(err.Error(), "専用dnsmasq") {
		t.Fatalf("error = %v, want DNS and cleanup errors", err)
	}
}

func TestApplyAdblockRulesJoinsApplyAndCleanupErrors(t *testing.T) {
	saveAdblockRuleHooks(t)
	adblockMACsFn = func() map[string]bool { return map[string]bool{"02:00:00:00:00:01": true} }
	adblockDNSReadyFn = func() bool { return true }
	adblockBrlanIPFn = func() string { return "198.51.100.1" }
	adblockIptablesOutput = func(...string) (string, error) {
		return "-N sbair_adblock\n-A PREROUTING -j sbair_adblock\n", nil
	}
	flushes := 0
	adblockIptablesRun = func(args ...string) error {
		for _, arg := range args {
			if arg == "-F" {
				flushes++
				if flushes == 1 {
					return errors.New("apply flush failed")
				}
				return errors.New("cleanup flush failed")
			}
		}
		return nil
	}
	err := applyAdblockRules()
	if !strings.Contains(err.Error(), "apply flush failed") || !strings.Contains(err.Error(), "cleanup flush failed") {
		t.Fatalf("error = %v, want both apply and cleanup errors", err)
	}
}

func TestBrlanIPExcludesOnlyTheExactFactoryResidue(t *testing.T) {
	saveAdblockRuleHooks(t)
	for _, tc := range []struct {
		name string
		out  string
		want string
	}{
		{"valid 172.16 address", "2: br-lan    inet 172.16.1.1/24 scope global br-lan\n", "172.16.1.1"},
		{"factory residue only", "2: br-lan    inet 172.16.255.254/24 scope global br-lan\n", ""},
		{"public LAN address", "2: br-lan    inet 198.51.100.1/24 scope global br-lan\n", "198.51.100.1"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			adblockIPOutput = func() ([]byte, error) { return []byte(tc.out), nil }
			if got := brlanIP(); got != tc.want {
				t.Fatalf("brlanIP() = %q, want %q", got, tc.want)
			}
		})
	}
}
