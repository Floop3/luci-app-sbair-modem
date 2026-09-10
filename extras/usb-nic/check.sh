#!/bin/sh
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Floop3
# Read-only post-install/status entry point for the optional bundle.
set -eu

command -v sbair-usb-nic >/dev/null 2>&1 || {
	echo 'result=error'
	echo 'error=sbair-usb-nic helper is not installed; install the main application first'
	exit 1
}
exec sbair-usb-nic status
