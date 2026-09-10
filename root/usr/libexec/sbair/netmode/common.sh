# SPDX-License-Identifier: MIT
# Copyright (c) 2026 syado
# Shared runtime, locking, UCI, and validation helpers.

runtime_metadata_secure() {
	local path expected_mode chmod_mode line mode owner uid
	path=$1
	expected_mode=$2
	chmod_mode=$3
	# SBA6's BusyBox build does not include stat(1). Use numeric ls output,
	# which is available on the target and keeps the owner/mode checks explicit.
	line=$(LC_ALL=C ls -ldn "$path" 2>/dev/null) || return 1
	mode=$(printf '%s\n' "$line" | awk '{print $1}') || return 1
	# BSD ls appends `@` when extended attributes are present; it is not part
	# of the permission bits.
	mode=${mode%@*}
	owner=$(printf '%s\n' "$line" | awk '{print $3}') || return 1
	uid=$(id -u 2>/dev/null || printf 0)
	[ "$owner" = 0 ] || [ "$owner" = "$uid" ] || return 1
	if [ "$mode" != "$expected_mode" ]; then
		chmod "$chmod_mode" "$path" 2>/dev/null || return 1
		line=$(LC_ALL=C ls -ldn "$path" 2>/dev/null) || return 1
		mode=$(printf '%s\n' "$line" | awk '{print $1}') || return 1
		mode=${mode%@*}
	fi
	[ "$mode" = "$expected_mode" ]
}

private_runtime_dir() {
	local dir
	dir=$1
	[ -d "$dir" ] || mkdir -p "$dir" 2>/dev/null || return 1
	[ ! -L "$dir" ] || return 1
	# On the device uid is root. The uid fallback makes host fixtures usable while
	# still rejecting a non-root-owned directory when this process is root.
	runtime_metadata_secure "$dir" drwx------ 700
}

safe_runtime_write() {
	local path value dir tmp
	path=$1
	value=$2
	dir=$(dirname "$path")
	private_runtime_dir "$dir" || return 1
	tmp=$(mktemp "$path.tmp.XXXXXX" 2>/dev/null) || return 1
	chmod 600 "$tmp" 2>/dev/null || { rm -f "$tmp"; return 1; }
	if ! printf '%s\n' "$value" > "$tmp"; then
		rm -f "$tmp"
		return 1
	fi
	mv "$tmp" "$path" 2>/dev/null || { rm -f "$tmp"; return 1; }
	[ ! -L "$path" ]
}

private_runtime_file() {
	local path
	path=$1
	[ ! -L "$path" ] || return 1
	[ ! -e "$path" ] && return 0
	[ -f "$path" ] || return 1
	runtime_metadata_secure "$path" -rw------- 600
}

netmode_lock_release() {
	[ "$LOCK_HELD" -eq 1 ] || return 0
	rm -f "$LOCK_DIR/pid" 2>/dev/null || true
	rmdir "$LOCK_DIR" 2>/dev/null || true
	LOCK_HELD=0
}

netmode_lock_acquire() {
	local holder
	[ "$LOCK_HELD" -eq 1 ] && return 0
	private_runtime_dir "$RUNTIME_DIR" || return 1
	if mkdir "$LOCK_DIR" 2>/dev/null; then
		[ ! -L "$LOCK_DIR" ] || { rmdir "$LOCK_DIR" 2>/dev/null || true; return 1; }
		chmod 700 "$LOCK_DIR" 2>/dev/null || { rmdir "$LOCK_DIR" 2>/dev/null || true; return 1; }
		printf '%s\n' "$$" > "$LOCK_DIR/pid" 2>/dev/null || { rm -f "$LOCK_DIR/pid"; rmdir "$LOCK_DIR" 2>/dev/null || true; return 1; }
		LOCK_HELD=1
		trap netmode_lock_release EXIT INT TERM
		return 0
	fi
	[ -d "$LOCK_DIR" ] && private_runtime_dir "$LOCK_DIR" || return 1
	holder=$(cat "$LOCK_DIR/pid" 2>/dev/null || true)
	case "$holder" in
		''|*[!0-9]*) return 2;;
		*) kill -0 "$holder" 2>/dev/null && return 2;;
	esac
	# A crashed shell leaves only this private lock directory. Remove exactly the
	# known pid file and directory, then retry once; never recursively remove it.
	rm -f "$LOCK_DIR/pid" 2>/dev/null || return 1
	rmdir "$LOCK_DIR" 2>/dev/null || return 2
	if mkdir "$LOCK_DIR" 2>/dev/null; then
		chmod 700 "$LOCK_DIR" 2>/dev/null || return 1
		printf '%s\n' "$$" > "$LOCK_DIR/pid" 2>/dev/null || return 1
		LOCK_HELD=1
		trap netmode_lock_release EXIT INT TERM
		return 0
	fi
	return 2
}

netmode_lock_wait() {
	local tries rc
	tries=0
	while [ "$tries" -lt 480 ]; do
		netmode_lock_acquire
		rc=$?
		[ "$rc" -eq 0 ] && return 0
		[ "$rc" -eq 1 ] && return 1
		sleep 0.25
		tries=$((tries + 1))
	done
	return 2
}

now() {
	date +%s 2>/dev/null || printf '0\n'
}

get() {
	uci -q get "$1" 2>/dev/null || true
}

set_opt() {
	uci -q set "$1=$2" >/dev/null 2>&1
}

del_opt() {
	uci -q delete "$1" >/dev/null 2>&1 || true
}

commit() {
	uci -q commit "$1" >/dev/null 2>&1
}
static_resolution_reset() {
	static_effective_ipaddr=
	static_effective_netmask=
	static_effective_gateway=
	static_effective_dns=
	static_effective_ipaddr_source=
	static_effective_netmask_source=
	static_effective_gateway_source=
	static_effective_dns_source=
	static_resolve_error=
}

resolve_static_config() {
	local raw_ipaddr raw_netmask raw_gateway raw_dns oem_ready oem_ipaddr oem_netmask oem_gateway oem_dns
	raw_ipaddr=${1-}
	raw_netmask=${2-}
	raw_gateway=${3-}
	raw_dns=${4-}
	static_resolution_reset
	oem_ready=$(get sbair.bridge.oem_baseline_ready)
	oem_ipaddr=
	oem_netmask=
	oem_gateway=
	oem_dns=
	if [ "$oem_ready" = 1 ]; then
		oem_ipaddr=$(get sbair.bridge.oem_ipaddr)
		oem_netmask=$(get sbair.bridge.oem_netmask)
		oem_gateway=$(get sbair.bridge.oem_gateway)
		oem_dns=$(get sbair.bridge.oem_dns)
	fi
	if [ -n "$raw_ipaddr" ]; then
		static_effective_ipaddr=$raw_ipaddr
		static_effective_ipaddr_source='明示指定'
	else
		static_effective_ipaddr=$oem_ipaddr
		[ -n "$static_effective_ipaddr" ] && static_effective_ipaddr_source='純正設定を継承'
	fi
	if [ -n "$raw_netmask" ]; then
		static_effective_netmask=$raw_netmask
		static_effective_netmask_source='明示指定'
	else
		static_effective_netmask=$oem_netmask
		[ -n "$static_effective_netmask" ] && static_effective_netmask_source='純正設定を継承'
	fi
	if [ -n "$raw_gateway" ]; then
		static_effective_gateway=$raw_gateway
		static_effective_gateway_source='明示指定'
	else
		static_effective_gateway=$oem_gateway
		[ -n "$static_effective_gateway" ] && static_effective_gateway_source='純正設定を継承'
	fi
	if [ -n "$raw_dns" ]; then
		static_effective_dns=$raw_dns
		static_effective_dns_source='明示指定'
	else
		static_effective_dns=$oem_dns
		[ -n "$static_effective_dns" ] && static_effective_dns_source='純正設定を継承'
	fi
	if [ -z "$static_effective_ipaddr" ] || ! is_ipv4 "$static_effective_ipaddr"; then
		static_resolve_error='固定IPを解決できません。明示指定するか、先に純正のnetwork.lan.ipaddrを保存できる状態にしてください'
		return 1
	fi
	if [ -z "$static_effective_netmask" ] || ! mask_to_prefix "$static_effective_netmask" >/dev/null 2>&1; then
		static_resolve_error='ネットマスクを解決できません。明示指定するか、先に純正のnetwork.lan.netmaskを保存できる状態にしてください'
		return 1
	fi
	[ -z "$static_effective_gateway" ] || is_ipv4 "$static_effective_gateway" || {
		static_resolve_error='Gateway は有効なIPv4値が必要です'
		return 1
	}
}

ensure_config() {
	local changed mode
	changed=0
	if [ ! -f "$CONFIG" ]; then
		mkdir -p "$(dirname "$CONFIG")"
		printf '%s\n' '# Managed by luci-app-sbair-modem.' > "$CONFIG"
		changed=1
	fi
	if ! uci -q get sbair.bridge >/dev/null 2>&1; then
		set_opt sbair.bridge bridge
		changed=1
	fi
	mode=$(get sbair.bridge.mode)
	if [ "$mode" != sim ] && [ "$mode" != ap ]; then
		# Never infer AP mode from dhcp.lan.ignore. Installing the package must not
		# change a live network; AP is entered only by an explicit apply request.
		mode=sim
		set_opt sbair.bridge.mode "$mode"
		changed=1
	fi
	if [ -z "$(get sbair.bridge.managed)" ]; then
		# A missing marker includes configurations created by the pre-snapshot
		# release. Treat those as unmanaged until the user explicitly applies a
		# mode with this release.
		set_opt sbair.bridge.managed 0
		changed=1
	fi
	if [ -z "$(get sbair.bridge.management_proto)" ]; then
		set_opt sbair.bridge.management_proto dhcp
		changed=1
	fi
	if [ -z "$(get sbair.bridge.oem_baseline_ready)" ]; then
		# Existing installations are explicitly treated as having no proven OEM
		# baseline until an unmanaged -> AP transition captures network.lan.*.
		set_opt sbair.bridge.oem_baseline_ready 0
		changed=1
	fi
	# AP management DHCP is available by default.  Selecting it is still a very
	# high-risk network change: a failed apply can lose every network path and
	# require UART recovery.  The UI displays the warning and Safe Apply cannot
	# guarantee recovery from every failure.
	# SIM mode DHCP is independent and remains available.
	if [ -z "$(get sbair.bridge.ap_dhcp_enabled)" ]; then
		set_opt sbair.bridge.ap_dhcp_enabled 1
		changed=1
	fi
	if [ -z "$(get sbair.bridge.dhcp_server)" ]; then
		set_opt sbair.bridge.dhcp_server 0
		changed=1
	fi
	if [ -z "$(get sbair.bridge.cellular_wan)" ]; then
		set_opt sbair.bridge.cellular_wan 0
		changed=1
	fi
	if [ -z "$(get sbair.bridge.fallback_enabled)" ]; then
		set_opt sbair.bridge.fallback_enabled 1
		changed=1
	fi
	if [ -z "$(get sbair.bridge.fallback_ip)" ]; then
		set_opt sbair.bridge.fallback_ip 192.168.3.1
		changed=1
	fi
	if [ -z "$(get sbair.bridge.fallback_netmask)" ]; then
		set_opt sbair.bridge.fallback_netmask 255.255.255.0
		changed=1
	fi
	if [ -z "$(get sbair.bridge.fallback_timeout)" ]; then
		set_opt sbair.bridge.fallback_timeout 15
		changed=1
	fi
	[ "$changed" -eq 0 ] || commit sbair
}

ap_dhcp_allowed() {
	local value
	# The environment override keeps the switch easy to exercise in the host
	# fixture without changing the device's persistent safety default.
	value=${SBAIR_NETMODE_AP_DHCP_ENABLED-}
	[ -n "$value" ] || value=$(get sbair.bridge.ap_dhcp_enabled)
	[ "$value" = 1 ]
}

validate_ap_proto() {
	local mode proto
	mode=$1
	proto=$2
	if [ "$mode" = ap ] && [ "$proto" = dhcp ] && ! ap_dhcp_allowed; then
		printf '%s\n' 'error=APモードのDHCPクライアントは安全フラグで無効化されています。非常に高リスクなため、sbair.bridge.ap_dhcp_enabled=1を明示的に設定してから適用してください'
		return 1
	fi
}

is_ipv4() {
	local old_ifs octet
	[ $# -eq 1 ] || return 1
	case "$1" in *[!0-9.]*|'') return 1;; esac
	old_ifs=$IFS
	IFS=.
	set -- $1
	IFS=$old_ifs
	[ $# -eq 4 ] || return 1
	for octet in "$@"; do
		[ -n "$octet" ] || return 1
		[ "$octet" -le 255 ] 2>/dev/null || return 1
	done
}

mask_to_prefix() {
	local old_ifs octet bits partial
	[ $# -eq 1 ] || return 1
	old_ifs=$IFS
	IFS=.
	set -- $1
	IFS=$old_ifs
	[ $# -eq 4 ] || return 1
	bits=0
	partial=0
	for octet in "$@"; do
		case "$octet" in
			255)
				[ "$partial" -eq 0 ] || return 1
				bits=$((bits + 8));;
			128)
				[ "$partial" -eq 0 ] || return 1
			bits=$((bits + 1)); partial=1;;
			192)
				[ "$partial" -eq 0 ] || return 1
			bits=$((bits + 2)); partial=1;;
			224)
				[ "$partial" -eq 0 ] || return 1
			bits=$((bits + 3)); partial=1;;
			240)
				[ "$partial" -eq 0 ] || return 1
			bits=$((bits + 4)); partial=1;;
			248)
				[ "$partial" -eq 0 ] || return 1
			bits=$((bits + 5)); partial=1;;
			252)
				[ "$partial" -eq 0 ] || return 1
			bits=$((bits + 6)); partial=1;;
			254)
				[ "$partial" -eq 0 ] || return 1
			bits=$((bits + 7)); partial=1;;
			0) partial=1;;
			*) return 1;;
		esac
	done
	[ "$bits" -ge 1 ] && [ "$bits" -le 32 ] || return 1
	printf '%s\n' "$bits"
}
