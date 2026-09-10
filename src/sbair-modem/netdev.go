// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Floop3

package main

// Read-only network-device capability diagnostics. This deliberately does not
// change UCI, netifd, bridge membership, or kernel module state.

import (
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"sort"
	"strings"
)

type netdevKernelStatus struct {
	Release           string   `json:"release"`
	Architecture      string   `json:"architecture"`
	LoadedModules     []string `json:"loaded_modules"`
	ModulesPath       string   `json:"modules_path"`
	ModulesDirPresent bool     `json:"modules_dir_present"`
	ModulesDepPresent bool     `json:"modules_dep_present"`
}

type netdevBridgeStatus struct {
	Name    string   `json:"name"`
	Members []string `json:"members"`
}

type netdevUSBController struct {
	Name     string `json:"name"`
	Driver   string `json:"driver"`
	BusSpeed string `json:"bus_speed"`
}

type netdevUSBDevice struct {
	Name             string                    `json:"name"`
	SysfsPath        string                    `json:"sysfs_path"`
	Parent           string                    `json:"parent"`
	VIDPID           string                    `json:"vid_pid"`
	Manufacturer     string                    `json:"manufacturer"`
	Product          string                    `json:"product"`
	BusSpeed         string                    `json:"bus_speed"`
	BCDUSB           string                    `json:"bcd_usb"`
	DeviceClass      string                    `json:"device_class"`
	Kind             string                    `json:"kind"`
	Driver           string                    `json:"driver"`
	NetworkCandidate bool                      `json:"network_candidate"`
	Interfaces       []netdevUSBInterface      `json:"interfaces"`
	DriverManagement netdevUSBDriverManagement `json:"driver_management"`
}

type netdevUSBInterface struct {
	Name         string   `json:"name"`
	Class        string   `json:"class"`
	Subclass     string   `json:"subclass"`
	Protocol     string   `json:"protocol"`
	Modalias     string   `json:"modalias"`
	Driver       string   `json:"driver"`
	Netdevs      []string `json:"netdevs"`
	BlockDevices []string `json:"block_devices"`
}

type netdevUSBDriverManagement struct {
	DeviceClassAllowed bool   `json:"device_class_allowed"`
	Provenance         string `json:"provenance"`
	ExpectedDriver     string `json:"expected_driver"`
	BundleAvailable    bool   `json:"bundle_available"`
	InstallAvailable   bool   `json:"install_available"`
	RemoveAvailable    bool   `json:"remove_available"`
	Reason             string `json:"reason"`
}

type netdevDeviceStatus struct {
	Name         string `json:"name"`
	OperState    string `json:"operstate"`
	Carrier      string `json:"carrier"`
	MAC          string `json:"mac"`
	MTU          string `json:"mtu"`
	Master       string `json:"master"`
	BridgeMember bool   `json:"bridge_member"`
	LinkSpeed    string `json:"link_speed"`
	Duplex       string `json:"duplex"`
	Driver       string `json:"driver"`
	KernelDriver string `json:"kernel_driver"`
	BusType      string `json:"bus_type"`
	USBDevice    bool   `json:"usb_device"`
	USBVIDPID    string `json:"usb_vid_pid"`
	USBBusSpeed  string `json:"usb_bus_speed"`
	Role         string `json:"role"`
}

func netdevPathEnv(name, fallback string) string {
	if value := strings.TrimSpace(os.Getenv(name)); value != "" {
		return value
	}
	return fallback
}

func netdevSysClassNet() string {
	return netdevPathEnv("SBAIR_NETDEV_SYS_CLASS_NET", "/sys/class/net")
}

func netdevUSBRoot() string {
	return netdevPathEnv("SBAIR_NETDEV_SYS_USB_DEVICES", "/sys/bus/usb/devices")
}

func netdevModuleRoot() string {
	return netdevPathEnv("SBAIR_NETDEV_SYS_MODULE", "/sys/module")
}

func netdevRead(path string) string {
	b, err := os.ReadFile(path)
	if err != nil {
		return ""
	}
	return strings.TrimSpace(string(b))
}

func netdevValue(path string) string {
	if value := netdevRead(path); value != "" {
		return value
	}
	return "unknown"
}

func netdevLinkBase(path string) string {
	resolved, err := filepath.EvalSymlinks(path)
	if err != nil {
		target, readErr := os.Readlink(path)
		if readErr != nil {
			return ""
		}
		if !filepath.IsAbs(target) {
			target = filepath.Join(filepath.Dir(path), target)
		}
		resolved = target
	}
	return filepath.Base(filepath.Clean(resolved))
}

func netdevResolved(path string) string {
	resolved, err := filepath.EvalSymlinks(path)
	if err != nil {
		return ""
	}
	return resolved
}

func netdevUSBIdentity(devicePath string) (string, string, bool) {
	for current := filepath.Clean(devicePath); current != "." && current != "/"; current = filepath.Dir(current) {
		vendor := strings.ToLower(netdevRead(filepath.Join(current, "idVendor")))
		product := strings.ToLower(netdevRead(filepath.Join(current, "idProduct")))
		if vendor != "" && product != "" {
			return vendor + ":" + product, netdevValue(filepath.Join(current, "speed")), true
		}
	}
	return "unknown", "unknown", false
}

func netdevPathWithin(path, parent string) bool {
	rel, err := filepath.Rel(filepath.Clean(parent), filepath.Clean(path))
	return err == nil && rel != ".." && !strings.HasPrefix(rel, ".."+string(filepath.Separator))
}

func netdevUSBHasNetdev(devicePath string) bool {
	if devicePath == "" {
		return false
	}
	if resolved := netdevResolved(devicePath); resolved != "" {
		devicePath = resolved
	}
	entries, err := os.ReadDir(netdevSysClassNet())
	if err != nil {
		return false
	}
	for _, entry := range entries {
		path := netdevResolved(filepath.Join(netdevSysClassNet(), entry.Name(), "device"))
		if netdevPathWithin(path, devicePath) {
			return true
		}
	}
	return false
}

func netdevDeviceDriver(devicePath string, usb bool) string {
	if devicePath != "" {
		if driver := netdevLinkBase(filepath.Join(devicePath, "driver")); driver != "" {
			return driver
		}
	}
	if usb {
		return "unbound"
	}
	return "unknown"
}

func netdevBusType(devicePath string, usb bool) string {
	if usb {
		return "usb"
	}
	if devicePath != "" {
		if bus := netdevLinkBase(filepath.Join(devicePath, "subsystem")); bus != "" {
			return bus
		}
	}
	return "unknown"
}

func netdevUname(flag, fallback string) string {
	if value := strings.TrimSpace(os.Getenv(flag)); value != "" {
		return value
	}
	args := []string{"-r"}
	if flag == "SBAIR_NETDEV_UNAME_MACHINE" {
		args = []string{"-m"}
	}
	if out, err := exec.Command("uname", args...).Output(); err == nil {
		if value := strings.TrimSpace(string(out)); value != "" {
			return value
		}
	}
	return fallback
}

func netdevLoadedModules() []string {
	path := netdevPathEnv("SBAIR_NETDEV_PROC_MODULES", "/proc/modules")
	seen := map[string]bool{}
	var modules []string
	if b, err := os.ReadFile(path); err == nil {
		for _, line := range strings.Split(string(b), "\n") {
			fields := strings.Fields(line)
			if len(fields) > 0 && !seen[fields[0]] {
				seen[fields[0]] = true
				modules = append(modules, fields[0])
			}
		}
	}
	if len(modules) == 0 {
		if entries, err := os.ReadDir(netdevModuleRoot()); err == nil {
			for _, entry := range entries {
				if entry.IsDir() && !seen[entry.Name()] {
					seen[entry.Name()] = true
					modules = append(modules, entry.Name())
				}
			}
		}
	}
	sort.Strings(modules)
	return modules
}

func collectNetdevKernelStatus() netdevKernelStatus {
	release := netdevUname("SBAIR_NETDEV_UNAME_RELEASE", "unknown")
	architecture := netdevUname("SBAIR_NETDEV_UNAME_MACHINE", runtime.GOARCH)
	modulesPath := os.Getenv("SBAIR_NETDEV_MODULES_DIR")
	if strings.TrimSpace(modulesPath) == "" && release != "unknown" {
		modulesPath = filepath.Join("/lib/modules", release)
	}
	return netdevKernelStatus{
		Release:           release,
		Architecture:      architecture,
		LoadedModules:     netdevLoadedModules(),
		ModulesPath:       modulesPath,
		ModulesDirPresent: modulesPath != "" && dirExists(modulesPath),
		ModulesDepPresent: modulesPath != "" && fileExists(filepath.Join(modulesPath, "modules.dep")),
	}
}

func dirExists(path string) bool {
	info, err := os.Stat(path)
	return err == nil && info.IsDir()
}

func fileExists(path string) bool {
	info, err := os.Stat(path)
	return err == nil && info.Mode().IsRegular()
}

func netdevBridgeMembers(root, bridge string) []string {
	entries, err := os.ReadDir(filepath.Join(root, bridge, "brif"))
	if err != nil {
		return []string{}
	}
	members := make([]string, 0, len(entries))
	for _, entry := range entries {
		members = append(members, entry.Name())
	}
	sort.Strings(members)
	return members
}

func netdevCellularInterfaces() (map[string]bool, bool) {
	proto, err := uci("get", "network.wan.proto")
	if err != nil || strings.TrimSpace(proto) != "ql_datacall" {
		return map[string]bool{}, false
	}
	names := map[string]bool{}
	if device, err := uci("get", "network.wan.device"); err == nil && strings.TrimSpace(device) != "" {
		names[strings.TrimSpace(device)] = true
	}
	// netifd exposes the runtime device here when network.wan.device is a
	// protocol placeholder or has not been populated yet.
	if out, err := exec.Command("ubus", "call", "network.interface.wan", "status").Output(); err == nil {
		var status struct {
			Device   string `json:"device"`
			L3Device string `json:"l3_device"`
		}
		if json.Unmarshal(out, &status) == nil {
			if strings.TrimSpace(status.Device) != "" {
				names[strings.TrimSpace(status.Device)] = true
			}
			if strings.TrimSpace(status.L3Device) != "" {
				names[strings.TrimSpace(status.L3Device)] = true
			}
		}
	}
	return names, true
}

func netdevCellularName(name string, names map[string]bool, qlDataCall bool) bool {
	if names[name] {
		return true
	}
	if !qlDataCall {
		return false
	}
	// These are the known ql_datacall runtime families. USB Ethernet names are
	// intentionally absent; the protocol gate is required before this fallback.
	for _, prefix := range []string{"ccmni", "rmnet", "wwan", "ppp"} {
		if strings.HasPrefix(name, prefix) {
			return true
		}
	}
	return false
}

func netdevRole(name, master, bridge string, cellularNames map[string]bool, qlDataCall bool) string {
	if master == bridge {
		return "LAN bridge member"
	}
	if netdevCellularName(name, cellularNames, qlDataCall) {
		return "cellular"
	}
	if master != "" && master != "none" {
		return "unknown"
	}
	if name == bridge {
		return "unknown"
	}
	return "standalone"
}

func netdevNetworkDevices(root, bridge string) []netdevDeviceStatus {
	entries, err := os.ReadDir(root)
	if err != nil {
		return []netdevDeviceStatus{}
	}
	cellularNames, qlDataCall := netdevCellularInterfaces()
	devices := make([]netdevDeviceStatus, 0, len(entries))
	for _, entry := range entries {
		name := entry.Name()
		classPath := filepath.Join(root, name)
		devicePath := netdevResolved(filepath.Join(classPath, "device"))
		vidpid, usbSpeed, usb := netdevUSBIdentity(devicePath)
		driver := netdevDeviceDriver(devicePath, usb)
		master := netdevLinkBase(filepath.Join(classPath, "master"))
		if master == "" {
			master = "none"
		}
		bus := netdevBusType(devicePath, usb)
		devices = append(devices, netdevDeviceStatus{
			Name:         name,
			OperState:    netdevValue(filepath.Join(classPath, "operstate")),
			Carrier:      netdevValue(filepath.Join(classPath, "carrier")),
			MAC:          netdevValue(filepath.Join(classPath, "address")),
			MTU:          netdevValue(filepath.Join(classPath, "mtu")),
			Master:       master,
			BridgeMember: master == bridge,
			LinkSpeed:    netdevValue(filepath.Join(classPath, "speed")),
			Duplex:       netdevValue(filepath.Join(classPath, "duplex")),
			Driver:       driver,
			KernelDriver: driver,
			BusType:      bus,
			USBDevice:    usb,
			USBVIDPID:    vidpid,
			USBBusSpeed:  usbSpeed,
			Role:         netdevRole(name, master, bridge, cellularNames, qlDataCall),
		})
	}
	sort.Slice(devices, func(i, j int) bool { return devices[i].Name < devices[j].Name })
	return devices
}

func usbNetworkClass(value string) bool {
	switch strings.ToLower(strings.TrimSpace(value)) {
	case "02", "0a":
		return true
	default:
		return false
	}
}

func netdevUSBInterfaceStatus(path, name string) netdevUSBInterface {
	netdevs := []string{}
	if entries, err := os.ReadDir(filepath.Join(path, "net")); err == nil {
		for _, entry := range entries {
			netdevs = append(netdevs, entry.Name())
		}
	}
	blockDevices := []string{}
	if entries, err := os.ReadDir(filepath.Join(path, "block")); err == nil {
		for _, entry := range entries {
			blockDevices = append(blockDevices, entry.Name())
		}
	}
	sort.Strings(netdevs)
	sort.Strings(blockDevices)
	driver := netdevLinkBase(filepath.Join(path, "driver"))
	if driver == "" {
		driver = "unbound"
	}
	return netdevUSBInterface{
		Name:         name,
		Class:        netdevValue(filepath.Join(path, "bInterfaceClass")),
		Subclass:     netdevValue(filepath.Join(path, "bInterfaceSubClass")),
		Protocol:     netdevValue(filepath.Join(path, "bInterfaceProtocol")),
		Modalias:     netdevValue(filepath.Join(path, "modalias")),
		Driver:       driver,
		Netdevs:      netdevs,
		BlockDevices: blockDevices,
	}
}

func netdevUSBKind(deviceClass string, networkCandidate bool, interfaces []netdevUSBInterface) string {
	if networkCandidate {
		return "USB Ethernet / network candidate"
	}
	switch strings.ToLower(strings.TrimSpace(deviceClass)) {
	case "01":
		return "audio"
	case "03":
		return "HID"
	case "08":
		return "storage"
	case "09":
		return "hub"
	case "0e":
		return "camera / video"
	case "02", "0a":
		return "serial / communications"
	case "ff":
		return "vendor-specific"
	}
	for _, iface := range interfaces {
		switch strings.ToLower(strings.TrimSpace(iface.Class)) {
		case "08":
			return "storage"
		case "03":
			return "HID"
		case "0e":
			return "camera / video"
		}
	}
	return "unknown"
}

func netdevUSBExpectedDriver(vidpid string) string {
	switch strings.ToLower(vidpid) {
	case "0bda:8152", "0bda:8153", "0bda:8156":
		return "r8152（参照）"
	default:
		return "要確認"
	}
}

func netdevUSBDriverPlan(device netdevUSBDevice) netdevUSBDriverManagement {
	knownEthernet := device.NetworkCandidate && netdevUSBExpectedDriver(device.VIDPID) != "要確認"
	provenance := "unknown"
	if device.Driver == "unbound" {
		provenance = "not-bound"
	} else if device.Driver != "" {
		// There is no app-managed module bundle in this release. A bound module
		// is therefore treated as vendor/system-owned and never removable.
		provenance = "vendor/system preinstalled"
	}
	reason := "USB driver操作は読み取り専用です"
	if device.NetworkCandidate && knownEthernet {
		reason = "Air 6向けのkernel-matched driver bundleがありません"
	} else if device.NetworkCandidate {
		reason = "USB Ethernetであることを確定できないため操作できません"
	}
	return netdevUSBDriverManagement{
		DeviceClassAllowed: knownEthernet,
		Provenance:         provenance,
		ExpectedDriver:     netdevUSBExpectedDriver(device.VIDPID),
		BundleAvailable:    false,
		InstallAvailable:   false,
		RemoveAvailable:    false,
		Reason:             reason,
	}
}

func netdevUSBDeviceStatus(root string) []netdevUSBDevice {
	entries, err := os.ReadDir(root)
	if err != nil {
		return []netdevUSBDevice{}
	}
	devices := make([]netdevUSBDevice, 0)
	for _, entry := range entries {
		path := filepath.Join(root, entry.Name())
		// /sys/bus/usb/devices entries are commonly symlinks into /sys/devices.
		if !dirExists(path) {
			continue
		}
		vendor := strings.ToLower(netdevRead(filepath.Join(path, "idVendor")))
		product := strings.ToLower(netdevRead(filepath.Join(path, "idProduct")))
		if vendor == "" || product == "" {
			continue
		}
		resolvedPath := netdevResolved(path)
		if resolvedPath == "" {
			resolvedPath = path
		}
		interfaces := make([]netdevUSBInterface, 0)
		children, _ := os.ReadDir(path)
		for _, child := range children {
			interfacePath := filepath.Join(path, child.Name())
			if !strings.Contains(child.Name(), ":") || !dirExists(interfacePath) {
				continue
			}
			interfaces = append(interfaces, netdevUSBInterfaceStatus(interfacePath, child.Name()))
		}
		sort.Slice(interfaces, func(i, j int) bool { return interfaces[i].Name < interfaces[j].Name })
		// A bound Linux netdev is stronger evidence than a USB class heuristic.
		// This covers vendor-specific USB Ethernet interfaces without treating an
		// unbound vendor-specific device as Ethernet by guesswork.
		networkCandidate := usbNetworkClass(netdevRead(filepath.Join(path, "bDeviceClass"))) || netdevUSBHasNetdev(path)
		for _, iface := range interfaces {
			if usbNetworkClass(iface.Class) {
				networkCandidate = true
			}
		}
		drivers := make([]string, 0)
		seenDrivers := map[string]bool{}
		if driver := netdevLinkBase(filepath.Join(path, "driver")); driver != "" && driver != "usb" {
			drivers = append(drivers, driver)
			seenDrivers[driver] = true
		}
		for _, iface := range interfaces {
			if iface.Driver != "" && iface.Driver != "unbound" && !seenDrivers[iface.Driver] {
				drivers = append(drivers, iface.Driver)
				seenDrivers[iface.Driver] = true
			}
		}
		sort.Strings(drivers)
		driver := "unbound"
		if len(drivers) > 0 {
			driver = strings.Join(drivers, ",")
		}
		device := netdevUSBDevice{
			Name:             entry.Name(),
			SysfsPath:        resolvedPath,
			Parent:           filepath.Base(filepath.Dir(resolvedPath)),
			VIDPID:           vendor + ":" + product,
			Manufacturer:     netdevValue(filepath.Join(path, "manufacturer")),
			Product:          netdevValue(filepath.Join(path, "product")),
			BusSpeed:         netdevValue(filepath.Join(path, "speed")),
			BCDUSB:           netdevValue(filepath.Join(path, "bcdUSB")),
			DeviceClass:      netdevValue(filepath.Join(path, "bDeviceClass")),
			Driver:           driver,
			NetworkCandidate: networkCandidate,
			Interfaces:       interfaces,
		}
		device.Kind = netdevUSBKind(device.DeviceClass, networkCandidate, interfaces)
		device.DriverManagement = netdevUSBDriverPlan(device)
		devices = append(devices, device)
	}
	sort.Slice(devices, func(i, j int) bool { return devices[i].Name < devices[j].Name })
	return devices
}

func netdevUSBControllers(root string) []netdevUSBController {
	entries, err := os.ReadDir(root)
	if err != nil {
		return []netdevUSBController{}
	}
	controllers := make([]netdevUSBController, 0)
	for _, entry := range entries {
		path := filepath.Join(root, entry.Name())
		if !strings.HasPrefix(entry.Name(), "usb") || !dirExists(path) {
			continue
		}
		controllers = append(controllers, netdevUSBController{
			Name:     entry.Name(),
			Driver:   netdevDeviceDriver(path, false),
			BusSpeed: netdevValue(filepath.Join(path, "speed")),
		})
	}
	sort.Slice(controllers, func(i, j int) bool { return controllers[i].Name < controllers[j].Name })
	return controllers
}

func netdevStatus() map[string]any {
	bridge := netdevPathEnv("SBAIR_NETDEV_BRIDGE", "br-lan")
	root := netdevSysClassNet()
	report := map[string]any{
		"result":          "ok",
		"kernel":          collectNetdevKernelStatus(),
		"bridge":          netdevBridgeStatus{Name: bridge, Members: netdevBridgeMembers(root, bridge)},
		"usb_controllers": netdevUSBControllers(netdevUSBRoot()),
		"usb_devices":     netdevUSBDeviceStatus(netdevUSBRoot()),
		"network_devices": netdevNetworkDevices(root, bridge),
	}
	return report
}

func usbStatus() map[string]any {
	report := netdevStatus()
	report["scope"] = "all-usb-devices"
	return report
}
