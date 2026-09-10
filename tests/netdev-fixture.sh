#!/bin/sh
# SPDX-License-Identifier: MIT
# Read-only sysfs fixture for wired/USB capability diagnostics.
set -eu

repo=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT INT TERM
fake="$tmp/bin"
sys="$tmp/sys"
net="$sys/class/net"
usb="$sys/bus/usb/devices"
usb_real="$sys/devices/usb"
modules="$tmp/modules/6.1.0-air"
uci_log="$tmp/uci.log"
mkdir -p "$fake" "$net" "$usb" "$usb_real" "$sys/bus/pci" "$sys/drivers/e1000" \
	"$sys/drivers/r8152" "$sys/drivers/usb" "$sys/drivers/xhci-hcd" "$sys/module" "$modules"
: > "$uci_log"
printf '%s\n' '# fake modules.dep' > "$modules/modules.dep"
printf '%s\n' 'r8152 123 0 - Live 0x0' 'xhci_hcd 456 0 - Live 0x0' > "$tmp/proc-modules"

cat > "$fake/uci" <<'EOF'
#!/bin/sh
set -eu
[ "${1:-}" = -q ] && shift
[ "${1:-}" = get ] || { printf '%s\n' "$*" >> "$UCI_LOG"; exit 1; }
case "${2:-}" in
network.wan.proto) printf '%s\n' ql_datacall;;
network.wan.device) printf '%s\n' ccmni0;;
*) exit 1;;
esac
EOF
chmod 755 "$fake/uci"

cat > "$fake/ubus" <<'EOF'
#!/bin/sh
printf '%s\n' '{"device":"ccmni0","l3_device":"ccmni0"}'
EOF
chmod 755 "$fake/ubus"

write_net() {
	name=$1
	operstate=$2
	carrier=$3
	mac=$4
	mtu=$5
	speed=$6
	duplex=$7
	mkdir -p "$net/$name"
	printf '%s\n' "$operstate" > "$net/$name/operstate"
	printf '%s\n' "$carrier" > "$net/$name/carrier"
	printf '%s\n' "$mac" > "$net/$name/address"
	printf '%s\n' "$mtu" > "$net/$name/mtu"
	printf '%s\n' "$speed" > "$net/$name/speed"
	printf '%s\n' "$duplex" > "$net/$name/duplex"
}

pci_device="$sys/devices/pci0000:00/0000:00:01.0"
mkdir -p "$pci_device"
ln -s "$sys/bus/pci" "$pci_device/subsystem"
ln -s "$sys/drivers/e1000" "$pci_device/driver"

usb_device="$usb_real/1-1"
usb_interface="$usb_device/1-1:1.0"
mkdir -p "$usb_interface"
printf '%s\n' 0bda > "$usb_device/idVendor"
printf '%s\n' 8156 > "$usb_device/idProduct"
printf '%s\n' 5000 > "$usb_device/speed"
printf '%s\n' 00 > "$usb_device/bDeviceClass"
printf '%s\n' Realtek > "$usb_device/manufacturer"
printf '%s\n' 'USB 2.5GbE' > "$usb_device/product"
printf '%s\n' 0310 > "$usb_device/bcdUSB"
printf '%s\n' 02 > "$usb_interface/bInterfaceClass"
ln -s "$sys/drivers/usb" "$usb_device/driver"
ln -s "$sys/drivers/r8152" "$usb_interface/driver"
ln -s "$usb_device" "$usb/1-1"

unbound="$usb_real/2-1"
mkdir -p "$unbound/2-1:1.0"
printf '%s\n' 0bda > "$unbound/idVendor"
printf '%s\n' 8153 > "$unbound/idProduct"
printf '%s\n' 480 > "$unbound/speed"
printf '%s\n' 00 > "$unbound/bDeviceClass"
printf '%s\n' 02 > "$unbound/2-1:1.0/bInterfaceClass"
ln -s "$sys/drivers/usb" "$unbound/driver"
ln -s "$unbound" "$usb/2-1"

vendor_bound="$usb_real/3-1"
vendor_interface="$vendor_bound/3-1:1.0"
mkdir -p "$vendor_interface/net/eth1"
printf '%s\n' abcd > "$vendor_bound/idVendor"
printf '%s\n' ef01 > "$vendor_bound/idProduct"
printf '%s\n' 5000 > "$vendor_bound/speed"
printf '%s\n' 00 > "$vendor_bound/bDeviceClass"
printf '%s\n' ff > "$vendor_interface/bInterfaceClass"
ln -s "$sys/drivers/r8152" "$vendor_interface/driver"
ln -s "$vendor_bound" "$usb/3-1"

vendor_unbound="$usb_real/4-1"
mkdir -p "$vendor_unbound/4-1:1.0"
printf '%s\n' 4321 > "$vendor_unbound/idVendor"
printf '%s\n' 8765 > "$vendor_unbound/idProduct"
printf '%s\n' 480 > "$vendor_unbound/speed"
printf '%s\n' ff > "$vendor_unbound/bDeviceClass"
printf '%s\n' ff > "$vendor_unbound/4-1:1.0/bInterfaceClass"
ln -s "$vendor_unbound" "$usb/4-1"

storage="$usb_real/5-1"
mkdir -p "$storage/5-1:1.0/block/sda"
printf '%s\n' 1d6b > "$storage/idVendor"
printf '%s\n' 0104 > "$storage/idProduct"
printf '%s\n' 480 > "$storage/speed"
printf '%s\n' 08 > "$storage/bDeviceClass"
printf '%s\n' 08 > "$storage/5-1:1.0/bInterfaceClass"
ln -s "$storage" "$usb/5-1"

hub="$usb_real/6-1"
mkdir -p "$hub"
printf '%s\n' 05e3 > "$hub/idVendor"
printf '%s\n' 0610 > "$hub/idProduct"
printf '%s\n' 480 > "$hub/speed"
printf '%s\n' 09 > "$hub/bDeviceClass"
ln -s "$hub" "$usb/6-1"

unknown="$usb_real/7-1"
mkdir -p "$unknown/7-1:1.0"
printf '%s\n' 9999 > "$unknown/idVendor"
printf '%s\n' 0001 > "$unknown/idProduct"
printf '%s\n' 12 > "$unknown/speed"
printf '%s\n' 99 > "$unknown/bDeviceClass"
printf '%s\n' 99 > "$unknown/7-1:1.0/bInterfaceClass"
ln -s "$unknown" "$usb/7-1"

for controller in usb1 usb2; do
	mkdir -p "$usb_real/$controller"
	ln -s "$sys/drivers/xhci-hcd" "$usb_real/$controller/driver"
	ln -s "$usb_real/$controller" "$usb/$controller"
done
printf '%s\n' 480 > "$usb_real/usb1/speed"
printf '%s\n' 5000 > "$usb_real/usb2/speed"

write_net br-lan up 1 02:00:00:00:00:01 1500 1000 full
write_net eth0 up 1 02:00:00:00:00:02 1500 1000 full
write_net usb0 up 1 02:00:00:00:00:03 1500 1000 full
write_net eth1 up 1 02:00:00:00:00:05 1500 1000 full
write_net ccmni0 up 1 02:00:00:00:00:04 1500 unknown unknown
ln -s "$pci_device" "$net/eth0/device"
ln -s "$usb_interface" "$net/usb0/device"
ln -s "$vendor_interface" "$net/eth1/device"
ln -s "$net/br-lan" "$net/eth0/master"
mkdir -p "$net/br-lan/brif"
ln -s "$net/eth0" "$net/br-lan/brif/eth0"

(cd "$repo/src/sbair-modem" && go build -o "$tmp/sbair-modem" .)

out=$(PATH="$fake:/usr/bin:/bin:/usr/sbin:/sbin" \
	UCI_LOG="$uci_log" \
	SBAIR_NETDEV_SYS_CLASS_NET="$net" \
	SBAIR_NETDEV_SYS_USB_DEVICES="$usb" \
	SBAIR_NETDEV_SYS_MODULE="$sys/module" \
	SBAIR_NETDEV_PROC_MODULES="$tmp/proc-modules" \
	SBAIR_NETDEV_MODULES_DIR="$modules" \
	SBAIR_NETDEV_UNAME_RELEASE=6.1.0-air \
	SBAIR_NETDEV_UNAME_MACHINE=aarch64 \
	SBAIR_NETDEV_BRIDGE=br-lan \
	"$tmp/sbair-modem" netmode netdev-status)

printf '%s\n' "$out" | grep -Fq '"release":"6.1.0-air"'
printf '%s\n' "$out" | grep -Fq '"architecture":"aarch64"'
printf '%s\n' "$out" | grep -Fq '"members":["eth0"]'
printf '%s\n' "$out" | grep -Fq '"name":"eth0"'
printf '%s\n' "$out" | grep -Fq '"role":"LAN bridge member"'
printf '%s\n' "$out" | grep -Fq '"name":"usb0"'
printf '%s\n' "$out" | grep -Fq '"role":"standalone"'
printf '%s\n' "$out" | grep -Fq '"name":"eth1"'
printf '%s\n' "$out" | grep -Fq '"vid_pid":"abcd:ef01"'
printf '%s\n' "$out" | grep -Fq '"driver":"r8152"'
printf '%s\n' "$out" | grep -Fq '"name":"ccmni0"'
printf '%s\n' "$out" | grep -Fq '"role":"cellular"'
printf '%s\n' "$out" | grep -Fq '"vid_pid":"0bda:8156"'
printf '%s\n' "$out" | grep -Fq '"vid_pid":"0bda:8153"'
printf '%s\n' "$out" | grep -Fq '"usb_bus_speed":"5000"'
printf '%s\n' "$out" | grep -Fq '"name":"2-1"'
printf '%s\n' "$out" | grep -Fq '"expected_driver":"r8152（参照）"'
printf '%s\n' "$out" | grep -Fq '"driver":"unbound"'
printf '%s\n' "$out" | grep -Fq '"bus_speed":"480"'
printf '%s\n' "$out" | grep -Fq '"name":"usb2"'
printf '%s\n' "$out" | grep -Fq '"vid_pid":"4321:8765"'
printf '%s\n' "$out" | grep -Fq '"kind":"vendor-specific"'
printf '%s\n' "$out" | grep -Fq '"kind":"storage"'
printf '%s\n' "$out" | grep -Fq '"kind":"hub"'
printf '%s\n' "$out" | grep -Fq '"kind":"unknown"'
printf '%s\n' "$out" | grep -Fq '"block_devices":["sda"]'
[ ! -s "$uci_log" ]

printf '%s\n' netdev-fixture-ok
