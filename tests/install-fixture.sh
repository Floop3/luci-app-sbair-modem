#!/bin/sh
# SPDX-License-Identifier: MIT
# Verify that a tree install contains every runtime dependency used by the
# services and that the private configuration directory is not omitted.
set -eu

repo=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT INT TERM
rootfs="$tmp/rootfs"
mkdir -p "$rootfs"
mkdir -p "$rootfs/www/luci-static/resources/view/sbair"
printf '%s\n' stale > "$rootfs/www/luci-static/resources/view/sbair/adblock.js"
printf '%s\n' stale > "$rootfs/www/luci-static/resources/view/sbair/maintenance.js"

sh "$repo/install.sh" "$rootfs" >/dev/null

version=$(sh "$rootfs/usr/sbin/sbair-netmode" version)
printf '%s\n' "$version" | grep -q '^implementation=luci-app-sbair-modem$'
printf '%s\n' "$version" | grep -q '^schema=1$'
printf '%s\n' "$version" | grep -q '^version=1$'
# A second install must recognize the current app-owned helper and remain
# idempotent; it must not create a migration backup.
sh "$repo/install.sh" "$rootfs" >/dev/null
[ ! -e "$rootfs/root/sbair-backups/netmode-legacy/sbair-netmode" ]

[ ! -e "$rootfs/www/luci-static/resources/view/sbair/adblock.js" ]
[ ! -e "$rootfs/www/luci-static/resources/view/sbair/maintenance.js" ]

for path in \
	/etc/init.d/sbair-adblock \
	/etc/init.d/sbair-portal \
	/etc/sbair/adblock-dnsmasq.conf \
	/usr/sbin/sbair-adblock-dnsmasq \
	/usr/bin/sbair-modem \
	/usr/sbin/sbair-netmode \
	/usr/sbin/sbair-maintenance \
	/usr/sbin/sbair-usb-nic \
	/www/luci-static/resources/view/sbair/lan_services.js \
	/www/luci-static/resources/view/sbair/network_diagnostics.js \
	/www/luci-static/resources/view/sbair/update.js; do
	[ -f "$rootfs$path" ] || { echo "missing $path" >&2; exit 1; }
done

# An exact historical Floop3 helper is still app-owned and may be updated.
old_rootfs="$tmp/old-rootfs"
mkdir -p "$old_rootfs/usr/sbin"
git show dc8f04779829100f5299287a3f6e195f4a671f02:root/usr/sbin/sbair-netmode > "$old_rootfs/usr/sbin/sbair-netmode"
sh "$repo/install.sh" "$old_rootfs" >/dev/null
sh "$old_rootfs/usr/sbin/sbair-netmode" version | grep -q '^implementation=luci-app-sbair-modem$'

# An unknown existing implementation must remain byte-for-byte untouched and
# must stop before the installer creates or copies any other app file.
foreign_rootfs="$tmp/foreign-rootfs"
mkdir -p "$foreign_rootfs/usr/sbin"
printf '%s\n' '#!/bin/sh' 'echo foreign' > "$foreign_rootfs/usr/sbin/sbair-netmode"
chmod 755 "$foreign_rootfs/usr/sbin/sbair-netmode"
foreign_before=$(shasum -a 256 "$foreign_rootfs/usr/sbin/sbair-netmode" | awk '{print $1}')
if sh "$repo/install.sh" "$foreign_rootfs" >"$tmp/foreign-install.out" 2>&1; then
	echo 'unknown foreign sbair-netmode was overwritten' >&2
	exit 1
fi
foreign_after=$(shasum -a 256 "$foreign_rootfs/usr/sbin/sbair-netmode" | awk '{print $1}')
[ "$foreign_before" = "$foreign_after" ]
[ ! -e "$foreign_rootfs/usr/bin/sbair-modem" ]
grep -q '未知の外部実装' "$tmp/foreign-install.out"

# The optional kernel module and activation profile are never part of the
# normal application installation.
[ ! -e "$rootfs/usr/lib/sbair/usb-nic/t6a_usb_ncm_65532_candidate_v1.ko" ]
[ ! -e "$rootfs/etc/sbair/usb-nic/profile" ]

[ "$(stat -f %Lp "$rootfs/etc/sbair")" = 700 ]
[ "$(stat -f %Lp "$rootfs/etc/sbair/adblock-dnsmasq.conf")" = 600 ]
[ "$(readlink "$rootfs/etc/rc.d/S90sbair-adblock")" = ../init.d/sbair-adblock ]
[ "$(readlink "$rootfs/etc/rc.d/S91sbair-portal")" = ../init.d/sbair-portal ]
[ "$(readlink "$rootfs/etc/rc.d/K10sbair-adblock")" = ../init.d/sbair-adblock ]
[ "$(readlink "$rootfs/etc/rc.d/K09sbair-portal")" = ../init.d/sbair-portal ]

# Keep the boot path at the unforked behavior: only the lightweight APN apply
# runs during startup, asynchronously.  The heavier modem/SIM/IMS/band boot
# sequence must never be part of the init start path.
grep -q '/usr/bin/sbair-modem apn apply' "$repo/root/etc/init.d/sbair-apn"
! grep -q '/usr/bin/sbair-modem boot' "$repo/root/etc/init.d/sbair-apn"

# Diagnostic Wi-Fi drift collection is opt-in and the power action must keep
# regulatory settings untouched.
grep -q 'wifi_txpower_max' "$repo/src/sbair-modem/rpcd.go"
grep -q 'wifi_txpower_default' "$repo/src/sbair-modem/rpcd.go"
grep -q 'uci.*delete.*txpower' "$repo/src/sbair-modem/wifi.go"
grep -q 'regulatory_settings_kept' "$repo/src/sbair-modem/wifi.go"
grep -q '全てのネットワーク接続が失われ' "$repo/htdocs/luci-static/resources/tools/sbair.js"
grep -q 'Wi-Fiやネットワーク設定の切り替えや設定変更' "$repo/htdocs/luci-static/resources/tools/sbair.js"
grep -q '接続モードの切り替えや設定変更' "$repo/htdocs/luci-static/resources/tools/sbair.js"
grep -q 'uci.*sbair.wifi_drift.enabled.*= 1' "$repo/root/etc/init.d/sbair-wifidrift"

# Network-mode mutation remains owned by the target helper; Go only invokes it
# and may perform read-only UCI inspection for unrelated modem guards.
grep -Fq 'exec.Command("sbair-netmode", args...)' "$repo/src/sbair-modem/netmode.go"
! grep -Eq 'uci\("(set|delete|commit)"' "$repo/src/sbair-modem/netmode.go"

echo install-fixture-ok
