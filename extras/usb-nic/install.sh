#!/bin/sh
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Floop3
# Host-side optional bundle installer for the experimental SBA6 USB NCM gadget.
# It only downloads, verifies and transfers the module. Runtime activation is
# a separate, explicit operation in LuCI/target-side sbair-usb-nic.
set -eu

SELF=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
LOCKFILE=${SBA6_USB_NIC_LOCKFILE:-$SELF/driver.lock}
CACHE_DIR=${SBA6_USB_NIC_CACHE_DIR:-${TMPDIR:-/tmp}/sba6-usb-nic-cache}
STAGE=/tmp/sba6-usb-nic
MODE=install
PROFILE=
TARGET=

die() { echo "[ERROR] $*" >&2; exit 1; }
say() { echo "[INFO] $*"; }

lock_value() {
	key=$1
	sed -n "s/^${key}=//p" "$LOCKFILE" | head -n 1
}

hash_file() {
	file=$1
	if command -v sha256sum >/dev/null 2>&1; then
		sha256sum "$file" | awk '{print $1}'
	elif command -v shasum >/dev/null 2>&1; then
		shasum -a 256 "$file" | awk '{print $1}'
	elif command -v openssl >/dev/null 2>&1; then
		openssl dgst -sha256 "$file" | sed 's/^.*= //'
	else
		die "sha256sum, shasum or openssl is required"
	fi
}

require_command() {
	command -v "$1" >/dev/null 2>&1 || die "required command is missing: $1"
}

check_lock() {
	[ -r "$LOCKFILE" ] || die "driver.lock is missing: $LOCKFILE"
	ARTIFACT_FILENAME=$(lock_value ARTIFACT_FILENAME)
	ARTIFACT_URL=$(lock_value ARTIFACT_URL)
	EXPECTED_SHA256=$(lock_value SHA256)
	[ -n "$ARTIFACT_FILENAME" ] || die "driver.lock: ARTIFACT_FILENAME is empty"
	[ -n "$ARTIFACT_URL" ] || die "driver.lock: ARTIFACT_URL is empty"
	case "$ARTIFACT_FILENAME" in */*|..*) die "driver.lock: invalid artifact filename" ;; esac
	printf '%s\n' "$EXPECTED_SHA256" | awk '
		length($0) == 64 && $0 ~ /^[0-9a-f]+$/ { ok = 1 }
		END { exit(ok ? 0 : 1) }' || die "driver.lock: SHA256 is not 64 lowercase hexadecimal characters"
}

parse_args() {
	while [ "$#" -gt 0 ]; do
		case "$1" in
			--check) MODE=check ;;
			--profile)
				[ "$#" -ge 2 ] || die "--profile requires a file"
				PROFILE=$2
				shift
				;;
			--cache-dir)
				[ "$#" -ge 2 ] || die "--cache-dir requires a directory"
				CACHE_DIR=$2
				shift
				;;
			--help|-h)
				echo "Usage: $0 [--check] [--profile FILE] [--cache-dir DIR] root@AIR6"
				exit 0
				;;
			-*) die "unknown option: $1" ;;
			*)
				[ -z "$TARGET" ] || die "only one SSH target is allowed"
				TARGET=$1
				;;
		esac
		shift
	done
	[ -n "$TARGET" ] || die "usage: $0 [--check] [--profile FILE] root@AIR6"
}

profile_file_check() {
	[ -n "$PROFILE" ] || return 0
	[ -f "$PROFILE" ] || die "profile is not a regular file: $PROFILE"
	[ ! -L "$PROFILE" ] || die "profile must not be a symlink: $PROFILE"
	mode=$(stat -f %Lp "$PROFILE" 2>/dev/null || stat -c %a "$PROFILE" 2>/dev/null || true)
	case "$mode" in
		600|0600) ;;
		*) die "profile must have mode 600: $PROFILE (found ${mode:-unknown})" ;;
	esac
}

download_bundle() {
	module=$CACHE_DIR/$ARTIFACT_FILENAME
	mkdir -p "$CACHE_DIR"
	if [ -f "$module" ]; then
		say "using cached artifact: $module" >&2
	else
		require_command curl
		say "downloading pinned artifact from upstream revision $(lock_value UPSTREAM_REVISION)" >&2
		curl -fsSL --retry 2 -o "$module.part" "$ARTIFACT_URL"
		mv "$module.part" "$module"
	fi
	actual=$(hash_file "$module")
	[ "$actual" = "$EXPECTED_SHA256" ] || die "SHA256 mismatch for $ARTIFACT_FILENAME (got $actual)"
	say "SHA256 verified: $actual" >&2
	echo "$module"
}

remote_install() {
	module=$1
	require_command ssh
	require_command scp
	ssh "$TARGET" "rm -rf '$STAGE' && mkdir -m 700 -p '$STAGE'"
	scp "$module" "$TARGET:$STAGE/$ARTIFACT_FILENAME"
	scp "$SELF/target.sh" "$TARGET:$STAGE/target.sh"
	scp "$SELF/check.sh" "$TARGET:$STAGE/check.sh"
	scp "$LOCKFILE" "$TARGET:$STAGE/driver.lock"
	if [ -n "$PROFILE" ]; then
		scp "$PROFILE" "$TARGET:$STAGE/profile"
	fi
	ssh "$TARGET" "chmod 700 '$STAGE/target.sh' '$STAGE/check.sh'; chmod 600 '$STAGE/$ARTIFACT_FILENAME' '$STAGE/driver.lock'"
	if [ -n "$PROFILE" ]; then
		ssh "$TARGET" "chmod 600 '$STAGE/profile'"
	fi
	say "transferring verified bundle; runtime remains disabled"
	if [ -n "$PROFILE" ]; then
		ssh "$TARGET" "'$STAGE/target.sh' --install --module '$STAGE/$ARTIFACT_FILENAME' --profile '$STAGE/profile'"
	else
		ssh "$TARGET" "'$STAGE/target.sh' --install --module '$STAGE/$ARTIFACT_FILENAME'"
	fi
	ssh "$TARGET" "'$STAGE/check.sh'"
}

remote_check() {
	require_command ssh
	ssh "$TARGET" "command -v sbair-usb-nic >/dev/null 2>&1 && sbair-usb-nic status || '$STAGE/check.sh'"
}

parse_args "$@"
check_lock
profile_file_check

if [ "$MODE" = check ]; then
	say "read-only USB NIC status check"
	remote_check
	exit 0
fi

say "[1/4] checking SSH target: $TARGET"
ssh "$TARGET" "true"
say "[2/4] downloading and verifying optional experimental bundle"
	MODULE=$(download_bundle)
say "[3/4] transferring bundle to Air6"
remote_install "$MODULE"
say "[4/4] completed; no module load, ConfigFS change, UDC bind or reboot was performed"
echo "Bundle installed. Runtime activation requires a valid reviewed profile and explicit LuCI acknowledgement."
