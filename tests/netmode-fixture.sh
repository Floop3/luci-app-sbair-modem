#!/bin/sh
# SPDX-License-Identifier: MIT
# Small host-side regression fixture for network safety boundaries.
set -eu

repo=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT INT TERM
fake="$tmp/bin"
state="$tmp/uci.state"
uci_log="$tmp/uci.log"
hook_log="$tmp/hook.log"
rule="$tmp/iptables-rule"
dnsmasq_log="$tmp/dnsmasq.log"
udp67_file="$tmp/udp67"
mkdir -p "$fake" "$tmp/etc/config"
: > "$uci_log"
: > "$hook_log"
: > "$dnsmasq_log"

{
	printf 'sbair.bridge\tbridge\n'
	printf 'sbair.bridge.managed\t0\n'
	printf 'sbair.bridge.management_proto\tdhcp\n'
	printf 'network.lan\tinterface\n'
	printf 'network.lan.proto\tdhcp\n'
	printf 'network.lan.ipaddr\t192.168.0.143\n'
	printf 'network.lan.netmask\t255.255.255.0\n'
	printf 'dhcp.lan\tdhcp\n'
	printf 'dhcp.lan.ignore\t1\n'
	printf 'network.wan\tinterface\n'
	printf 'network.wan.proto\tdhcp\n'
	printf 'network.wan.device\tusb0\n'
	printf 'network.wan.disabled\t0\n'
	printf 'network.wan.auto\t1\n'
} > "$state"

cat > "$fake/uci" <<'EOF'
#!/bin/sh
set -eu
[ "${1:-}" = -q ] && shift
state=$UCI_STATE
command=${1:-}
shift || true
case "$command" in
get)
	key=${1:-}
	line=$(awk -F '\t' -v key="$key" '$1 == key { print; exit }' "$state")
	[ -n "$line" ] || exit 1
	printf '%s\n' "${line#*	}"
	;;
set)
	arg=${1:-}
	key=${arg%%=*}
	value=${arg#*=}
	[ "${UCI_FAIL_SET_KEY:-}" = "$key" ] && exit 1
	tmp_state="$state.tmp.$$"
	awk -F '\t' -v key="$key" '$1 != key' "$state" > "$tmp_state"
	printf '%s\t%s\n' "$key" "$value" >> "$tmp_state"
	mv "$tmp_state" "$state"
	;;
delete)
	key=${1:-}
	[ "${UCI_FAIL_DELETE_KEY:-}" = "$key" ] && exit 1
	tmp_state="$state.tmp.$$"
	awk -F '\t' -v key="$key" '$1 != key' "$state" > "$tmp_state"
	mv "$tmp_state" "$state"
	;;
commit)
	[ -z "${UCI_FAIL_COMMIT:-}" ] || exit 1
	;;
*) exit 1;;
esac
EOF
chmod 755 "$fake/uci"

cat > "$fake/iptables" <<'EOF'
#!/bin/sh
set -eu
case "${1:-}" in
-C) [ -f "$IPTABLES_RULE" ];;
-I) : > "$IPTABLES_RULE";;
-D) rm -f "$IPTABLES_RULE";;
*) exit 1;;
esac
EOF
chmod 755 "$fake/iptables"

cat > "$fake/ip" <<'EOF'
#!/bin/sh
if [ "${1:-}" = -4 ] && [ "${2:-}" = -o ] && [ "${3:-}" = addr ]; then
	[ -z "${IP_ADDR_OUTPUT:-}" ] || printf '%s\n' "$IP_ADDR_OUTPUT"
	exit 0
fi
if [ "${1:-}" = route ] && [ -n "${ROUTE_DEVICE:-}" ]; then
	printf '%s\n' "default dev $ROUTE_DEVICE"
	fi
exit 0
EOF
chmod 755 "$fake/ip"

cat > "$fake/ss" <<'EOF'
#!/bin/sh
printf '%s\n' 'Netid State Local Address:Port Peer Address:Port'
[ -f "$UDP67_FILE" ] && printf '%s\n' 'udp UNCONN 0 0 0.0.0.0:67 0.0.0.0:*'
EOF
chmod 755 "$fake/ss"

cat > "$fake/setsid" <<'EOF'
#!/bin/sh
set -eu
if [ "${2:-}" = --rollback-watch ]; then
	exit 0
fi
exec "$@"
EOF
chmod 755 "$fake/setsid"

cat > "$fake/stat" <<'EOF'
#!/bin/sh
# The target BusyBox image does not ship stat(1). Keep the fixture honest by
# failing if the network-mode helper accidentally starts depending on it.
exit 127
EOF
chmod 755 "$fake/stat"

cat > "$fake/dnsmasq-init" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$DNSMASQ_LOG"
: > "$UDP67_FILE"
exit 0
EOF
chmod 755 "$fake/dnsmasq-init"

cat > "$tmp/fake-netmode" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$HOOK_LOG"
EOF
chmod 755 "$tmp/fake-netmode"

state_get() {
	awk -F '\t' -v key="$1" '$1 == key { print substr($0, index($0, "\t") + 1); exit }' "$state"
}

state_set() {
	UCI_STATE="$state" "$fake/uci" -q set "$1=$2"
}

run_netmode() {
	SBAIR_NETMODE_PATH="$fake:/usr/sbin:/usr/bin:/sbin:/bin" \
	SBAIR_NETMODE_CONFIG="$tmp/etc/config/sbair" \
	SBAIR_NETMODE_STATE_DIR="$tmp/netmode" \
	SBAIR_NETMODE_REPAIR_FILE="$tmp/repair" \
	SBAIR_NETMODE_DHCP_START_FILE="$tmp/dhcp-start" \
	SBAIR_NETMODE_CONFLICT_FILE="$tmp/conflict" \
	SBAIR_NETMODE_FALLBACK_FILE="$tmp/fallback" \
	SBAIR_NETMODE_BRIDGE=br-lan \
	SBAIR_NETMODE_SELF="$repo/root/usr/sbin/sbair-netmode" \
	SBAIR_NETMODE_DNSMASQ_INIT="$fake/dnsmasq-init" \
	SBAIR_NETMODE_LOCK_DIR="${NETMODE_LOCK_DIR:-}" \
	UCI_STATE="$state" UCI_FAIL_SET_KEY="${UCI_FAIL_SET_KEY:-}" UCI_FAIL_DELETE_KEY="${UCI_FAIL_DELETE_KEY:-}" UCI_FAIL_COMMIT="${UCI_FAIL_COMMIT:-}" IPTABLES_RULE="$rule" DNSMASQ_LOG="$dnsmasq_log" UDP67_FILE="$udp67_file" ROUTE_DEVICE="${ROUTE_DEVICE:-}" \
	IP_ADDR_OUTPUT="${IP_ADDR_OUTPUT:-}" \
	PATH="$fake:/usr/sbin:/usr/bin:/sbin:/bin" \
	sh "$repo/root/usr/sbin/sbair-netmode" "$@"
}

run_firewall() {
	SBAIR_FIREWALL_PATH="$fake:/usr/sbin:/usr/bin:/sbin:/bin" \
	UCI_STATE="$state" IPTABLES_RULE="$rule" \
	PATH="$fake:/usr/sbin:/usr/bin:/sbin:/bin" \
	sh "$repo/root/usr/share/sbair/firewall.include"
}

wait_transaction() {
	id=$1
	state_file="$tmp/netmode/sbair-netmode-$id.state"
	i=0
	while [ "$i" -lt 25 ]; do
		if [ -f "$state_file" ] && grep -Eq '^state=(applied|confirmed)$' "$state_file"; then
			return 0
		fi
		sleep 1
		i=$((i + 1))
	done
	return 1
}

version_out=$(run_netmode version)
printf '%s\n' "$version_out" | grep -q '^implementation=luci-app-sbair-modem$'
printf '%s\n' "$version_out" | grep -q '^schema=1$'
printf '%s\n' "$version_out" | grep -q '^version=1$'

out=$(run_netmode show)
printf '%s\n' "$out" | grep -q '^mode=unmanaged$'
printf '%s\n' "$out" | grep -q '^configured_mode=sim$'
printf '%s\n' "$out" | grep -q '^managed=0$'
printf '%s\n' "$out" | grep -q '^health=unmanaged$'
[ "$(state_get network.lan.proto)" = dhcp ]
[ "$(state_get dhcp.lan.ignore)" = 1 ]
[ "$(state_get network.wan.proto)" = dhcp ]
[ "$(state_get network.wan.device)" = usb0 ]
[ "$(state_get sbair.bridge.ap_dhcp_enabled)" = 1 ]
printf '%s\n' "$(run_netmode get-config)" | grep '^ap_dhcp_enabled=1$' >/dev/null

# The first explicit SIM claim must not combine the vendor DHCP client with a
# local DHCP server, and rollback must restore the unmanaged baseline exactly.
apply_out=$(run_netmode apply sim)
transaction=$(printf '%s\n' "$apply_out" | sed -n 's/^transaction=//p')
wait_transaction "$transaction"
[ "$(state_get sbair.bridge.managed)" = 1 ]
[ "$(state_get sbair.bridge.mode)" = sim ]
[ "$(state_get network.lan.proto)" = static ]
[ "$(state_get network.lan.ipaddr)" = 192.168.3.1 ]
[ "$(state_get dhcp.lan.ignore)" = 0 ]
grep -q "address=%s" "$repo/root/usr/sbin/sbair-netmode"
! grep -q "address=192\.168\.3\.1" "$repo/root/usr/sbin/sbair-netmode"
run_netmode rollback >/dev/null
[ "$(state_get sbair.bridge.managed)" = 0 ]
[ "$(state_get network.lan.proto)" = dhcp ]
[ "$(state_get network.lan.ipaddr)" = 192.168.0.143 ]
[ "$(state_get dhcp.lan.ignore)" = 1 ]

state_set network.wan.proto ql_datacall
state_set network.wan.device ccmni0
out=$(ROUTE_DEVICE=usb0 run_netmode show)
printf '%s\n' "$out" | grep -q '^cellular.interface=ccmni0$'
printf '%s\n' "$out" | grep -q '^cellular.default_route=0$'
out=$(ROUTE_DEVICE=ccmni0 run_netmode show)
printf '%s\n' "$out" | grep -q '^cellular.default_route=1$'
state_set network.wan.proto dhcp
state_set network.wan.device usb0

out=$(run_netmode set-config \
	proto=static ipaddr=192.168.3.2 netmask=255.255.255.0 \
	gateway=192.168.3.254 dns=192.168.3.254 fallback_enabled=1 \
	fallback_ip=192.168.3.1 fallback_netmask=255.255.255.0 fallback_timeout=15)
printf '%s\n' "$out" | grep -q '^draft=1$'
[ "$(state_get sbair.bridge.management_proto)" = dhcp ]
[ "$(state_get sbair.bridge.draft_proto)" = static ]
printf '%s\n' "$(run_netmode get-config)" | grep '^draft=1$' >/dev/null

cp "$repo/root/etc/uci-defaults/luci-app-sbair-modem" "$tmp/uci-defaults"
UCI_STATE="$state" PATH="$fake:/usr/sbin:/usr/bin:/sbin:/bin" sh "$tmp/uci-defaults"
[ "$(state_get firewall.sbair_dhcp_guard)" = include ]
[ "$(state_get firewall.sbair_dhcp_guard.type)" = script ]
[ "$(state_get firewall.sbair_dhcp_guard.path)" = /usr/share/sbair/firewall.include ]
[ "$(state_get firewall.sbair_dhcp_guard.reload)" = 1 ]

state_set sbair.bridge.mode ap
state_set sbair.bridge.managed 0
run_firewall
[ ! -f "$rule" ]
state_set sbair.bridge.managed 1
run_firewall
[ -f "$rule" ]
rm -f "$rule"
run_firewall
[ -f "$rule" ]
run_firewall
[ -f "$rule" ]
state_set sbair.bridge.mode sim
run_firewall
[ ! -f "$rule" ]

state_set sbair.bridge.mode ap
state_set sbair.bridge.managed 1
printf '%s\n' marker > "$tmp/dhcp-start"
printf '%s\n' marker > "$tmp/conflict"
run_netmode dhcp-event wan eth0 bound
[ -f "$tmp/dhcp-start" ]
[ -f "$tmp/conflict" ]
run_netmode dhcp-event unknown eth1 renew
[ -f "$tmp/dhcp-start" ]
[ -f "$tmp/conflict" ]
run_netmode dhcp-event lan eth0 deconfig
[ -f "$tmp/dhcp-start" ]
[ -f "$tmp/conflict" ]
run_netmode dhcp-event lan eth0 bound
[ ! -f "$tmp/dhcp-start" ]
[ ! -f "$tmp/conflict" ]

# Explicitly disabling the safety gate must still reject AP DHCP. A legacy
# active AP DHCP config is migrated to the recovery static address by
# startup/repair.
state_set sbair.bridge.ap_dhcp_enabled 0
if run_netmode apply ap \
	proto=dhcp ipaddr=192.168.0.143 netmask=255.255.255.0 \
	gateway= dns= fallback_enabled=1 fallback_ip=192.168.3.1 \
	fallback_netmask=255.255.255.0 fallback_timeout=15 >/dev/null 2>&1; then
	printf '%s\n' 'AP DHCP apply was accepted while disabled' >&2
	exit 1
fi
[ "$(state_get sbair.bridge.management_proto)" = dhcp ]
state_set network.lan.ipaddr ''
state_set network.lan.netmask ''
run_netmode startup >/dev/null
[ "$(state_get sbair.bridge.management_proto)" = static ]
[ "$(state_get sbair.bridge.ipaddr)" = 192.168.3.1 ]
[ "$(state_get sbair.bridge.netmask)" = 255.255.255.0 ]
[ "$(state_get network.lan.proto)" = static ]
[ "$(state_get network.lan.ipaddr)" = 192.168.3.1 ]
[ "$(state_get dhcp.lan.ignore)" = 1 ]

hook="$repo/root/etc/udhcpc.user.d/sbair-fallback"
: > "$hook_log"
PATH="$fake:/usr/sbin:/usr/bin:/sbin:/bin" UCI_STATE="$state" \
	HOOK_LOG="$hook_log" SBAIR_NETMODE_BIN="$tmp/fake-netmode" \
	INTERFACE=lan interface=br-lan ACTION=bound sh "$hook"
PATH="$fake:/usr/sbin:/usr/bin:/sbin:/bin" UCI_STATE="$state" \
	HOOK_LOG="$hook_log" SBAIR_NETMODE_BIN="$tmp/fake-netmode" \
	INTERFACE=wan interface=eth0 ACTION=bound sh "$hook"
PATH="$fake:/usr/sbin:/usr/bin:/sbin:/bin" UCI_STATE="$state" \
	HOOK_LOG="$hook_log" SBAIR_NETMODE_BIN="$tmp/fake-netmode" \
	INTERFACE=unknown interface=eth1 ACTION=renew sh "$hook"
PATH="$fake:/usr/sbin:/usr/bin:/sbin:/bin" UCI_STATE="$state" \
	HOOK_LOG="$hook_log" SBAIR_NETMODE_BIN="$tmp/fake-netmode" \
	INTERFACE=wan interface=br-lan ACTION=renew sh "$hook"
PATH="$fake:/usr/sbin:/usr/bin:/sbin:/bin" UCI_STATE="$state" \
	HOOK_LOG="$hook_log" SBAIR_NETMODE_BIN="$tmp/fake-netmode" \
	INTERFACE=lan interface=br-lan sh "$hook" bound
PATH="$fake:/usr/sbin:/usr/bin:/sbin:/bin" UCI_STATE="$state" \
	HOOK_LOG="$hook_log" SBAIR_NETMODE_BIN="$tmp/fake-netmode" \
	sh "$hook" lan br-lan bound
[ "$(wc -l < "$hook_log" | tr -d ' ')" = 4 ]

# An AP->AP Safe Apply must snapshot the live transaction immediately before
# promotion. A stale draft_prev_* from an older release must not win rollback.
state_set sbair.bridge.mode ap
state_set sbair.bridge.managed 1
state_set sbair.bridge.management_proto static
state_set sbair.bridge.ipaddr 192.168.3.10
state_set sbair.bridge.netmask 255.255.255.0
state_set sbair.bridge.gateway 192.168.3.1
state_set sbair.bridge.dns 192.168.3.1
state_set sbair.bridge.fallback_enabled 1
state_set sbair.bridge.fallback_ip 192.168.3.11
state_set sbair.bridge.fallback_netmask 255.255.255.0
state_set sbair.bridge.fallback_timeout 20
state_set sbair.bridge.dhcp_server 0
state_set sbair.bridge.cellular_wan 0
state_set network.lan.proto static
state_set network.lan.ipaddr 192.168.3.10
state_set network.lan.netmask 255.255.255.0
state_set network.lan.gateway 192.168.3.1
state_set network.lan.dns 192.168.3.1
state_set network.lan.delegate 0
state_set dhcp.lan.ignore 1
state_set dhcp.lan.ra disabled
state_set dhcp.lan.dhcpv6 disabled
state_set dhcp.lan.ndp disabled
state_set dhcp.lan.start 100
state_set dhcp.lan.limit 50
state_set dhcp.lan.leasetime 12h
state_set network.wan.disabled 1
state_set network.wan.auto 0
state_set sbair.bridge.dhcp_start 100
state_set sbair.bridge.dhcp_limit 50
state_set sbair.bridge.dhcp_leasetime 12h
state_set sbair.bridge.draft_prev_snapshot_ready 1
state_set sbair.bridge.draft_prev_ipaddr 192.168.99.99
apply_out=$(run_netmode apply ap \
	proto=static ipaddr=192.168.3.20 netmask=255.255.255.0 \
	gateway=192.168.3.254 dns=192.168.3.254 fallback_enabled=1 \
	fallback_ip=192.168.3.21 fallback_netmask=255.255.255.0 fallback_timeout=25)
transaction=$(printf '%s\n' "$apply_out" | sed -n 's/^transaction=//p')
wait_transaction "$transaction"
[ "$(state_get sbair.bridge.pending_prev_ipaddr)" = 192.168.3.10 ]
[ "$(state_get sbair.bridge.pending_prev_fallback_ip)" = 192.168.3.11 ]
[ -z "$(state_get sbair.bridge.draft_prev_ipaddr)" ]
run_netmode rollback >/dev/null
[ "$(state_get sbair.bridge.mode)" = ap ]
[ "$(state_get sbair.bridge.managed)" = 1 ]
[ "$(state_get sbair.bridge.management_proto)" = static ]
[ "$(state_get sbair.bridge.ipaddr)" = 192.168.3.10 ]
[ "$(state_get sbair.bridge.netmask)" = 255.255.255.0 ]
[ "$(state_get sbair.bridge.gateway)" = 192.168.3.1 ]
[ "$(state_get sbair.bridge.dns)" = 192.168.3.1 ]
[ "$(state_get sbair.bridge.fallback_enabled)" = 1 ]
[ "$(state_get sbair.bridge.fallback_ip)" = 192.168.3.11 ]
[ "$(state_get sbair.bridge.fallback_netmask)" = 255.255.255.0 ]
[ "$(state_get sbair.bridge.fallback_timeout)" = 20 ]
[ "$(state_get network.lan.proto)" = static ]
[ "$(state_get network.lan.ipaddr)" = 192.168.3.10 ]
[ "$(state_get network.lan.netmask)" = 255.255.255.0 ]
[ "$(state_get network.lan.gateway)" = 192.168.3.1 ]
[ "$(state_get network.lan.dns)" = 192.168.3.1 ]
[ "$(state_get network.lan.delegate)" = 0 ]
[ "$(state_get dhcp.lan.ignore)" = 1 ]
[ "$(state_get dhcp.lan.ra)" = disabled ]
[ "$(state_get dhcp.lan.dhcpv6)" = disabled ]
[ "$(state_get dhcp.lan.ndp)" = disabled ]
[ "$(state_get dhcp.lan.start)" = 100 ]
[ "$(state_get dhcp.lan.limit)" = 50 ]
[ "$(state_get dhcp.lan.leasetime)" = 12h ]
[ "$(state_get sbair.bridge.dhcp_start)" = 100 ]
[ "$(state_get sbair.bridge.dhcp_limit)" = 50 ]
[ "$(state_get sbair.bridge.dhcp_leasetime)" = 12h ]
[ "$(state_get network.wan.disabled)" = 1 ]
[ "$(state_get network.wan.auto)" = 0 ]
[ -z "$(state_get sbair.bridge.pending_prev_snapshot_ready)" ]
[ -z "$(state_get sbair.bridge.draft_prev_snapshot_ready)" ]

# Releasing management must leave the live vendor network untouched.
run_netmode unmanage >/dev/null
[ "$(state_get sbair.bridge.managed)" = 0 ]
[ "$(state_get network.lan.proto)" = static ]
[ "$(state_get network.lan.ipaddr)" = 192.168.3.10 ]
[ "$(state_get dhcp.lan.ignore)" = 1 ]
[ "$(state_get network.wan.disabled)" = 1 ]
[ -z "$(state_get sbair.bridge.dhcp_start)" ]

# SIM/recover paths must explicitly restart dnsmasq and verify UDP/67.
: > "$dnsmasq_log"
rm -f "$udp67_file"
apply_out=$(run_netmode apply sim)
transaction=$(printf '%s\n' "$apply_out" | sed -n 's/^transaction=//p')
wait_transaction "$transaction"
grep -q '^restart$' "$dnsmasq_log"
[ -f "$udp67_file" ]
[ "$(state_get network.lan.proto)" = static ]
[ "$(state_get network.lan.ipaddr)" = 192.168.3.1 ]
[ "$(state_get dhcp.lan.ignore)" = 0 ]

if run_netmode unmanage >/dev/null 2>&1; then
	printf '%s\n' 'unmanage was allowed while a transaction was pending' >&2
	exit 1
fi
run_netmode confirm >/dev/null

# The switch is reversible without changing the implementation: enabling the
# UCI flag permits an explicit AP DHCP apply again, and rollback restores SIM.
state_set sbair.bridge.ap_dhcp_enabled 1
# Legacy `ap` and `sim` callers must enter the same transaction path as apply.
for alias in ap sim; do
	alias_out=$(run_netmode "$alias")
	alias_transaction=$(printf '%s\n' "$alias_out" | sed -n 's/^transaction=//p')
	[ -n "$alias_transaction" ]
	wait_transaction "$alias_transaction"
	grep -Eq '^state=(applied|confirmed)$' "$tmp/netmode/sbair-netmode-$alias_transaction.state"
	run_netmode rollback >/dev/null
done

apply_out=$(run_netmode apply ap \
	proto=dhcp ipaddr=192.168.0.143 netmask=255.255.255.0 \
	gateway= dns= fallback_enabled=1 fallback_ip=192.168.3.1 \
	fallback_netmask=255.255.255.0 fallback_timeout=15)
transaction=$(printf '%s\n' "$apply_out" | sed -n 's/^transaction=//p')
wait_transaction "$transaction"
[ "$(state_get sbair.bridge.management_proto)" = dhcp ]
[ "$(state_get network.lan.proto)" = dhcp ]
run_netmode rollback >/dev/null
[ "$(state_get sbair.bridge.mode)" = sim ]
[ "$(state_get network.lan.proto)" = static ]
state_set sbair.bridge.ap_dhcp_enabled 0

# Two different applies started together still produce only one transaction.
# The loser must observe the cross-process lock and must not mutate UCI.
rm -f "$tmp/apply-one.out" "$tmp/apply-two.out"
run_netmode apply sim >"$tmp/apply-one.out" 2>&1 & apply_one_pid=$!
run_netmode apply ap \
	proto=static ipaddr=192.168.3.40 netmask=255.255.255.0 \
	gateway=192.168.3.1 dns=192.168.3.1 fallback_enabled=1 \
	fallback_ip=192.168.3.41 fallback_netmask=255.255.255.0 fallback_timeout=15 \
	>"$tmp/apply-two.out" 2>&1 & apply_two_pid=$!
if wait "$apply_one_pid"; then :; fi
if wait "$apply_two_pid"; then :; fi
transaction_count=$(grep -h -c '^transaction=' "$tmp/apply-one.out" "$tmp/apply-two.out" | awk '{total += $1} END {print total + 0}')
[ "$transaction_count" = 1 ]
grep -h -q 'another network-mode transaction\|awaiting confirmation' "$tmp/apply-one.out" "$tmp/apply-two.out"
pending_id=$(state_get sbair.bridge.pending_id)
[ -n "$pending_id" ]
wait_transaction "$pending_id"
run_netmode rollback >/dev/null

# A live cross-process transaction lock must stop before ensure_config,
# snapshot, UCI promotion, network reload, or worker spawn.
cp "$state" "$tmp/lock-before"
mkdir "$tmp/held-netmode-lock"
printf '%s\n' "$$" > "$tmp/held-netmode-lock/pid"
if NETMODE_LOCK_DIR="$tmp/held-netmode-lock" run_netmode apply sim >/dev/null 2>&1; then
	printf '%s\n' 'apply bypassed the cross-process lock' >&2
	exit 1
fi
cmp -s "$tmp/lock-before" "$state"
rm -f "$tmp/held-netmode-lock/pid"
rmdir "$tmp/held-netmode-lock"

# A snapshot set failure or commit failure must never promote a pending
# transaction. The live LAN configuration remains untouched.
cp "$state" "$tmp/snapshot-before"
if UCI_FAIL_SET_KEY=sbair.bridge.pending_prev_mode run_netmode apply ap \
	proto=static ipaddr=192.168.3.30 netmask=255.255.255.0 \
	gateway=192.168.3.1 dns=192.168.3.1 fallback_enabled=1 fallback_ip=192.168.3.1 \
	fallback_netmask=255.255.255.0 fallback_timeout=15 >/dev/null 2>&1; then
	printf '%s\n' 'snapshot set failure was accepted' >&2
	exit 1
fi
[ -z "$(state_get sbair.bridge.pending_id)" ]
[ "$(state_get network.lan.proto)" = static ]
[ "$(state_get network.lan.ipaddr)" = 192.168.3.1 ]
if UCI_FAIL_COMMIT=1 run_netmode apply ap \
	proto=static ipaddr=192.168.3.31 netmask=255.255.255.0 \
	gateway=192.168.3.1 dns=192.168.3.1 fallback_enabled=1 fallback_ip=192.168.3.1 \
	fallback_netmask=255.255.255.0 fallback_timeout=15 >/dev/null 2>&1; then
	printf '%s\n' 'snapshot commit failure was accepted' >&2
	exit 1
fi
[ -z "$(state_get sbair.bridge.pending_id)" ]
[ "$(state_get network.lan.ipaddr)" = 192.168.3.1 ]

# A first unmanaged -> AP transition captures the live logical OEM LAN once.
# Blank raw fields inherit that baseline; they must not inherit the recovery
# Fallback address.
unset NETMODE_LOCK_DIR UCI_FAIL_SET_KEY UCI_FAIL_COMMIT
state_set sbair.bridge.mode sim
state_set sbair.bridge.managed 0
state_set sbair.bridge.management_proto static
state_set sbair.bridge.ipaddr ''
state_set sbair.bridge.netmask ''
state_set sbair.bridge.gateway ''
state_set sbair.bridge.dns ''
state_set sbair.bridge.oem_baseline_ready 0
state_set sbair.bridge.oem_ipaddr ''
state_set sbair.bridge.oem_netmask ''
state_set sbair.bridge.oem_gateway ''
state_set sbair.bridge.oem_dns ''
state_set sbair.bridge.fallback_ip 192.168.3.1
state_set sbair.bridge.fallback_netmask 255.255.255.0
state_set sbair.bridge.fallback_timeout 15
state_set network.lan.proto static
state_set network.lan.ipaddr 198.51.100.11
state_set network.lan.netmask 255.255.255.0
state_set network.lan.gateway 198.51.100.1
state_set network.lan.dns 198.51.100.1
apply_out=$(run_netmode apply ap \
	proto=static ipaddr= netmask= gateway= dns= fallback_enabled=1 \
	fallback_ip=192.168.3.1 fallback_netmask=255.255.255.0 fallback_timeout=15)
transaction=$(printf '%s\n' "$apply_out" | sed -n 's/^transaction=//p')
wait_transaction "$transaction"
[ "$(state_get sbair.bridge.oem_baseline_ready)" = 1 ]
[ "$(state_get sbair.bridge.oem_ipaddr)" = 198.51.100.11 ]
[ "$(state_get sbair.bridge.oem_netmask)" = 255.255.255.0 ]
[ "$(state_get sbair.bridge.oem_gateway)" = 198.51.100.1 ]
[ "$(state_get sbair.bridge.ipaddr)" = '' ]
[ "$(state_get sbair.bridge.netmask)" = '' ]
[ "$(state_get network.lan.ipaddr)" = 198.51.100.11 ]
[ "$(state_get network.lan.netmask)" = 255.255.255.0 ]
[ "$(state_get network.lan.gateway)" = 198.51.100.1 ]
[ "$(state_get network.lan.dns)" = 198.51.100.1 ]
config_out=$(run_netmode get-config)
printf '%s\n' "$config_out" | grep '^ipaddr=$' >/dev/null
printf '%s\n' "$config_out" | grep '^netmask=$' >/dev/null
printf '%s\n' "$config_out" | grep '^effective.ipaddr=198.51.100.11$' >/dev/null
printf '%s\n' "$config_out" | grep '^effective.ipaddr_source=純正設定を継承$' >/dev/null
printf '%s\n' "$config_out" | grep '^effective.netmask_source=純正設定を継承$' >/dev/null
run_netmode confirm >/dev/null

# Mixed override: only explicitly entered fields replace the OEM baseline.
apply_out=$(run_netmode apply ap \
	proto=static ipaddr=198.51.100.21 netmask= gateway= dns= fallback_enabled=1 \
	fallback_ip=192.168.3.1 fallback_netmask=255.255.255.0 fallback_timeout=15)
transaction=$(printf '%s\n' "$apply_out" | sed -n 's/^transaction=//p')
wait_transaction "$transaction"
[ "$(state_get network.lan.ipaddr)" = 198.51.100.21 ]
[ "$(state_get network.lan.netmask)" = 255.255.255.0 ]
[ "$(state_get network.lan.gateway)" = 198.51.100.1 ]
[ "$(state_get network.lan.dns)" = 198.51.100.1 ]
[ "$(state_get sbair.bridge.oem_ipaddr)" = 198.51.100.11 ]
run_netmode rollback >/dev/null
[ "$(state_get network.lan.ipaddr)" = 198.51.100.11 ]
[ "$(state_get network.lan.gateway)" = 198.51.100.1 ]
[ "$(state_get sbair.bridge.oem_ipaddr)" = 198.51.100.11 ]

# A managed device without a proven OEM baseline must reject inherited required
# fields before touching network.lan. The live address is not a substitute.
state_set sbair.bridge.mode ap
state_set sbair.bridge.managed 1
state_set sbair.bridge.management_proto static
state_set sbair.bridge.ipaddr ''
state_set sbair.bridge.netmask ''
state_set sbair.bridge.gateway ''
state_set sbair.bridge.dns ''
state_set sbair.bridge.oem_baseline_ready 0
state_set network.lan.ipaddr 192.168.70.11
state_set network.lan.netmask 255.255.255.0
if run_netmode apply ap \
	proto=static ipaddr= netmask= gateway= dns= fallback_enabled=1 \
	fallback_ip=192.168.3.1 fallback_netmask=255.255.255.0 fallback_timeout=15 \
	>"$tmp/netmode-oem-reject.out" 2>&1; then
	printf '%s\n' 'inherited static configuration was accepted without an OEM baseline' >&2
	exit 1
fi
grep -q '固定IPを解決できません' "$tmp/netmode-oem-reject.out"
[ -z "$(state_get sbair.bridge.pending_id)" ]
[ "$(state_get network.lan.ipaddr)" = 192.168.70.11 ]

# Repair and startup use the same effective values as initial apply.
state_set sbair.bridge.oem_baseline_ready 1
state_set sbair.bridge.oem_ipaddr 198.51.100.11
state_set sbair.bridge.oem_netmask 255.255.255.0
state_set sbair.bridge.oem_gateway 198.51.100.1
state_set sbair.bridge.oem_dns 198.51.100.1
state_set network.lan.ipaddr 198.51.100.99
state_set network.lan.netmask 255.255.255.0
run_netmode repair >/dev/null
[ "$(state_get network.lan.ipaddr)" = 198.51.100.11 ]
[ "$(state_get network.lan.gateway)" = 198.51.100.1 ]
state_set network.lan.ipaddr 198.51.100.98
run_netmode startup >/dev/null
[ "$(state_get network.lan.ipaddr)" = 198.51.100.11 ]

grep -q 'for mark in 0x102 0x202 0x302' "$repo/root/usr/sbin/sbair-netfix"
grep -q 'SNAPSHOT_KEYS=.*managed' "$repo/root/usr/sbin/sbair-netmode"
grep -Fq 'if [ "$previous_mode" = ap ] && [ "$previous_managed" = 1 ]; then' "$repo/root/usr/sbin/sbair-netmode"
grep -Fq 'set_opt network.lan.proto static' "$repo/root/usr/sbin/sbair-netmode"
grep -Fq 'oem_baseline_ready' "$repo/root/usr/sbin/sbair-netmode"

# A healthy AP DHCP client is automatically confirmed after the target verifies
# that the new management address is present. This prevents the browser from
# having to confirm through the old address after a DHCP move.
state_set sbair.bridge.ap_dhcp_enabled 1
state_set sbair.bridge.mode ap
state_set sbair.bridge.managed 1
state_set sbair.bridge.management_proto dhcp
auto_apply_out=$(IP_ADDR_OUTPUT='2: br-lan    inet 198.51.100.197/24 brd 198.51.100.255 scope global br-lan' run_netmode apply ap \
	proto=dhcp ipaddr= netmask= gateway= dns= fallback_enabled=1 fallback_ip=192.168.3.1 \
	fallback_netmask=255.255.255.0 fallback_timeout=15)
auto_transaction=$(printf '%s\n' "$auto_apply_out" | sed -n 's/^transaction=//p')
wait_transaction "$auto_transaction"
grep -q '^state=confirmed$' "$tmp/netmode/sbair-netmode-$auto_transaction.state"
[ -z "$(state_get sbair.bridge.pending_id)" ]
[ "$(state_get network.lan.proto)" = dhcp ]
state_set sbair.bridge.ap_dhcp_enabled 0

# Recovery output must describe the address selected by the transaction rather
# than relying on a hard-coded status message.
recover_out=$(run_netmode recover)
printf '%s\n' "$recover_out" | grep -q '^result=recovered$'
printf '%s\n' "$recover_out" | grep -q '^address=192\.168\.3\.1$'

printf '%s\n' netmode-fixture-ok
