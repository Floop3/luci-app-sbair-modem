#!/bin/sh
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 soralis0912
# install.sh — root/ と htdocs/ を配置し、out/sbair-modem を入れる。
#
#   ./install.sh <展開済み rootfs ツリー>     ツリーへ導入する
#   ./install.sh /                            動いている実機に直接
#
# ⚠ **`install(1)` を使わない。** この機体の busybox に applet が無く、
#    実機で `install: not found` になる。mkdir/cp/chmod だけで組む。
#
# 実機に直接入れたときだけ rpcd を再起動する。**ubus のオブジェクトは
# rpcd の起動時にしか列挙されない**ので、これを飛ばすと画面が
# "Object not found" になる。
set -eu
SELF=$(cd "$(dirname "$0")" && pwd)
ROOT="${1:-}"

[ -n "$ROOT" ] || { echo "使い方: $0 <rootfs ツリー | />" >&2; exit 2; }
[ -d "$ROOT" ] || { echo "!! $ROOT が無い" >&2; exit 1; }
[ -f "$SELF/out/sbair-modem" ] || { echo "!! out/sbair-modem が無い。先に ./build.sh" >&2; exit 1; }

sha256_file() {
	if command -v sha256sum >/dev/null 2>&1; then
		sha256sum "$1" | awk '{print $1}'
		return
	fi
	command -v shasum >/dev/null 2>&1 || return 1
	shasum -a 256 "$1" | awk '{print $1}'
}

netmode_marker_is_current() {
	local path current_hash target_hash
	path=$1
	[ -f "$path" ] || return 1
	[ ! -L "$path" ] || return 1
	# Inspect the marker statically. Do not execute an untrusted existing helper
	# merely to ask it for its version. The source hash also prevents a foreign
	# helper from spoofing the marker with a few copied lines.
	grep -Fqx "NETMODE_IMPLEMENTATION='luci-app-sbair-modem'" "$path" || return 1
	grep -Fqx "NETMODE_SCHEMA='1'" "$path" || return 1
	grep -Fqx "NETMODE_VERSION='1'" "$path" || return 1
	grep -Fq 'version) show_version;;' "$path" || return 1
	current_hash=$(sha256_file "$SELF/root/usr/sbin/sbair-netmode") || return 1
	target_hash=$(sha256_file "$path") || return 1
	[ "$current_hash" = "$target_hash" ]
}

netmode_hash_is_app_owned_old() {
	local hash
	hash=$(sha256_file "$1") || return 1
	# Exact hashes of the Floop3-bundled helper revisions before the stable
	# marker existed. Do not broaden this list to content heuristics: a foreign
	# helper must never be mistaken for an app-owned one.
	case "$hash" in
		367d5f82151a7ec9cc8fc1834cc9f23c5334b4957bff2bdaa08fa63d712e4c57|\
		7310572db87e28972ea153620e5341c5e60232e02795aaf09b8456f8bf0fd94a|\
		c724aeae25e5b0047f0fd67778730efbf86dd7d0dd1d00e23390c3a87178e250|\
		5c5d05ff309d7b34e1f6bf39ae0bd284b9a9c53715200649a67f098ef754d6f7|\
		17e59eea66170a5bd388579fdff085379cf7851f91a71ec41502194f9b10e560|\
		8398486cefbbfb6ddfc77f5ec4bb3157da06e660f496cb85b42b8b9e13ebe46e|\
		43fc29e716b920c3e62f2e1ea476e5905d127389d47a81a37e41c16b2f472287|\
		bcee5d0143509161d756cee27073a66c7655ab2ea911040e3f8814f525810de5|\
		25d9c44efb16ed5507eb3578b36b84bd877697a7ef6b7330c75dd7ee9045940e|\
		b40113d65acdb9933ba3e94af901929d34f551985f3d5f4408b2ca01c06bcaab|\
		02d9d6e7b2ac432eb1de88ec0e32e0e8d6587ced8b711337bd68e4dea66aacfc)
			return 0
		;;
	esac
	return 1
}

netmode_is_known_prefork_legacy() {
	# The pre-fork recovery implementation is not present in this checkout or
	# in the reachable project history. Keep this explicit allow-list empty
	# until its exact artifact can be independently identified. Unknown files
	# therefore fail closed instead of being classified by fragile heuristics.
	return 1
}

check_netmode_ownership() {
	local target kind hash backup_dir backup
	target="$ROOT/usr/sbin/sbair-netmode"
	[ -e "$target" ] || [ -L "$target" ] || return 0
	if netmode_marker_is_current "$target"; then
		kind=APP_OWNED_CURRENT
	elif netmode_hash_is_app_owned_old "$target"; then
		kind=APP_OWNED_OLD
	elif netmode_is_known_prefork_legacy "$target"; then
		kind=KNOWN_PRE_FORK_LEGACY
	else
		kind=UNKNOWN_FOREIGN
	fi

	case "$kind" in
		APP_OWNED_CURRENT|APP_OWNED_OLD)
			echo "既存の sbair-netmode: ${kind}（更新します）"
			;;
		KNOWN_PRE_FORK_LEGACY)
			backup_dir="$ROOT/root/sbair-backups/netmode-legacy"
			backup="$backup_dir/sbair-netmode"
			mkdir -p "$backup_dir"
			chmod 700 "$backup_dir"
			if [ -e "$backup" ] || [ -L "$backup" ]; then
				[ -f "$backup" ] && [ ! -L "$backup" ] || {
					echo "!! 既存のlegacyバックアップが不正なため停止します: $backup" >&2
					return 1
				}
				echo "既知の旧recovery版を検出済み（既存バックアップを保持して移行します）"
			else
				cp -p "$target" "$backup"
				echo "既知の旧recovery版を $backup へ退避し、移行します"
			fi
			;;
		UNKNOWN_FOREIGN)
			hash=$(sha256_file "$target" 2>/dev/null || printf 'unavailable')
			echo "!! /usr/sbin/sbair-netmode は未知の外部実装です。上書きしません。" >&2
			echo "!! SHA256: $hash" >&2
			echo "!! 既存実装を確認・退避してから、意図的な移行手順を実施してください。" >&2
			return 1
			;;
	esac
}

# Check before creating directories or copying any file. This makes an
# ordinary install fail closed when another package owns the network controller.
check_netmode_ownership

mkdir -p "$ROOT/usr/bin" \
         "$ROOT/usr/sbin" \
         "$ROOT/usr/libexec/sbair/netmode" \
         "$ROOT/usr/libexec/rpcd" \
         "$ROOT/usr/share/rpcd/acl.d" \
         "$ROOT/usr/share/luci/menu.d" \
         "$ROOT/www/luci-static/resources/view/sbair" \
         "$ROOT/www/luci-static/resources/tools" \
         "$ROOT/www/luci-static/resources/protocol" \
         "$ROOT/etc/init.d" \
         "$ROOT/etc/udhcpc.user.d" \
         "$ROOT/etc/sbair" \
         "$ROOT/usr/share/sbair" \
         "$ROOT/etc/uci-defaults"

put() {   # put <src> <dst> <mode>
	cp "$1" "$2"
	chmod "$3" "$2"
}

put "$SELF/out/sbair-modem"             "$ROOT/usr/bin/sbair-modem"          0755
put "$SELF/root/usr/sbin/sbair-netmode" "$ROOT/usr/sbin/sbair-netmode"       0755
for module in common.sh state.sh apply.sh status.sh; do
	put "$SELF/root/usr/libexec/sbair/netmode/$module" \
	    "$ROOT/usr/libexec/sbair/netmode/$module" 0755
done
put "$SELF/root/usr/sbin/sbair-maintenance" "$ROOT/usr/sbin/sbair-maintenance" 0755
put "$SELF/root/usr/sbin/sbair-usb-nic" "$ROOT/usr/sbin/sbair-usb-nic" 0755
put "$SELF/root/usr/sbin/sbair-netfix"  "$ROOT/usr/sbin/sbair-netfix"        0755
put "$SELF/root/usr/share/sbair/firewall.include" \
    "$ROOT/usr/share/sbair/firewall.include"                                0755
put "$SELF/root/etc/uci-defaults/luci-app-sbair-modem" \
    "$ROOT/etc/uci-defaults/luci-app-sbair-modem"                            0755
put "$SELF/root/usr/sbin/sbair-wifidrift" "$ROOT/usr/sbin/sbair-wifidrift"    0755
put "$SELF/root/etc/init.d/sbair-wifidrift" "$ROOT/etc/init.d/sbair-wifidrift" 0755
put "$SELF/root/usr/libexec/rpcd/sbair" "$ROOT/usr/libexec/rpcd/sbair"       0755
put "$SELF/root/usr/share/rpcd/acl.d/luci-app-sbair-modem.json" \
    "$ROOT/usr/share/rpcd/acl.d/luci-app-sbair-modem.json"                   0644
put "$SELF/root/usr/share/luci/menu.d/luci-app-sbair-modem.json" \
    "$ROOT/usr/share/luci/menu.d/luci-app-sbair-modem.json"                  0644
put "$SELF/htdocs/luci-static/resources/tools/sbair.js" \
    "$ROOT/www/luci-static/resources/tools/sbair.js"                         0644

# 元のスクリプトにバグが存在したため、修正。
# for v in signal sim sms device; do
# 	put "$SELF/htdocs/luci-static/resources/view/sbair/$v.js" \
# 	    "$ROOT/www/luci-static/resources/view/sbair/$v.js"                   0644
# done

# 修正版。LuCI の全 sbair view を配置する。
# 画面追加時に install.sh 側への列挙追加を忘れて 404 になるのを防ぐ。
for src in "$SELF"/htdocs/luci-static/resources/view/sbair/*.js; do
    [ -f "$src" ] || continue
    dst="$ROOT/www/luci-static/resources/view/sbair/$(basename "$src")"
    put "$src" "$dst" 0644
done

# adblock.js used to be a standalone page.  Its controls now live in the
# connected-clients view, so remove the old deployed view on upgrades as well.
rm -f "$ROOT/www/luci-static/resources/view/sbair/adblock.js"

# maintenance.js used to own both LAN DHCP and OTA/FOTA.  The two focused
# views now own those menu entries, so remove the old deployed page on upgrades.
rm -f "$ROOT/www/luci-static/resources/view/sbair/maintenance.js"

# netifd の ql_datacall proto を LuCI の Interfaces から触れるようにする。
# **ベンダは proto スクリプトだけ入れて LuCI 側の JS を入れていない。**
put "$SELF/htdocs/luci-static/resources/protocol/ql_datacall.js" \
    "$ROOT/www/luci-static/resources/protocol/ql_datacall.js"                0644
put "$SELF/root/etc/init.d/sbair-apn"    "$ROOT/etc/init.d/sbair-apn"          0755
put "$SELF/root/etc/init.d/sbair-netfix" "$ROOT/etc/init.d/sbair-netfix"       0755
put "$SELF/root/etc/init.d/sbair-adblock" "$ROOT/etc/init.d/sbair-adblock"     0755
put "$SELF/root/etc/init.d/sbair-portal" "$ROOT/etc/init.d/sbair-portal"       0755
put "$SELF/root/usr/sbin/sbair-adblock-dnsmasq" \
    "$ROOT/usr/sbin/sbair-adblock-dnsmasq"                                     0755
put "$SELF/root/etc/sbair/adblock-dnsmasq.conf" \
    "$ROOT/etc/sbair/adblock-dnsmasq.conf"                                      0600
put "$SELF/root/etc/udhcpc.user.d/sbair-fallback" \
    "$ROOT/etc/udhcpc.user.d/sbair-fallback"                                  0755

# **rc.d のリンクを自分で張る。** ツリーへの導入では
# `/etc/init.d/sbair-apn enable` を走らせられない(動いている実機ではないので
# procd も uci も無い)。
# **張り忘れると起動時フックが動かず**、APN がベンダの値に戻り
# (knsh が /etc/config/lte から上書きする)、AT+CNMI も既定に戻ったままになる。
mkdir -p "$ROOT/etc/rc.d"
ln -sf ../init.d/sbair-apn "$ROOT/etc/rc.d/S95sbair-apn"
ln -sf ../init.d/sbair-apn "$ROOT/etc/rc.d/K01sbair-apn"
ln -sf ../init.d/sbair-netfix "$ROOT/etc/rc.d/S94sbair-netfix"
ln -sf ../init.d/sbair-netfix "$ROOT/etc/rc.d/K06sbair-netfix"
ln -sf ../init.d/sbair-wifidrift "$ROOT/etc/rc.d/S93sbair-wifidrift"
ln -sf ../init.d/sbair-wifidrift "$ROOT/etc/rc.d/K07sbair-wifidrift"
ln -sf ../init.d/sbair-adblock "$ROOT/etc/rc.d/S90sbair-adblock"
ln -sf ../init.d/sbair-adblock "$ROOT/etc/rc.d/K10sbair-adblock"
ln -sf ../init.d/sbair-portal "$ROOT/etc/rc.d/S91sbair-portal"
ln -sf ../init.d/sbair-portal "$ROOT/etc/rc.d/K09sbair-portal"
chmod 0700 "$ROOT/etc/sbair"

# sysupgrade で持ち越す物の登録。
#
# **これが無いと、正規の更新手順でも APN と SMS が消える。** OpenWrt は
# `/lib/upgrade/keep.d/<pkg>` に書かれたパスだけを引き継ぐ。この機体でも
# busybox / collectd / dnsmasq / opkg が同じ形で登録している。
#
# ⚠ **これは sysupgrade 経路にしか効かない。** rootfs パーティションを
# `dd` で直接焼くときは overlay ごと消えるので、**別途 tar で退避すること**
# (実機検証結果)。実際に一度これで消した。
#
# ⚠ **SMS の DB を uci で別の場所へ移したら、その行もここに足すこと。**
# 既定 (`/etc/sbair/`) 以外は当然ここには載っていない。
mkdir -p "$ROOT/lib/upgrade/keep.d"
cat > "$ROOT/lib/upgrade/keep.d/luci-app-sbair-modem" <<'EOF'
/etc/config/sbair
/etc/sbair/
/root/sbair-backups/netmode-legacy/
EOF
chmod 0644 "$ROOT/lib/upgrade/keep.d/luci-app-sbair-modem"

echo "配置した: $ROOT"

# ベンダの libqlnet / libqlril が /etc/config/ql_ril_service を読んで log_level を
# 取る。**無いと 1 秒ごとに "uci_load file failed" を吐き続ける。**
# 中身はログ水準だけで、データコールとは無関係。
if [ ! -f "$ROOT/etc/config/ql_ril_service" ]; then
	mkdir -p "$ROOT/etc/config"
	printf "config ql_ril_service 'common'\n\toption log_level '3'\n" \
		> "$ROOT/etc/config/ql_ril_service"
	echo "作成した: /etc/config/ql_ril_service (ログ水準。無いと毎秒エラーを吐く)"
fi

if [ "$ROOT" = "/" ]; then
	# Register the named package include without appending arbitrary text to
	# /etc/config/firewall. The uci-defaults copy remains for image/tree installs.
	if command -v uci >/dev/null 2>&1; then
		uci -q get firewall.sbair_dhcp_guard >/dev/null 2>&1 || \
			uci -q set firewall.sbair_dhcp_guard=include
		uci -q set firewall.sbair_dhcp_guard.type=script
		uci -q set firewall.sbair_dhcp_guard.path=/usr/share/sbair/firewall.include
		uci -q set firewall.sbair_dhcp_guard.reload=1
		uci -q commit firewall
	fi
	# menu.d を読み直させる。消しておけば LuCI が作り直す。
	rm -f /tmp/luci-indexcache 2>/dev/null || true
	rm -rf /tmp/luci-modulecache 2>/dev/null || true
	/etc/init.d/rpcd restart 2>/dev/null || true
	/etc/init.d/sbair-apn enable 2>/dev/null || true
	/etc/init.d/sbair-netfix enable 2>/dev/null || true
	/etc/init.d/sbair-netfix start 2>/dev/null || true
	/etc/init.d/sbair-wifidrift enable 2>/dev/null || true
	/etc/init.d/sbair-wifidrift start 2>/dev/null || true
	/etc/init.d/sbair-adblock enable 2>/dev/null || true
	/etc/init.d/sbair-adblock start 2>/dev/null || true
	/etc/init.d/sbair-portal enable 2>/dev/null || true
	/etc/init.d/sbair-portal start 2>/dev/null || true
	/usr/share/sbair/firewall.include 2>/dev/null || true
	echo "rpcd を再起動し、LuCI のキャッシュを消した"
	echo "確認: ubus call sbair overview"
fi
