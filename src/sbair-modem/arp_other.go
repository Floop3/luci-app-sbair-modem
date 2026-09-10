//go:build !linux

// SPDX-License-Identifier: MIT
// Copyright (c) 2026 syado

package main

import "fmt"

func arpProbe(ifaceName, target string) (bool, error) {
	return false, fmt.Errorf("raw ARP probe is only supported on Linux")
}
