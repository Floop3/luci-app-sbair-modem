//go:build linux

// SPDX-License-Identifier: MIT
// Copyright (c) 2026 syado

package main

import (
	"encoding/binary"
	"fmt"
	"net"
	"syscall"
	"time"
)

const (
	etherTypeARP = 0x0806
	arpRequest   = 1
	arpReply     = 2
)

func htons(value uint16) uint16 { return value<<8 | value>>8 }

// arpProbe sends an RFC 5227-style duplicate-address probe. It returns true
// only when another host answers for target; silence is the safe-to-assign
// result, while socket/interface errors are returned to the caller.
func arpProbe(ifaceName, target string) (bool, error) {
	targetIP := net.ParseIP(target).To4()
	if targetIP == nil {
		return false, fmt.Errorf("invalid IPv4 address %q", target)
	}
	iface, err := net.InterfaceByName(ifaceName)
	if err != nil {
		return false, err
	}
	if len(iface.HardwareAddr) != 6 {
		return false, fmt.Errorf("%s has no Ethernet MAC", ifaceName)
	}

	fd, err := syscall.Socket(syscall.AF_PACKET, syscall.SOCK_RAW, int(htons(etherTypeARP)))
	if err != nil {
		return false, fmt.Errorf("raw ARP socket: %w", err)
	}
	defer syscall.Close(fd)
	timeout := syscall.NsecToTimeval((2 * time.Second).Nanoseconds())
	if err := syscall.SetsockoptTimeval(fd, syscall.SOL_SOCKET, syscall.SO_RCVTIMEO, &timeout); err != nil {
		return false, fmt.Errorf("ARP socket timeout: %w", err)
	}

	broadcast := [6]byte{0xff, 0xff, 0xff, 0xff, 0xff, 0xff}
	frame := make([]byte, 42)
	copy(frame[0:6], broadcast[:])
	copy(frame[6:12], iface.HardwareAddr)
	binary.BigEndian.PutUint16(frame[12:14], etherTypeARP)
	// Ethernet/IPv4/6-byte-MAC/4-byte-IP, request.
	binary.BigEndian.PutUint16(frame[14:16], 1)
	binary.BigEndian.PutUint16(frame[16:18], 0x0800)
	frame[18], frame[19] = 6, 4
	binary.BigEndian.PutUint16(frame[20:22], arpRequest)
	copy(frame[22:28], iface.HardwareAddr)
	// sender protocol address is 0.0.0.0 for duplicate-address detection
	copy(frame[38:42], targetIP)

	addr := &syscall.SockaddrLinklayer{
		Protocol: htons(etherTypeARP),
		Ifindex:  iface.Index,
		Halen:    6,
	}
	copy(addr.Addr[:], broadcast[:])
	if err := syscall.Sendto(fd, frame, 0, addr); err != nil {
		return false, fmt.Errorf("send ARP probe: %w", err)
	}

	buf := make([]byte, 2048)
	for {
		n, _, err := syscall.Recvfrom(fd, buf, 0)
		if err != nil {
			if err == syscall.EAGAIN || err == syscall.EWOULDBLOCK {
				return false, nil
			}
			return false, fmt.Errorf("receive ARP probe: %w", err)
		}
		if n < 42 || binary.BigEndian.Uint16(buf[12:14]) != etherTypeARP {
			continue
		}
		if binary.BigEndian.Uint16(buf[20:22]) != arpReply {
			continue
		}
		if net.IP(buf[28:32]).Equal(targetIP) {
			return true, nil
		}
	}
}
