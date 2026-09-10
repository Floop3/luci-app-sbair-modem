#!/bin/sh
# SPDX-License-Identifier: MIT
# target.sh — BusyBox ash-compatible SBA6-side LuCI bootstrap.
#
# This file is copied to /tmp on the router by the host installer.  It never
# edits /etc/opkg/distfeeds.conf and never runs opkg upgrade.
set -eu

STAGE=${SBA6_LUCI_STAGE:-/tmp/sba6-luci-bootstrap}
PKGDIR="$STAGE/packages"
LOCKFILE="$STAGE/packages.lock"
OPKG_CONF="$STAGE/opkg.conf"
MODE=install
DRY_RUN=0

die() {
	echo "[ERROR] $*" >&2
	exit 1
}

say() {
	echo "[INFO] $*"
}

warn() {
	echo "[WARNING] $*" >&2
}

while [ "$#" -gt 0 ]; do
	case "$1" in
		--preflight) MODE=preflight ;;
		--install) MODE=install ;;
		--repair) MODE=repair ;;
		--dry-run) DRY_RUN=1 ;;
		--help|-h)
			echo "Usage: $0 [--preflight|--install|--repair] [--dry-run]"
			exit 0
			;;
		*) die "unknown option: $1" ;;
	esac
	shift
done

command_or_die() {
	command -v "$1" >/dev/null 2>&1 || die "required command is missing: $1"
}

release_value() {
	# /etc/openwrt_release uses shell assignments with single-quoted values.
	key=$1
	sed -n "s/^$key='//; s/'\$//; p" /etc/openwrt_release 2>/dev/null | head -n 1
}

require_platform() {
	command_or_die awk
	command_or_die sed
	command_or_die ip
	command_or_die opkg
	command_or_die uci
	command_or_die tar
	command_or_die iptables
	[ -r /etc/openwrt_release ] || die "/etc/openwrt_release is missing"

	release=$(release_value DISTRIB_RELEASE)
	target=$(release_value DISTRIB_TARGET)
	arch=$(release_value DISTRIB_ARCH)

	[ "$release" = "21.02.7" ] || die "unsupported OpenWrt release: ${release:-unknown} (need 21.02.7)"
	[ "$target" = "gem6xxx/evb6990_cpe_mt7990_emmc" ] || \
		die "unsupported target: ${target:-unknown} (this bootstrap is for SBA6D only)"
	[ "$arch" = "aarch64_cortex-a55_neon-vfpv4" ] || \
		die "unsupported vendor architecture: ${arch:-unknown}"
	opkg print-architecture 2>/dev/null |
		grep -q 'aarch64_cortex-a55_neon-vfpv4' || \
		die "opkg does not advertise the SBA6 vendor architecture"

	say "platform OK: OpenWrt $release / $target / $arch"
}

runtime_lan_ip() {
	ip -4 addr show br-lan 2>/dev/null |
		awk '$1 == "inet" && $2 !~ /^172\.16\.255\./ {
			sub(/\/.*/, "", $2)
			print $2
			exit
		}'
}

configured_lan_ip() {
	uci -q get network.lan.ipaddr 2>/dev/null || true
}

check_lan_ip() {
	configured=$(configured_lan_ip)
	runtime=$(runtime_lan_ip)

	[ -n "$runtime" ] || die "br-lan has no usable IPv4 address"
	if [ -n "$configured" ] && [ "$configured" != "$runtime" ]; then
		warn "configured LAN IP and runtime LAN IP differ"
		warn "Configured: $configured"
		warn "Runtime:    $runtime"
		warn "Do not delete a network device section automatically."
		warn "See extras/luci-bootstrap/docs/IP-MIGRATION.md"
		exit 1
	fi
	say "LAN IP: $runtime"
}

require_stage() {
	[ -f "$LOCKFILE" ] || die "packages.lock is missing from $STAGE"
	[ -d "$PKGDIR" ] || die "package directory is missing: $PKGDIR"
	awk -F '\t' '$1 !~ /^#/ && NF == 5 { n++ } END { exit(n == 0) }' "$LOCKFILE" ||
		die "packages.lock has no package entries"
}

make_backup() {
	BACKUP="/root/sba6-pre-luci-$(date +%Y%m%d-%H%M%S).$$"
	mkdir -p "$BACKUP" || die "cannot create backup directory: $BACKUP"
	opkg list-installed >"$BACKUP/opkg.before.txt" 2>/dev/null || true
	tar -czf "$BACKUP/config.before.tgz" \
		/etc/config \
		/etc/firewall.user \
		/etc/opkg.conf \
		/etc/opkg \
		/usr/lib/opkg/status \
		2>/dev/null || true
	[ -e /usr/lib/libnl-tiny.so ] &&
		cp -p /usr/lib/libnl-tiny.so "$BACKUP/libnl-tiny.so.before" 2>/dev/null || true
	say "backup: $BACKUP"
}

write_opkg_conf() {
	mkdir -p "$STAGE/lists"
	cat >"$OPKG_CONF" <<'EOF'
dest root /
dest ram /tmp
lists_dir ext /tmp/sba6-luci-bootstrap/lists
option overlay_root /overlay
option check_signature
arch all 1
arch noarch 1
arch aarch64_generic 10
arch aarch64_cortex-a55_neon-vfpv4 100
EOF
}

manifest_paths() {
	awk -F '\t' -v d="$PKGDIR" \
		'$1 !~ /^#/ && NF == 5 && $5 != "special-libnl" { print d "/" $2 }' \
		"$LOCKFILE"
}

special_libnl_path() {
	awk -F '\t' -v d="$PKGDIR" \
		'$1 !~ /^#/ && NF == 5 && $5 == "special-libnl" { print d "/" $2; exit }' \
		"$LOCKFILE"
}

check_manifest_files() {
	missing=0
	for package in $(manifest_paths); do
		[ -f "$package" ] || {
			echo "[ERROR] missing package: $package" >&2
			missing=1
		}
	done
	special=$(special_libnl_path)
	[ -n "$special" ] && [ -f "$special" ] || {
		echo "[ERROR] missing special libnl package" >&2
		missing=1
	}
	[ "$missing" -eq 0 ] || exit 1
}

reject_unsafe_plan() {
	plan="$STAGE/opkg-dry-run.txt"
	if grep -E '^(Downgrading|Removing)' "$plan" >/dev/null 2>&1; then
		cat "$plan" >&2
		die "opkg plan contains a downgrade or removal; vendor packages were not changed"
	fi
	if grep -Ei '^(Upgrading|Downgrading|Removing).*(libc|kernel|kmod-|libubus|libuci|libubox|libjson|libblobmsg|liblua|libnl|libiwinfo20230701|mtk|kn_)' "$plan" >/dev/null 2>&1; then
		cat "$plan" >&2
		die "opkg plan would change a protected vendor library"
	fi
}

check_vendor_libnl() {
	[ -f /usr/lib/libnl-tiny.so.1 ] ||
		die "vendor /usr/lib/libnl-tiny.so.1 is missing; refusing to replace vendor ABI"
	opkg status libnl-tiny1 2>/dev/null |
		grep -q '^Status: .* installed' || \
		die "vendor libnl-tiny1 is not registered as installed"
}

plan_packages() {
	set -- $(manifest_paths)
	[ "$#" -gt 0 ] || die "the package manifest has no installable packages"
	opkg -f "$OPKG_CONF" --noaction install "$@" >"$STAGE/opkg-dry-run.txt" 2>&1 || {
		cat "$STAGE/opkg-dry-run.txt" >&2
		die "opkg dependency dry-run failed"
	}
	reject_unsafe_plan
	say "opkg dry-run OK"
}

install_packages() {
	set -- $(manifest_paths)
	opkg -f "$OPKG_CONF" install "$@" || die "opkg package installation failed"
}

extract_libnl() {
	NL_IPK=$(special_libnl_path)
	NL_ROOT="$STAGE/libnl-runtime"
	NL_AR_DIR="$STAGE/libnl-ar"
	rm -rf "$NL_ROOT" "$NL_AR_DIR"
	mkdir -p "$NL_ROOT" "$NL_AR_DIR"

	# OpenWrt .ipk files are ar archives on current releases.  Keep a tar
	# fallback for vendor images whose busybox/opkg still uses tar-style ipks.
	if command -v ar >/dev/null 2>&1; then
		if ar p "$NL_IPK" data.tar.gz >"$NL_AR_DIR/data.tar.gz" 2>/dev/null &&
			tar -xzf "$NL_AR_DIR/data.tar.gz" -C "$NL_ROOT" 2>/dev/null; then
			:
		else
			rm -f "$NL_AR_DIR/data.tar.gz"
		fi
	fi
	if [ ! -f "$NL_ROOT/usr/lib/libnl-tiny.so" ]; then
		if opkg extract "$NL_IPK" "$NL_ROOT" >/dev/null 2>&1; then
			:
		fi
	fi
	if [ ! -f "$NL_ROOT/usr/lib/libnl-tiny.so" ]; then
		tar -xzf "$NL_IPK" -C "$NL_AR_DIR" 2>/dev/null || true
		if [ -f "$NL_AR_DIR/data.tar.gz" ]; then
			tar -xzf "$NL_AR_DIR/data.tar.gz" -C "$NL_ROOT" 2>/dev/null || true
		fi
		[ -f "$NL_AR_DIR/usr/lib/libnl-tiny.so" ] &&
			cp -p "$NL_AR_DIR/usr/lib/libnl-tiny.so" "$NL_ROOT/usr/lib/libnl-tiny.so" 2>/dev/null || true
	fi
	[ -f "$NL_ROOT/usr/lib/libnl-tiny.so" ] || \
		die "could not extract libnl-tiny.so without installing vendor libnl-tiny1"

	LD_LIBRARY_PATH="$NL_ROOT/usr/lib" lua -e "require 'luci.ip'; print('[OK] luci.ip ABI')" ||
		die "the staged libnl-tiny.so failed the LuCI ABI test"
	cp -f "$NL_ROOT/usr/lib/libnl-tiny.so" /usr/lib/libnl-tiny.so
	chmod 0644 /usr/lib/libnl-tiny.so
	[ -f /usr/lib/libnl-tiny.so.1 ] || die "vendor libnl-tiny.so.1 disappeared"
	say "libnl-tiny.so installed side-by-side with vendor libnl-tiny.so.1"
}

configure_uhttpd() {
	uci -q delete uhttpd.main.listen_http || true
	uci add_list uhttpd.main.listen_http='0.0.0.0:8080'
	uci add_list uhttpd.main.listen_http='[::]:8080'
	uci -q delete uhttpd.main.listen_https || true
	uci set uhttpd.main.redirect_https='0'
	uci set uhttpd.main.home='/www'
	uci set uhttpd.main.cgi_prefix='/cgi-bin'
	uci set uhttpd.main.lua_prefix='/cgi-bin/luci'
	uci set uhttpd.main.lua_handler='/usr/lib/lua/luci/sgi/uhttpd.lua'
	uci set uhttpd.main.ubus_prefix='/ubus'
	uci commit uhttpd
	say "uhttpd configured for TCP/8080; lighttpd TCP/80 was not changed"
}

firewall_rule_present() {
	iptables -C INPUT -i br-lan -p tcp --dport 8080 -j ACCEPT >/dev/null 2>&1
}

configure_firewall() {
	touch /etc/firewall.user
	sed -i '/^# LUCI-LAN-SBA6-BEGIN$/,/^# LUCI-LAN-SBA6-END$/d' /etc/firewall.user
	cat >>/etc/firewall.user <<'EOF'

# LUCI-LAN-SBA6-BEGIN
# Permit LuCI from the LAN bridge only; do not couple this to a LAN IP.
iptables -C INPUT -i br-lan -p tcp --dport 8080 -j ACCEPT 2>/dev/null || \
iptables -I INPUT 1 -i br-lan -p tcp --dport 8080 -j ACCEPT
# LUCI-LAN-SBA6-END
EOF
	uci set firewall.sba6_user_include='include'
	uci set firewall.sba6_user_include.path='/etc/firewall.user'
	uci set firewall.sba6_user_include.reload='1'
	uci commit firewall
	/etc/init.d/firewall restart || die "firewall restart failed"
	firewall_rule_present || iptables -I INPUT 1 -i br-lan -p tcp --dport 8080 -j ACCEPT
	firewall_rule_present || die "could not install the LAN-only TCP/8080 firewall rule"
	say "firewall persisted: br-lan -> TCP/8080 only"
}

refresh_services() {
	rm -f /tmp/luci-indexcache /tmp/luci-indexcache.*
	rm -rf /tmp/luci-modulecache
	/etc/init.d/rpcd restart 2>/dev/null || true
	/etc/init.d/uhttpd enable || die "could not enable uhttpd autostart"
	/etc/init.d/uhttpd restart || die "could not restart uhttpd"
	say "rpcd refreshed and uhttpd autostart enabled"
}

require_installed_runtime() {
	[ -x /usr/sbin/uhttpd ] || die "uhttpd is not installed; run the normal installer first"
	[ -f /usr/lib/uhttpd_lua.so ] || die "uhttpd-mod-lua is not installed"
	[ -f /usr/lib/lua/luci/sgi/uhttpd.lua ] || die "LuCI runtime is not installed"
}

do_install() {
	require_stage
	check_manifest_files
	check_vendor_libnl
	write_opkg_conf
	plan_packages
	if [ "$DRY_RUN" -eq 1 ]; then
		say "dry-run: no package, library, UCI, firewall, or service changes made"
		exit 0
	fi
	make_backup
	install_packages
	extract_libnl
	configure_uhttpd
	configure_firewall
	refresh_services
}

do_repair() {
	require_installed_runtime
	check_vendor_libnl
	make_backup
	configure_uhttpd
	configure_firewall
	refresh_services
}

require_platform
check_lan_ip

case "$MODE" in
	preflight)
		say "preflight completed; no changes made"
		;;
	install)
		do_install
		;;
	repair)
		do_repair
		;;
esac
