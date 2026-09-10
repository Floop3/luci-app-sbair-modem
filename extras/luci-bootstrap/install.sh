#!/bin/sh
# SPDX-License-Identifier: MIT
# install.sh — host-side SBA6 LuCI bootstrap.
#
# The router only needs SSH, tar, and the normal OpenWrt runtime.  Package
# downloads and SHA256 verification happen here, then target.sh applies a
# local package set without touching the vendor feeds.
set -u

SELF=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
TARGET_SCRIPT="$SELF/target.sh"
CHECK_SCRIPT="$SELF/check.sh"
LOCKFILE="$SELF/packages.lock"
TARGET_STAGE=/tmp/sba6-luci-bootstrap
CHECK_PATH=/tmp/sba6-luci-bootstrap-check.sh
MODE=install
DRY_RUN=0
CACHE_DIR=${SBA6_LUCI_CACHE_DIR:-${TMPDIR:-/tmp}/sba6-luci-bootstrap-cache}
TARGET=
CURRENT_LAN_IP=

die() {
	echo "[ERROR] $*" >&2
	exit 1
}

usage() {
	cat <<'EOF'
Usage:
  ./install.sh [--dry-run] root@AIR6_IP
  ./install.sh --check root@AIR6_IP
  ./install.sh --repair root@AIR6_IP

The default path downloads the fixed OpenWrt 21.02.7 manifest on the host,
uploads it over SSH, and applies it on the SBA6.  It never reboots the router.

Environment:
  SBA6_LUCI_CACHE_DIR  package cache directory (default: /tmp/sba6-luci-bootstrap-cache)
EOF
}

while [ "$#" -gt 0 ]; do
	case "$1" in
		--check)
			[ "$MODE" = install ] || die "choose only one mode"
			MODE=check
			;;
		--repair)
			[ "$MODE" = install ] || die "choose only one mode"
			MODE=repair
			;;
		--dry-run)
			[ "$MODE" = install ] || die "--dry-run is only valid for install mode"
			DRY_RUN=1
			;;
		--cache-dir)
			[ "$#" -gt 1 ] || die "--cache-dir needs a directory"
			CACHE_DIR=$2
			shift
			;;
		--help|-h)
			usage
			exit 0
			;;
		-*)
			die "unknown option: $1"
			;;
		*)
			[ -z "$TARGET" ] || die "only one SSH target is allowed"
			TARGET=$1
			;;
	esac
	shift
done

[ -n "$TARGET" ] || {
	usage >&2
	exit 2
}

command_or_die() {
	command -v "$1" >/dev/null 2>&1 || die "required host command is missing: $1"
}

hash_file() {
	if command -v sha256sum >/dev/null 2>&1; then
		sha256sum "$1" | awk '{print $1}'
	elif command -v shasum >/dev/null 2>&1; then
		shasum -a 256 "$1" | awk '{print $1}'
	elif command -v openssl >/dev/null 2>&1; then
		openssl dgst -sha256 -r "$1" | awk '{print $1}'
	else
		die "sha256sum, shasum, or openssl is required"
	fi
}

validate_manifest() {
	[ -f "$LOCKFILE" ] || die "missing manifest: $LOCKFILE"
	awk -F '\t' '
		$1 ~ /^#/ || NF <= 1 { next }
		NF != 5 || $2 !~ /^[^\/]+\.ipk$/ || $3 !~ /^https:\/\/downloads\.openwrt\.org\// ||
		$4 !~ /^[0-9a-fA-F]{64}$/ || $5 == "" {
			bad=1
			print "invalid manifest row: " $0 > "/dev/stderr"
		}
		{ count++ }
		END { if (count == 0 || bad) exit 1 }
	' "$LOCKFILE" || die "packages.lock validation failed"
}

manifest_rows() {
	awk -F '\t' '$1 !~ /^#/ && NF == 5 { print }' "$LOCKFILE"
}

manifest_filenames() {
	manifest_rows | awk -F '\t' '{ print $2 }'
}

check_host_tools() {
	command_or_die ssh
	command_or_die scp
	if [ "$MODE" = install ]; then
		command_or_die curl
		command_or_die tar
		# Resolve this before downloading anything.
		hash_file /dev/null >/dev/null 2>&1 || die "SHA256 tool is unusable"
	fi
}

download_manifest() {
	mkdir -p "$CACHE_DIR" || die "cannot create cache directory: $CACHE_DIR"
	printf '%s\n' "[3/7] Downloading official OpenWrt 21.02.7 packages..."
	while IFS="$(printf '\t')" read -r package filename url expected role; do
		[ -n "$filename" ] || continue
		path="$CACHE_DIR/$filename"
		if [ -f "$path" ] && [ "$(hash_file "$path")" = "$expected" ]; then
			echo "  cached: $package"
			continue
		fi
		echo "  fetching: $package"
		curl --fail --location --retry 2 --connect-timeout 15 \
			--output "$path" "$url" || die "download failed: $url"
	done <"$LOCKFILE"
	printf '%s\n' "[4/7] Verifying SHA256 hashes..."
	while IFS="$(printf '\t')" read -r package filename url expected role; do
		[ -n "$filename" ] || continue
		path="$CACHE_DIR/$filename"
		actual=$(hash_file "$path")
		[ "$actual" = "$expected" ] || die "SHA256 mismatch for $filename"
		echo "  verified: $package"
	done <"$LOCKFILE"
}

run_logged() {
	label=$1
	command=$2
	logfile="$CACHE_DIR/${label}-$(date +%Y%m%d-%H%M%S).log"
	ssh "$TARGET" "$command" >"$logfile" 2>&1
	remote_status=$?
	cat "$logfile"
	echo "  log: $logfile"
	[ "$remote_status" -eq 0 ] || die "remote command failed; see $logfile"
}

preflight() {
	printf '%s\n' "[2/7] Checking SSH and SBA6 platform..."
	preflight_log="$CACHE_DIR/preflight-$(date +%Y%m%d-%H%M%S).log"
	ssh "$TARGET" "sh -s -- --preflight" <"$TARGET_SCRIPT" >"$preflight_log" 2>&1
	preflight_status=$?
	cat "$preflight_log"
	echo "  log: $preflight_log"
	[ "$preflight_status" -eq 0 ] || die "SSH or SBA6 preflight failed"
	CURRENT_LAN_IP=$(sed -n 's/^\[INFO\] LAN IP: //p' "$preflight_log" | tail -n 1)
}

upload_install_tree() {
	printf '%s\n' "[5/7] Uploading bootstrap and package set..."
	ssh "$TARGET" "rm -rf '$TARGET_STAGE'; mkdir -p '$TARGET_STAGE/packages'" ||
		die "could not prepare the Air6 staging directory"
	scp "$TARGET_SCRIPT" "$CHECK_SCRIPT" "$LOCKFILE" "$TARGET:$TARGET_STAGE/" ||
		die "could not upload bootstrap scripts"

	bundle="$CACHE_DIR/sba6-luci-packages.tar"
	set -- $(manifest_filenames)
	tar -cf "$bundle" -C "$CACHE_DIR" "$@" || die "could not assemble package bundle"
	scp "$bundle" "$TARGET:$TARGET_STAGE/" || die "could not upload package bundle"
	ssh "$TARGET" "tar -xf '$TARGET_STAGE/sba6-luci-packages.tar' -C '$TARGET_STAGE/packages' && rm -f '$TARGET_STAGE/sba6-luci-packages.tar' && chmod 0755 '$TARGET_STAGE/target.sh' '$TARGET_STAGE/check.sh'" ||
		die "could not unpack the Air6 package bundle"
}

upload_script_only() {
	ssh "$TARGET" "mkdir -p '$TARGET_STAGE'" || die "could not prepare the Air6 staging directory"
	scp "$TARGET_SCRIPT" "$CHECK_SCRIPT" "$LOCKFILE" "$TARGET:$TARGET_STAGE/" ||
		die "could not upload repair scripts"
	ssh "$TARGET" "chmod 0755 '$TARGET_STAGE/target.sh' '$TARGET_STAGE/check.sh'" ||
		die "could not prepare repair scripts"
}

run_check() {
	printf '%s\n' "[7/7] Verifying LuCI, uhttpd, firewall, and persistence..."
	run_logged check "sh '$TARGET_STAGE/check.sh'"
}

run_install() {
	printf '%s\n' "[6/7] Installing LuCI on Air6 (no reboot)..."
	if [ "$DRY_RUN" -eq 1 ]; then
		run_logged dry-run "sh '$TARGET_STAGE/target.sh' --install --dry-run"
	else
		run_logged install "sh '$TARGET_STAGE/target.sh' --install"
	fi
}

check_host_tools
validate_manifest

case "$MODE" in
	check)
		mkdir -p "$CACHE_DIR"
		scp "$CHECK_SCRIPT" "$TARGET:$CHECK_PATH" || die "could not upload check.sh"
		ssh "$TARGET" "chmod 0755 '$CHECK_PATH'" || die "could not prepare check.sh"
		run_logged check "sh '$CHECK_PATH'"
		;;
	repair)
		mkdir -p "$CACHE_DIR"
		preflight
		upload_script_only
		printf '%s\n' "[6/7] Rebuilding uhttpd, firewall, rpcd cache, and autostart..."
		run_logged repair "sh '$TARGET_STAGE/target.sh' --repair"
		run_check
		;;
	install)
		mkdir -p "$CACHE_DIR"
		preflight
		download_manifest
		upload_install_tree
		run_install
		if [ "$DRY_RUN" -eq 1 ]; then
			echo "Dry-run completed; post-install check was skipped because no target changes were made."
		else
			run_check
		fi
		echo
		echo "LuCI installation completed."
		echo "Router: $TARGET"
		if [ -n "$CURRENT_LAN_IP" ]; then
			LUCI_URL="http://$CURRENT_LAN_IP:8080/cgi-bin/luci/"
		else
			LUCI_URL="http://<current-LAN-IP>:8080/cgi-bin/luci/"
		fi
		echo "LuCI:   $LUCI_URL"
		echo "Reboot has NOT been performed."
		echo "After reboot: $SELF/install.sh --check $TARGET"
		;;
esac
