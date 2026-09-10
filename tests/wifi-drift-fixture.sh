#!/bin/sh
# SPDX-License-Identifier: MIT
# Host-side fake-command fixture for the monitor-only Wi-Fi drift contract.
set -eu

repo=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT INT TERM
fake="$tmp/bin"
uci_dir="$tmp/uci"
drift="$tmp/drift"
vendor="$tmp/vendor.dat"
lua="$tmp/mtwifi.lua"
beacon="$tmp/bcn_info"
runtime="$tmp/runtime-channel"
uci_mode="$tmp/uci-mode"
uci_log="$tmp/uci.log"
knsh_log="$tmp/knsh.log"
mkdir -p "$fake" "$uci_dir/etc/config" "$drift"
: > "$uci_log"
: > "$knsh_log"
printf '%s\n' 5 > "$runtime"
printf '%s\n' auto > "$uci_mode"
printf '%s\n' 'radio=6G channel_policy=AUTO width=160' > "$vendor"
printf '%s\n' "return '$vendor'" > "$lua"
printf '%s\n' 'beacon_count=42' > "$beacon"

cat > "$uci_dir/etc/config/wireless" <<'EOF'
config wifi-device 'radio0'
	option band '2.4G'
	option channel 'auto'
	option htmode 'HE40'
config wifi-device 'radio1'
	option band '5G'
	option channel 'auto'
	option htmode 'HE160'
config wifi-device 'radio2'
	option band '6G'
	option channel 'auto'
	option htmode 'HE160'
config wifi-iface 'ra0'
	option device 'radio0'
	option mode 'ap'
	option ssid 'fixture-ssid'
	option key 'fixture-secret'
config wifi-iface 'rai0'
	option device 'radio1'
	option mode 'ap'
	option ssid 'fixture-ssid'
	option key 'fixture-secret'
config wifi-iface 'rax0'
	option device 'radio2'
	option mode 'ap'
	option ssid 'fixture-ssid'
	option key 'fixture-secret'
EOF
printf '%s\n' 'config system network' > "$uci_dir/etc/config/knos"

cat > "$fake/uci" <<'EOF'
#!/bin/sh
set -eu
[ "${1:-}" = -q ] && shift
command=${1:-}
shift || true
case "$command" in
show)
	[ "${1:-}" = wireless ] || exit 1
	mode=$(cat "$UCI_MODE_FILE")
	c5=auto
	c6=auto
	if [ "$mode" = fixed ]; then
		c5=36
		c6=5
	fi
	cat <<EOF2
wireless.radio0=wifi-device
wireless.radio0.band='2.4G'
wireless.radio0.channel='auto'
wireless.radio0.htmode='HE40'
wireless.radio1=wifi-device
wireless.radio1.band='5G'
wireless.radio1.channel='$c5'
wireless.radio1.htmode='HE160'
wireless.radio2=wifi-device
wireless.radio2.band='6G'
wireless.radio2.channel='$c6'
wireless.radio2.htmode='HE160'
wireless.ra0=wifi-iface
wireless.ra0.device='radio0'
wireless.ra0.mode='ap'
wireless.ra0.ssid='fixture-ssid'
wireless.ra0.key='fixture-secret'
wireless.rai0=wifi-iface
wireless.rai0.device='radio1'
wireless.rai0.mode='ap'
wireless.rai0.ssid='fixture-ssid'
wireless.rai0.key='fixture-secret'
wireless.rax0=wifi-iface
wireless.rax0.device='radio2'
wireless.rax0.mode='ap'
wireless.rax0.ssid='fixture-ssid'
wireless.rax0.key='fixture-secret'
wireless.apmld1=wifi-iface
wireless.apmld1.mode='ap'
wireless.apmld1.disabled='0'
EOF2
	;;
get)
	case "${1:-}" in
	knos.network.wlan_enabled|knos.network.bandsteering|knos.network.mlo) printf '%s\n' 1;;
	sbair.wifi_drift.enabled) exit 1;;
	*) exit 1;;
	esac
	;;
set|commit)
	printf '%s %s\n' "$command" "$*" >> "$UCI_LOG"
	;;
*) exit 1;;
esac
EOF
chmod 755 "$fake/uci"

cat > "$fake/iw" <<'EOF'
#!/bin/sh
set -eu
[ "${1:-}" = dev ] || exit 1
channel=$(cat "$RUNTIME_CHANNEL_FILE")
case "$channel" in
missing) exit 0;;
5) freq=5975; center=6055;;
21) freq=6055; center=6135;;
36) freq=5180; center=5250;;
40) freq=5200; center=5270;;
*) freq=5975; center=6055;;
esac
cat <<EOF2
phy#0
	Interface rax0
		ifindex 10
		addr 02:00:00:00:00:06
		type AP
		channel $channel ($freq MHz), width: 160 MHz, center1: $center MHz
EOF2
EOF
chmod 755 "$fake/iw"

cat > "$fake/hostapd_cli" <<'EOF'
#!/bin/sh
cat <<'EOF2'
state=ENABLED
freq=5975
channel=5
bssid=02:00:00:00:00:06
ieee80211ax=1
airtime=0
EOF2
EOF
chmod 755 "$fake/hostapd_cli"

cat > "$fake/iwinfo" <<'EOF'
#!/bin/sh
if [ "${2:-}" = assoclist ]; then
	printf '%s\n' '02:00:00:00:00:aa  -40 dBm'
	exit 0
fi
printf '%s\n' 'Tx-Power: 0 dBm'
EOF
chmod 755 "$fake/iwinfo"

cat > "$fake/logread" <<'EOF'
#!/bin/sh
	printf '%s\n' 'knsh key=fixture-key password=secret psk=fixture-secret ssid=fixture-ssid'
EOF
chmod 755 "$fake/logread"

cat > "$fake/ps" <<'EOF'
#!/bin/sh
printf '%s\n' 'PID COMMAND' '1 procd'
EOF
chmod 755 "$fake/ps"

# The monitor must remain disabled when the UCI option is absent.  This is a
# regression guard for the service's previous inverted boolean check.
grep -q 'uci.*sbair.wifi_drift.enabled.*= 1' "$repo/root/etc/init.d/sbair-wifidrift"
grep -q 'return err == nil && v == "1"' "$repo/src/sbair-modem/wifi_drift.go"
grep -q 'for delay in 0 120 300' "$repo/root/usr/sbin/sbair-wifidrift"
grep -q 'sleep 120' "$repo/root/usr/sbin/sbair-wifidrift"

cat > "$fake/knsh" <<'EOF'
#!/bin/sh
set -eu
printf '%s\n' "$*" >> "$KNSH_LOG"
case "$*" in
save) printf '%s\n' save-marker >> "$VENDOR_FILE";;
esac
EOF
chmod 755 "$fake/knsh"

(cd "$repo/src/sbair-modem" && go build -o "$tmp/sbair-modem" .)

run() {
	PATH="$fake:/usr/bin:/bin:/usr/sbin:/sbin" \
	UCI_MODE_FILE="$uci_mode" RUNTIME_CHANNEL_FILE="$runtime" \
	UCI_LOG="$uci_log" KNSH_LOG="$knsh_log" VENDOR_FILE="$vendor" \
	SBAIR_WIFI_DRIFT_DIR="$drift" \
	SBAIR_WIFI_DRIFT_BASELINE="$drift/baseline.json" \
	SBAIR_WIFI_DRIFT_UCI_DIR="$uci_dir/etc/config" \
	SBAIR_MTWIFI_LUA="$lua" SBAIR_WIFI_DRIFT_BEACON="$beacon" \
	"$tmp/sbair-modem" "$@"
}

run wifi-drift snapshot >/dev/null
run wifi-drift mark-good >/dev/null
[ ! -s "$uci_log" ]
[ ! -s "$knsh_log" ]

printf '%s\n' 21 > "$runtime"
run wifi-drift snapshot >/dev/null
status=$(run wifi-drift status)
printf '%s\n' "$status" | grep '"status":"ok"' >/dev/null

printf '%s\n' fixed > "$uci_mode"
run wifi-drift snapshot >/dev/null
status=$(run wifi-drift status)
printf '%s\n' "$status" | grep '"status":"config_drift"' >/dev/null

run wifi-drift mark-good >/dev/null
printf '%s\n' 40 > "$runtime"
run wifi-drift snapshot >/dev/null
status=$(run wifi-drift status)
printf '%s\n' "$status" | grep '"status":"runtime_drift"' >/dev/null

run wifi-drift mark-good >/dev/null
printf '%s\n' 'vendor-change=1' >> "$vendor"
run wifi-drift snapshot >/dev/null
status=$(run wifi-drift status)
printf '%s\n' "$status" | grep '"Vendor persistent"' >/dev/null

printf '%s\n' 5 > "$runtime"
run wifi-drift mark-good >/dev/null
printf '%s\n' missing > "$runtime"
status=$(run wifi-drift status)
printf '%s\n' "$status" | grep '"status":"6g_attention"' >/dev/null
printf '%s\n' 5 > "$runtime"
run wifi-drift snapshot >/dev/null

cat >> "$drift/events.jsonl" <<'EOF'
password="my secret password"
psk='secret with spaces'
ssid="My Home WiFi"
key = value with spaces
export PASSWORD='shell-secret'
{"password":"json-secret"}
https://example.invalid/?token=query-secret
activation_code=confirmation-secret
EOF
logs=$(run wifi-drift logs)
case "$logs" in
	*fixture-key*|*fixture-secret*|*password=secret*|*fixture-ssid*|*my\ secret\ password*|*secret\ with\ spaces*|*My\ Home\ WiFi*|*value\ with\ spaces*|*shell-secret*|*json-secret*|*query-secret*|*confirmation-secret*) exit 1;;
esac
printf '%s\n' "$logs" | grep '<redacted diagnostic line>' >/dev/null
printf '%s\n' "$logs" | grep '<masked diagnostic line>' >/dev/null
rm -f "$drift/events.jsonl"
[ ! -s "$uci_log" ]
[ ! -s "$knsh_log" ]

: > "$knsh_log"
save=$(run wifi-drift save-test)
printf '%s\n' "$save" | grep '"restart_performed":false' >/dev/null
grep -q '^save$' "$knsh_log"
! grep -q 'wlan restart' "$knsh_log"

start=$(run wifi-drift restart-test)
printf '%s\n' "$start" | grep '"restart_performed":true' >/dev/null
busy=$(run wifi-drift restart-test)
printf '%s\n' "$busy" | grep '"busy":true' >/dev/null
done=0
for _ in 1 2 3 4 5 6 7 8; do
	status=$(run wifi-drift status)
	if printf '%s\n' "$status" | grep '"state":"done"' >/dev/null; then
		done=1
		break
	fi
	sleep 1
done
[ "$done" = 1 ]
count=$(grep -c '^wlan restart$' "$knsh_log" || true)
[ "$count" = 1 ]
again=$(run wifi-drift restart-test)
printf '%s\n' "$again" | grep '"restart_performed":true' >/dev/null
done=0
for _ in 1 2 3 4 5 6 7 8; do
	status=$(run wifi-drift status)
	if printf '%s\n' "$status" | grep '"state":"done"' >/dev/null; then
		done=1
		break
	fi
	sleep 1
done
[ "$done" = 1 ]
count=$(grep -c '^wlan restart$' "$knsh_log" || true)
[ "$count" = 2 ]
! grep -R -n -E 'fixture-secret|password=secret|fixture-ssid' "$drift"
printf '%s\n' wifi-drift-fixture-ok
