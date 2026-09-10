// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Floop3

package main

import (
	"fmt"
	"net"
	"os"
	"strings"
)

func bridgeInterfaceName() string {
	if value := strings.TrimSpace(os.Getenv("SBAIR_LAN_INTERFACE")); value != "" {
		return value
	}
	return "br-lan"
}

func currentBridgeIPv4() ([]*net.IPNet, []net.IP, error) {
	iface, err := net.InterfaceByName(bridgeInterfaceName())
	if err != nil {
		return nil, nil, err
	}
	addrs, err := iface.Addrs()
	if err != nil {
		return nil, nil, err
	}
	var networks []*net.IPNet
	var self []net.IP
	for _, addr := range addrs {
		ip, network, err := net.ParseCIDR(addr.String())
		if err != nil {
			continue
		}
		ip4 := ip.To4()
		if ip4 == nil {
			continue
		}
		network.IP = network.IP.To4()
		networks = append(networks, network)
		self = append(self, append(net.IP(nil), ip4...))
	}
	if len(networks) == 0 {
		return nil, nil, fmt.Errorf("%s has no IPv4 address", bridgeInterfaceName())
	}
	return networks, self, nil
}

func ipv4Uint(ip net.IP) uint32 {
	ip = ip.To4()
	return uint32(ip[0])<<24 | uint32(ip[1])<<16 | uint32(ip[2])<<8 | uint32(ip[3])
}

func networkBroadcast(network *net.IPNet) net.IP {
	base := ipv4Uint(network.IP)
	one, bits := network.Mask.Size()
	if bits != 32 {
		return nil
	}
	hostMask := uint32(0xffffffff >> uint(one))
	v := base | hostMask
	return net.IPv4(byte(v>>24), byte(v>>16), byte(v>>8), byte(v))
}

func isSpecialIPv4(ip net.IP, networks []*net.IPNet) bool {
	ip = ip.To4()
	if ip == nil || ip.IsUnspecified() || ip.IsLoopback() || ip.IsMulticast() || ip.IsLinkLocalUnicast() {
		return true
	}
	if ip.Equal(net.IPv4bcast) {
		return true
	}
	for _, network := range networks {
		if network != nil && ip.Equal(networkBroadcast(network)) {
			return true
		}
	}
	return false
}

func validateLANPeer(target string, networks []*net.IPNet, self []net.IP) (net.IP, error) {
	ip := net.ParseIP(strings.TrimSpace(target))
	ip4 := ip.To4()
	if ip4 == nil || ip.String() != ip4.String() {
		return nil, fmt.Errorf("IPv4 address is required")
	}
	if isSpecialIPv4(ip4, networks) {
		return nil, fmt.Errorf("special IPv4 address is not a LAN peer")
	}
	for _, own := range self {
		if ip4.Equal(own.To4()) {
			return nil, fmt.Errorf("router address is not a scan target")
		}
	}
	for _, network := range networks {
		if network != nil && network.Contains(ip4) {
			return ip4, nil
		}
	}
	return nil, fmt.Errorf("address is outside the current %s IPv4 network", bridgeInterfaceName())
}

func observedClientIP(ip string, clients []clientEntry) bool {
	for _, client := range clients {
		candidate := net.ParseIP(strings.TrimSpace(client.IP))
		if candidate != nil && candidate.To4() != nil && candidate.To4().String() == ip {
			return true
		}
	}
	return false
}
