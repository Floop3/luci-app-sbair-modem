#!/bin/sh
# SPDX-License-Identifier: MIT
# check.sh — read-only post-install and post-reboot SBA6 LuCI check.
set -u

status=0

ok() {
	echo "[OK] $*"
}

ng() {
	echo "[NG] $*"
	status=1
}

warn() {
	echo "[WARNING] $*"
}

release_value() {
	key=$1
	sed -n "s/^$key='//; s/'\$//; p" /etc/openwrt_release 2>/dev/null | head -n 1
}

runtime_lan_ip() {
	ip -4 addr show br-lan 2>/dev/null |
		awk '$1 == "inet" && $2 !~ /^172\.16\.255\./ {
			sub(/\/.*/, "", $2)
			print $2
			exit
		}'
}

echo "=== SBA6 LuCI CHECK (read-only) ==="

release=$(release_value DISTRIB_RELEASE)
target=$(release_value DISTRIB_TARGET)
arch=$(release_value DISTRIB_ARCH)
[ "$release" = "21.02.7" ] && ok "OpenWrt release: $release" || ng "OpenWrt release: ${release:-unknown}"
[ "$target" = "gem6xxx/evb6990_cpe_mt7990_emmc" ] && ok "target: $target" || ng "target: ${target:-unknown}"
[ "$arch" = "aarch64_cortex-a55_neon-vfpv4" ] && ok "vendor architecture: $arch" || ng "vendor architecture: ${arch:-unknown}"

configured=$(uci -q get network.lan.ipaddr 2>/dev/null || true)
runtime=$(runtime_lan_ip)
[ -n "$runtime" ] && ok "br-lan runtime IPv4: $runtime" || ng "br-lan has no usable IPv4"
if [ -n "$configured" ] && [ -n "$runtime" ] && [ "$configured" = "$runtime" ]; then
	ok "network.lan.ipaddr matches runtime"
elif [ -n "$configured" ] && [ -n "$runtime" ]; then
	ng "configured LAN IP $configured differs from runtime $runtime"
fi

for path in \
	/usr/sbin/uhttpd \
	/usr/lib/uhttpd_lua.so \
	/usr/lib/uhttpd_ubus.so \
	/usr/lib/libnl-tiny.so \
	/usr/lib/libnl-tiny.so.1 \
	/usr/lib/libiwinfo.so.20210430 \
	/usr/lib/libiwinfo.so.20230701 \
	/usr/lib/lua/luci/sgi/uhttpd.lua; do
	[ -e "$path" ] && ok "file: $path" || ng "missing: $path"
done

if command -v lua >/dev/null 2>&1; then
	lua -e "require 'luci.util'" >/dev/null 2>&1 && ok "Lua luci.util" || ng "Lua luci.util"
	lua -e "require 'luci.ip'" >/dev/null 2>&1 && ok "Lua luci.ip" || ng "Lua luci.ip"
	lua -e "require 'luci.sgi.uhttpd'" >/dev/null 2>&1 && ok "Lua luci.sgi.uhttpd" || ng "Lua luci.sgi.uhttpd"
else
	ng "lua command is missing"
fi

if [ -x /etc/init.d/uhttpd ] && /etc/init.d/uhttpd enabled >/dev/null 2>&1; then
	ok "uhttpd autostart enabled"
else
	ng "uhttpd autostart is disabled"
fi

listener_80=1
listener_8080=1
if command -v netstat >/dev/null 2>&1; then
	netstat_output=$(netstat -lntp 2>/dev/null || true)
	printf '%s\n' "$netstat_output" | grep -E ':80[[:space:]]' >/dev/null 2>&1 || listener_80=0
	printf '%s\n' "$netstat_output" | grep -E ':8080[[:space:]]' >/dev/null 2>&1 || listener_8080=0
elif command -v ss >/dev/null 2>&1; then
	ss_output=$(ss -lnt 2>/dev/null || true)
	printf '%s\n' "$ss_output" | grep -E ':80[[:space:]]' >/dev/null 2>&1 || listener_80=0
	printf '%s\n' "$ss_output" | grep -E ':8080[[:space:]]' >/dev/null 2>&1 || listener_8080=0
else
	listener_80=0
	listener_8080=0
	warn "netstat/ss is unavailable; socket checks could not run"
fi
[ "$listener_80" -eq 1 ] && ok "TCP/80 listener remains present" || ng "TCP/80 lighttpd listener not found"
[ "$listener_8080" -eq 1 ] && ok "TCP/8080 uhttpd listener present" || ng "TCP/8080 uhttpd listener not found"

if iptables -C INPUT -i br-lan -p tcp --dport 8080 -j ACCEPT >/dev/null 2>&1; then
	ok "firewall accepts br-lan TCP/8080"
else
	ng "firewall does not accept br-lan TCP/8080"
fi

include_path=$(uci -q get firewall.sba6_user_include.path 2>/dev/null || true)
include_reload=$(uci -q get firewall.sba6_user_include.reload 2>/dev/null || true)
[ "$include_path" = "/etc/firewall.user" ] && ok "firewall include path" || ng "firewall include path: ${include_path:-missing}"
[ "$include_reload" = "1" ] && ok "firewall include reload=1" || ng "firewall include reload: ${include_reload:-missing}"

http_status=
if command -v curl >/dev/null 2>&1; then
	http_status=$(curl -sS --connect-timeout 3 -o /dev/null -w '%{http_code}' http://127.0.0.1:8080/cgi-bin/luci/ 2>/dev/null || true)
elif command -v wget >/dev/null 2>&1; then
	wget_headers=$(wget -S -O /dev/null http://127.0.0.1:8080/cgi-bin/luci/ 2>&1 || true)
	http_status=$(printf '%s\n' "$wget_headers" |
		awk '$1 ~ /^HTTP\// { print $2 }' | tail -n 1)
else
	http_status=000
fi
case "$http_status" in
	200|301|302|303|403) ok "localhost LuCI HTTP response: $http_status" ;;
	*) ng "localhost LuCI HTTP response: ${http_status:-000}" ;;
esac

echo
echo "LuCI URL: http://${runtime:-<current-LAN-IP>}:8080/cgi-bin/luci/"
if [ "$status" -eq 0 ]; then
	echo "=== CHECK FINISHED: OK ==="
else
	echo "=== CHECK FINISHED: FAILED ==="
fi
exit "$status"
