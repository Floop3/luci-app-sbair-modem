#!/bin/sh
# Small mocked safety fixture for the optional USB CDC-NCM gadget helper.
set -eu

repo=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT INT TERM

fakebin=$tmp/bin
bundle=$tmp/bundle
state=$tmp/state
gadget=$tmp/configfs/usb_gadget
udc=$tmp/sys/udc
net=$tmp/sys/net
modules=$tmp/sys/module
proc_modules=$tmp/proc.modules
release=$tmp/openwrt_release
mkdir -p "$fakebin" "$bundle" "$gadget/g1" "$udc/11201000.usb" "$net/br-lan" "$modules"
: > "$proc_modules"
printf '%s\n' \
	"DISTRIB_RELEASE='21.02.7'" \
	"DISTRIB_TARGET='gem6xxx/evb6990_cpe_mt7990_emmc'" \
	"DISTRIB_ARCH='aarch64_cortex-a55_neon-vfpv4'" > "$release"
printf '%s\n' idle > "$udc/11201000.usb/state"
printf '%s\n' high-speed > "$udc/11201000.usb/current_speed"
: > "$gadget/g1/UDC"

cat > "$fakebin/sha256sum" <<'EOF'
#!/bin/sh
if [ "${SBAIR_TEST_BAD_HASH:-0}" = 1 ]; then
	printf '%s  %s\n' bad "$1"
else
	printf '%s  %s\n' 7f0e5f3ec197a5f80f23195a3945a2d700bca9d97b8c04eadbacb02c247523c1 "$1"
fi
EOF
cat > "$fakebin/modinfo" <<'EOF'
#!/bin/sh
if [ "${SBAIR_TEST_BAD_VERMAGIC:-0}" = 1 ]; then
	printf '%s\n' wrong
else
	printf '%s\n' '5.4.238 SMP mod_unload modversions aarch64'
fi
EOF
cat > "$fakebin/uname" <<'EOF'
#!/bin/sh
case "${1:-}" in
  -r) printf '%s\n' "${SBAIR_TEST_KERNEL:-5.4.238}" ;;
  -m) printf '%s\n' aarch64 ;;
  *) /usr/bin/uname "$@" ;;
esac
EOF
cat > "$fakebin/ip" <<'EOF'
#!/bin/sh
if [ "$1" = -4 ] && [ "$2" = addr ] && [ "$3" = show ]; then
	if [ "$4" = br-lan ]; then
		printf '%s\n' '2: br-lan    inet 198.51.100.100/24'
		exit 0
	fi
	if [ "$4" = dev ] && [ "$5" = usb0 ]; then
		printf '%s\n' '3: usb0'
		if [ -f "$SBAIR_USB_NIC_NET_ROOT/usb0/address" ]; then
			printf '    inet %s\n' "$(cat "$SBAIR_USB_NIC_NET_ROOT/usb0/address")"
		fi
		exit 0
	fi
fi
if [ "$1" = addr ] && [ "$2" = add ]; then
	printf '%s\n' "${3:-}" > "$SBAIR_USB_NIC_NET_ROOT/usb0/address"
	exit 0
fi
if [ "$1" = addr ] && [ "$2" = del ]; then
	rm -f "$SBAIR_USB_NIC_NET_ROOT/usb0/address"
	exit 0
fi
if [ "$1" = link ] && [ "$2" = set ]; then
	printf '%s\n' "$4" > "$SBAIR_USB_NIC_NET_ROOT/usb0/operstate"
	exit 0
fi
exit 0
EOF
cat > "$fakebin/insmod" <<'EOF'
#!/bin/sh
	module=$(basename "$1" .ko)
	mkdir -p "$SBAIR_USB_NIC_SYS_MODULE_ROOT/$module" "$SBAIR_USB_NIC_NET_ROOT/usb0"
	printf '%s\n' down > "$SBAIR_USB_NIC_NET_ROOT/usb0/operstate"
	printf '%s\n' 0 > "$SBAIR_USB_NIC_NET_ROOT/usb0/carrier"
	printf '%s 0 0 - Live 0x0\n' "$module" >> "$SBAIR_USB_NIC_PROC_MODULES"
EOF
cat > "$fakebin/find" <<'EOF'
#!/bin/sh
/usr/bin/find "$1" -print
EOF
chmod 755 "$fakebin"/*

helper=$repo/root/usr/sbin/sbair-usb-nic
env_base="SBAIR_USB_NIC_PATH=$fakebin:/usr/sbin:/usr/bin:/sbin:/bin SBAIR_USB_NIC_BUNDLE_DIR=$bundle SBAIR_USB_NIC_STATE_DIR=$state SBAIR_USB_NIC_PROFILE=$tmp/no-profile SBAIR_USB_NIC_GADGET_ROOT=$gadget SBAIR_USB_NIC_UDC_ROOT=$udc SBAIR_USB_NIC_NET_ROOT=$net SBAIR_USB_NIC_SYS_MODULE_ROOT=$modules SBAIR_USB_NIC_PROC_MODULES=$proc_modules SBAIR_USB_NIC_RELEASE_FILE=$release"
run_helper() {
	# shellcheck disable=SC2086
	env $env_base \
		SBAIR_USB_NIC_PROFILE="${SBAIR_USB_NIC_PROFILE-$tmp/no-profile}" \
		SBAIR_TEST_BAD_HASH="${SBAIR_TEST_BAD_HASH-}" \
		SBAIR_TEST_BAD_VERMAGIC="${SBAIR_TEST_BAD_VERMAGIC-}" \
		SBAIR_TEST_KERNEL="${SBAIR_TEST_KERNEL-}" \
		"$@"
}
fail() { echo "fixture failure: $*" >&2; exit 1; }

out=$(run_helper "$helper" status)
echo "$out" | grep -q '^bundle=missing$' || fail 'missing bundle state'
echo "$out" | grep -q '^runtime=preflight-ng$' || fail 'missing bundle must not be ready'
echo "$out" | grep -q '^preflight=ng$' || fail 'missing bundle preflight'
[ ! -e "$state" ] || fail 'status/preflight created state in read-only mode'

printf synthetic > "$bundle/t6a_usb_ncm_65532_candidate_v1.ko"
cp "$repo/extras/usb-nic/driver.lock" "$bundle/driver.lock"
chmod 600 "$bundle/driver.lock"
out=$(SBAIR_TEST_BAD_HASH=1 run_helper "$helper" status)
echo "$out" | grep -q '^bundle=invalid-hash$' || fail 'invalid hash was accepted'
echo "$out" | grep -q '^preflight_reason=bundle-sha256-mismatch$' || fail 'hash reason missing'
! echo "$out" | grep -Eq '0abc|02:00:00' || fail 'profile values leaked before profile exists'

out=$(SBAIR_TEST_KERNEL=wrong run_helper "$helper" status)
echo "$out" | grep -q '^preflight_reason=unsupported-kernel$' || fail 'kernel mismatch was accepted'
out=$(SBAIR_TEST_BAD_VERMAGIC=1 run_helper "$helper" status)
echo "$out" | grep -q '^preflight_reason=bundle-vermagic-mismatch$' || fail 'vermagic mismatch was accepted'

rm -rf "$udc/11201000.usb"
out=$(run_helper "$helper" status)
echo "$out" | grep -q '^preflight_reason=udc-missing$' || fail 'missing UDC was accepted'
mkdir -p "$udc/11201000.usb"
printf '%s\n' idle > "$udc/11201000.usb/state"
printf '%s\n' high-speed > "$udc/11201000.usb/current_speed"
: > "$gadget/g1/UDC"

out=$(run_helper "$helper" status)
echo "$out" | grep -q '^bundle=installed$' || fail 'valid bundle was not detected'
echo "$out" | grep -q '^profile=missing$' || fail 'missing profile state'
if run_helper "$helper" enable --ack >/dev/null 2>&1; then fail 'enable succeeded without a profile'; fi
[ ! -e "$gadget/t6a_ncm_test" ] || fail 'profile gate created a gadget'

cat > "$tmp/profile" <<'EOF'
VID_HEX=0abc
PID_HEX=1234
DEV_MAC=02:00:00:00:00:01
HOST_MAC=02:00:00:00:00:02
USB0_ADDR=192.0.2.2/30
PEER_IPV4=192.0.2.1
EOF
chmod 600 "$tmp/profile"
mkdir -p "$tmp/profile-dir"
cp "$tmp/profile" "$tmp/profile-dir/profile"
chmod 600 "$tmp/profile-dir/profile"

out=$(SBAIR_USB_NIC_PROFILE="$tmp/profile-dir/profile" run_helper "$helper" status)
echo "$out" | grep -q '^profile=valid$' || fail 'valid profile was rejected'
echo "$out" | grep -q '^preflight=ok$' || fail 'mocked preflight was not ready'
[ "$(printf '%s\n' "$out" | awk -F= '$1 == "loaded_usb_modules" { count++ } END { print count + 0 }')" = 1 ] || fail 'status emitted duplicate loaded_usb_modules fields'
! echo "$out" | grep -Eq '0abc|02:00:00|192\.0\.2' || fail 'profile values leaked in status'

mkdir -p "$gadget/t6a_ncm_test"
out=$(SBAIR_USB_NIC_PROFILE="$tmp/profile-dir/profile" run_helper "$helper" status)
echo "$out" | grep -q '^preflight_reason=custom-gadget-already-exists$' || fail 'custom conflict was accepted'
rm -rf "$gadget/t6a_ncm_test"

out=$(SBAIR_USB_NIC_PROFILE="$tmp/profile-dir/profile" run_helper "$helper" enable --ack)
echo "$out" | grep -q '^result=enabled$' || fail 'enable did not complete'
echo "$out" | grep -q '^runtime=active$' || fail 'enable runtime state'
[ -L "$gadget/t6a_ncm_test/configs/c.1/t6a_ncm.test0" ] || fail 'exact function link missing'
[ "$(readlink "$gadget/t6a_ncm_test/configs/c.1/t6a_ncm.test0")" = '../../functions/t6a_ncm.test0' ] || fail 'wrong function link'

mkdir "$gadget/t6a_ncm_test/configs/c.1/unknown-object"
if SBAIR_USB_NIC_PROFILE="$tmp/profile-dir/profile" run_helper "$helper" disable >/dev/null 2>&1; then
	fail 'disable removed an unknown ConfigFS object'
fi
[ -d "$gadget/t6a_ncm_test/configs/c.1/unknown-object" ] || fail 'unknown ConfigFS object was removed'
rmdir "$gadget/t6a_ncm_test/configs/c.1/unknown-object"

out=$(SBAIR_USB_NIC_PROFILE="$tmp/profile-dir/profile" run_helper "$helper" disable)
echo "$out" | grep -q '^runtime=disabled$' || fail 'disable runtime state'
[ ! -e "$gadget/t6a_ncm_test" ] || fail 'custom gadget was not removed'
[ ! -e "$net/usb0/address" ] || fail 'app-owned usb0 address was not removed'

! grep -q 'rmmod[[:space:]]\+-f' "$helper" || fail 'force rmmod path exists'
! grep -Eq '(^|[[:space:]])uci([[:space:]]|$)|network\.lan|br-lan.*=' "$helper" || fail 'helper mutates network configuration'
! grep -q 'insmod' "$repo/extras/usb-nic/target.sh" || fail 'bundle installer loads module'
! grep -Eq '(^|[[:space:];])(/etc/init\.d|insmod|rmmod)([[:space:];]|$)' "$repo/extras/usb-nic/target.sh" "$repo/extras/usb-nic/install.sh" || fail 'Issue #2 introduced boot/service action'
grep -q '"usb_nic_status"' "$repo/root/usr/share/rpcd/acl.d/luci-app-sbair-modem.json" || fail 'status ACL missing'
grep -q '"usb_nic_enable"' "$repo/root/usr/share/rpcd/acl.d/luci-app-sbair-modem.json" || fail 'enable ACL missing'
grep -q '"usb_nic_disable"' "$repo/root/usr/share/rpcd/acl.d/luci-app-sbair-modem.json" || fail 'disable ACL missing'

echo usb-nic-fixture-ok
