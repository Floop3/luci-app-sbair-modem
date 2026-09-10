#!/bin/sh
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Floop3
# BusyBox ash-compatible target-side bundle installer.
# This script deliberately does not load a module or touch ConfigFS, UDC,
# usb0, network configuration, firewall, services or reboot state.
set -eu

PATH=${SBA6_USB_NIC_PATH:-/usr/sbin:/usr/bin:/sbin:/bin}
export PATH

STAGE=${SBA6_USB_NIC_STAGE:-/tmp/sba6-usb-nic}
BUNDLE_DIR=${SBA6_USB_NIC_BUNDLE_DIR:-/usr/lib/sbair/usb-nic}
PROFILE_DIR=${SBA6_USB_NIC_PROFILE_DIR:-/etc/sbair/usb-nic}
LOCKFILE=${SBA6_USB_NIC_LOCKFILE:-$STAGE/driver.lock}
MODULE=
PROFILE=

die() { echo "[ERROR] $*" >&2; exit 1; }
lock_value() { sed -n "s/^$1=//p" "$LOCKFILE" | head -n 1; }
require() { command -v "$1" >/dev/null 2>&1 || die "required command is missing: $1"; }

release_value() {
	line=$(grep -m 1 "^$1=" /etc/openwrt_release 2>/dev/null || true)
	printf '%s\n' "$line" | sed "s/^$1='//; s/'$//"
}

while [ "$#" -gt 0 ]; do
	case "$1" in
		--install) : ;;
		--module)
			[ "$#" -ge 2 ] || die "--module requires a file"
			MODULE=$2
			shift
			;;
		--profile)
			[ "$#" -ge 2 ] || die "--profile requires a file"
			PROFILE=$2
			shift
			;;
		--help|-h)
			echo "Usage: $0 --install --module FILE [--profile FILE]"
			exit 0
			;;
		*) die "unknown option: $1" ;;
	esac
	shift
	done

[ -r "$LOCKFILE" ] || die "driver.lock is missing"
[ -n "$MODULE" ] || die "--module is required"
[ -f "$MODULE" ] || die "module is not a regular file"
[ ! -L "$MODULE" ] || die "module must not be a symlink"
require sha256sum
actual=$(sha256sum "$MODULE" | awk '{print $1}')
expected=$(lock_value SHA256)
[ "$actual" = "$expected" ] || die "module SHA256 mismatch"

release=$(release_value DISTRIB_RELEASE)
target=$(release_value DISTRIB_TARGET)
arch=$(release_value DISTRIB_ARCH)
[ "$release" = "21.02.7" ] || die "unsupported OpenWrt release: ${release:-unknown}"
[ "$target" = "gem6xxx/evb6990_cpe_mt7990_emmc" ] || die "unsupported target: ${target:-unknown}"
[ "$arch" = "aarch64_cortex-a55_neon-vfpv4" ] || die "unsupported vendor architecture: ${arch:-unknown}"
[ "$(uname -r)" = "5.4.238" ] || die "unsupported kernel release: $(uname -r)"
[ "$(uname -m)" = "aarch64" ] || die "unsupported machine architecture: $(uname -m)"
[ "$(lock_value ARTIFACT_FILENAME)" = "t6a_usb_ncm_65532_candidate_v1.ko" ] || die "unexpected artifact filename"
[ "$(lock_value SHA256)" = "7f0e5f3ec197a5f80f23195a3945a2d700bca9d97b8c04eadbacb02c247523c1" ] || die "unexpected artifact SHA256"
[ "$(lock_value MODULE_NAME)" = "t6a_usb_ncm_65532_candidate_v1" ] || die "unexpected module name"
[ "$(lock_value VERMAGIC)" = "5.4.238 SMP mod_unload modversions aarch64" ] || die "unexpected vermagic"
[ "$(lock_value UPSTREAM_REVISION)" = "97f55791dd0de4161cb2a9bd06ab9799ff580a8d" ] || die "unexpected upstream revision"

vermagic=$(lock_value VERMAGIC)
if command -v modinfo >/dev/null 2>&1; then
	actual_vm=$(modinfo -F vermagic "$MODULE" 2>/dev/null || true)
elif command -v strings >/dev/null 2>&1; then
	actual_vm=$(strings "$MODULE" 2>/dev/null | grep -F -m 1 "$vermagic" || true)
else
	die "modinfo or strings is required to verify vermagic"
fi
[ "$actual_vm" = "$vermagic" ] || die "module vermagic mismatch"

[ ! -L "$BUNDLE_DIR" ] || die "bundle directory must not be a symlink"
[ ! -L "$PROFILE_DIR" ] || die "profile directory must not be a symlink"
mkdir -p "$BUNDLE_DIR" "$PROFILE_DIR"
chmod 700 "$BUNDLE_DIR" "$PROFILE_DIR"
artifact=$(lock_value ARTIFACT_FILENAME)
cp "$MODULE" "$BUNDLE_DIR/$artifact"
chmod 600 "$BUNDLE_DIR/$artifact"
cp "$LOCKFILE" "$BUNDLE_DIR/driver.lock"
chmod 600 "$BUNDLE_DIR/driver.lock"
if [ -n "$PROFILE" ]; then
	[ -f "$PROFILE" ] || die "profile is not a regular file"
	[ ! -L "$PROFILE" ] || die "profile must not be a symlink"
	cp "$PROFILE" "$PROFILE_DIR/profile"
	chmod 600 "$PROFILE_DIR/profile"
fi

printf 'result=installed\nmodule=%s\nsha256=%s\nvermagic=%s\nruntime=disabled\n' \
	"$artifact" "$actual" "$actual_vm"
printf '%s\n' 'warning=Experimental bundle persisted only; no module load, ConfigFS change, UDC bind, usb0 configuration or reboot was performed.'
