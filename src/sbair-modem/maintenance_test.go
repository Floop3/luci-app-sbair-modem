// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Floop3

package main

import (
	"encoding/json"
	"testing"
)

func TestRPCDEnabledAcceptsLegacyStringAndMaintenanceBoolean(t *testing.T) {
	for _, test := range []struct {
		name string
		json string
		want string
	}{
		{name: "legacy on", json: `"1"`, want: "1"},
		{name: "legacy off", json: `"0"`, want: "0"},
		{name: "boolean on", json: `true`, want: "1"},
		{name: "boolean off", json: `false`, want: "0"},
	} {
		t.Run(test.name, func(t *testing.T) {
			var got rpcdEnabled
			if err := json.Unmarshal([]byte(test.json), &got); err != nil {
				t.Fatal(err)
			}
			if got.String() != test.want {
				t.Fatalf("got %q, want %q", got.String(), test.want)
			}
		})
	}
}

func TestParseMaintenanceFieldsRejectsMalformedAndDuplicateOutput(t *testing.T) {
	for _, raw := range []string{"broken", "key=one\nkey=two"} {
		if _, err := parseMaintenanceFields(raw); err == nil {
			t.Fatalf("parseMaintenanceFields(%q) accepted malformed output", raw)
		}
	}
}
