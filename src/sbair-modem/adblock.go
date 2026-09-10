// SPDX-License-Identifier: MIT
// Copyright (c) 2026 syado

package main

import (
	_ "embed"
	"fmt"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
)

// MACアドレス単位の広告ブロック。SSIDでは分けず、有線・無線・帯域を問わず
// 送信元MACだけで判定する(br-lanはbridge netfilterが有効なので、ブリッジを
// 流れるフレームもiptablesで拾える。§6-9のSSID2調査で確認済み)。
//
// 仕組み:
//  1. 対象MACに登録された端末のDNS(53番、TCP/UDPとも)だけをiptablesのDNATで
//     Air6自身が立てる専用dnsmasq(ポート5300、br-lanでlisten)へ強制転送する
//  2. その専用dnsmasqは Steven Black の ad-hoc list
//     (StevenBlack/hosts の data/StevenBlack/hosts)を0.0.0.0へ潰し、
//     それ以外は上流(1.1.1.1 / 8.8.8.8)へ転送する
//  3. 登録していないMACは今まで通りAtermへ素通り(何も変わらない)
//
// 登録状態は /etc/config/sbair に保存する。client_notes.go と同じセクション
// (client_note、名前は "m"+MAC)を共有し、"adblock" フィールドを追加するだけに
// している(MACごとに複数のセクションを持たせて食い違わせないため)。
//
// 🔴 **既知の制限、意図的にIPv4のみ対応(2026-08-10時点)**:
//   - **IPv6のDNSは対象外。** この機体のカーネルには`ip6table_nat`が存在せず
//     (`find /lib/modules -iname '*ip6*nat*'`で0件)、IPv6のDNAT自体が不可能。
//     `ip6t_REJECT`(フィルタで拒否してIPv4へフォールバックさせる)は可能だが、
//     「IPv6自体は止めたくない」という判断により見送った。IPv6優先で名前解決する
//     端末(既定のWindows/Android等)は、DNSがIPv6経由の間はブロックされない
//   - **DNS over HTTPS/TLS(暗号化DNS)を使う端末・ブラウザには効かない。**
//     Microsoft EdgeやChromeの「セキュリティで保護されたDNS」を明示的に有効にすると
//     443番の暗号化通信になり、53番のDNAT自体を素通りする。実機でEdgeのセキュアDNSで
//     この迂回を確認済み。対策(主要DoHサーバーのIPを443でブロックしフォールバックを
//     強制する等)は技術的に可能だが、今回は見送っている
//   - 対処するなら該当端末側でセキュアDNS/プライベートDNSを個別に無効化するのが確実

//go:embed data/adblock-domains.txt
var adblockDomainsRaw string

const (
	// 🔴 /etc/sbair はsms.db保護のため drwx------(root専用)。procd経由で起動する
	// dnsmasqは権限をnobodyへ落とすため、そこに置くと Permission denied で
	// 静かに読み込みに失敗し、全部素通りする(実機で踏んだ)。/tmp(誰でも読める)に置く。
	adblockHostsPath = "/tmp/sbair-adblock-hosts.txt"
	adblockDNSPort   = "5300"
	adblockChain     = "sbair_adblock"
)

var (
	adblockIptablesRun = func(args ...string) error { return exec.Command("iptables", args...).Run() }
	adblockDNSReadyFn  = adblockDNSReady
	adblockMACsFn      = adblockMacs
	adblockBrlanIPFn   = brlanIP
)

func adblockHostsFile() string {
	if value := os.Getenv("SBAIR_ADBLOCK_HOSTS"); value != "" {
		return value
	}
	return adblockHostsPath
}

// adblockMacs は adblock='1' が立っている mac の集合を返す。
func adblockMacs() map[string]bool {
	raw, err := uci("show", apnConfig)
	if err != nil {
		return map[string]bool{}
	}

	type entry struct {
		mac     string
		adblock bool
	}
	sections := map[string]*entry{}
	for _, line := range strings.Split(raw, "\n") {
		const prefix = apnConfig + "."
		if !strings.HasPrefix(line, prefix) {
			continue
		}
		rest := line[len(prefix):]
		dot := strings.IndexByte(rest, '.')
		if dot < 0 {
			continue
		}
		section, field := rest[:dot], rest[dot+1:]
		if !strings.HasPrefix(section, "m") {
			continue
		}
		eq := strings.IndexByte(field, '=')
		if eq < 0 {
			continue
		}
		key, val := field[:eq], strings.Trim(field[eq+1:], "'")
		if sections[section] == nil {
			sections[section] = &entry{}
		}
		switch key {
		case "mac":
			sections[section].mac = val
		case "adblock":
			sections[section].adblock = val == "1"
		}
	}

	out := map[string]bool{}
	for _, e := range sections {
		if e.mac != "" && e.adblock {
			out[e.mac] = true
		}
	}
	return out
}

// adblockList はLuCI画面用に、接続機器一覧へadblock状態を足したものを返す。
func adblockList() map[string]any {
	base := clientList()
	clients, _ := base["clients"].([]clientEntry)
	enabled := adblockMacs()
	type row struct {
		clientEntry
		Adblock bool `json:"adblock"`
	}
	rows := make([]row, 0, len(clients))
	for _, c := range clients {
		rows = append(rows, row{clientEntry: c, Adblock: enabled[c.MAC]})
	}
	return map[string]any{"clients": rows}
}

func adblockSet(mac, enabled string) map[string]any {
	mac = strings.ToLower(strings.TrimSpace(mac))
	if mac == "" {
		return map[string]any{"error": "mac is required"}
	}
	if err := ensureConfig(); err != nil {
		return map[string]any{"error": fmt.Sprintf("/etc/config/%s を作れません: %v", apnConfig, err)}
	}
	sec := apnConfig + "." + macSectionName(mac)
	if _, err := uci("get", sec); err != nil {
		// client_note がまだ無いMAC。adblock専用にセクションを新規作成する。
		if _, err := uci("set", sec+"=client_note"); err != nil {
			return map[string]any{"error": fmt.Sprintf("uci set: %v", err)}
		}
		if _, err := uci("set", sec+".mac="+mac); err != nil {
			return map[string]any{"error": fmt.Sprintf("uci set: %v", err)}
		}
	}
	val := "0"
	if enabled == "1" || enabled == "true" {
		val = "1"
	}
	if _, err := uci("set", sec+".adblock="+val); err != nil {
		return map[string]any{"error": fmt.Sprintf("uci set: %v", err)}
	}
	if _, err := uci("commit", apnConfig); err != nil {
		return map[string]any{"error": fmt.Sprintf("uci commit: %v", err)}
	}
	if err := applyAdblockRules(); err != nil {
		return map[string]any{"error": fmt.Sprintf("ルール反映に失敗: %v", err)}
	}
	return map[string]any{"result": "ok", "enabled": val == "1"}
}

// brlanIP はbr-lanの「本来の」IPv4アドレスを返す。172.16.255.254/24は出荷時からの
// 残骸で実際には使われていないため除外する(clients.goのarpSweepで確認済み)。
func brlanIP() string {
	out, err := exec.Command("ip", "-4", "-o", "addr", "show", "dev", "br-lan").Output()
	if err != nil {
		return ""
	}
	for _, line := range strings.Split(string(out), "\n") {
		f := strings.Fields(line)
		for i, tok := range f {
			if tok != "inet" || i+1 >= len(f) {
				continue
			}
			ip, _, err := net.ParseCIDR(f[i+1])
			if err != nil || ip.To4() == nil {
				continue
			}
			if !strings.HasPrefix(ip.String(), "172.16.") {
				return ip.String()
			}
		}
	}
	return ""
}

// writeAdblockHosts は埋め込んだドメインリストを hosts形式(dnsmasqのaddn-hosts用)
// で書き出す。固定revisionの生成物は現在2,804件。
func writeAdblockHosts() error {
	var b strings.Builder
	b.Grow(len(adblockDomainsRaw) + len(adblockDomainsRaw)/8)
	for _, domain := range strings.Split(strings.TrimSpace(adblockDomainsRaw), "\n") {
		domain = strings.TrimSpace(domain)
		if domain == "" {
			continue
		}
		b.WriteString("0.0.0.0 ")
		b.WriteString(domain)
		b.WriteByte('\n')
	}
	path := adblockHostsFile()
	if info, err := os.Lstat(filepath.Dir(path)); err != nil || !info.IsDir() || info.Mode()&os.ModeSymlink != 0 {
		if err != nil {
			return fmt.Errorf("hosts親ディレクトリを確認できません: %v", err)
		}
		return fmt.Errorf("hosts親ディレクトリが不正です")
	}
	tmp, err := os.CreateTemp(filepath.Dir(path), ".sbair-adblock-hosts-")
	if err != nil {
		return err
	}
	tmpName := tmp.Name()
	defer os.Remove(tmpName)
	if err := tmp.Chmod(0644); err != nil {
		_ = tmp.Close()
		return err
	}
	if _, err := tmp.WriteString(b.String()); err != nil {
		_ = tmp.Close()
		return err
	}
	if err := tmp.Sync(); err != nil {
		_ = tmp.Close()
		return err
	}
	if err := tmp.Close(); err != nil {
		return err
	}
	// Rename replaces a malicious final symlink rather than following it.
	if err := os.Rename(tmpName, path); err != nil {
		return err
	}
	info, err := os.Lstat(path)
	if err != nil {
		return err
	}
	if info.Mode()&os.ModeSymlink != 0 || !info.Mode().IsRegular() {
		return fmt.Errorf("hostsファイルが通常ファイルではありません")
	}
	if info.Mode().Perm() != 0644 {
		return fmt.Errorf("hostsファイルのmodeが0644ではありません")
	}
	return nil
}

func adblockDNSReady() bool {
	out, err := exec.Command("ss", "-lun").Output()
	if err != nil {
		return false
	}
	for _, line := range strings.Split(string(out), "\n") {
		fields := strings.Fields(line)
		if len(fields) == 0 || !strings.HasPrefix(strings.ToLower(fields[0]), "udp") {
			continue
		}
		for _, field := range fields[1:] {
			if strings.HasSuffix(field, ":"+adblockDNSPort) {
				return true
			}
		}
	}
	return false
}

func removeAdblockRules() error {
	if err := adblockIptablesRun("-t", "nat", "-L", adblockChain); err != nil {
		// No package chain means there is nothing to remove.  Other iptables
		// failures are intentionally treated the same here because stop/boot
		// must never turn normal DNS into a partial DNAT state.
		return nil
	}
	var firstErr error
	for {
		err := adblockIptablesRun("-t", "nat", "-D", "PREROUTING", "-j", adblockChain)
		if err != nil {
			break
		}
	}
	if err := adblockIptablesRun("-t", "nat", "-F", adblockChain); err != nil {
		firstErr = err
	}
	return firstErr
}

// applyAdblockRules はiptables nat の sbair_adblock チェーンを、現在登録されている
// MAC集合に合わせて作り直す(flush + 再構築なので何度呼んでも安全)。
func applyAdblockRules() error {
	macs := adblockMACsFn()
	if len(macs) == 0 {
		return removeAdblockRules()
	}
	if !adblockDNSReadyFn() {
		_ = removeAdblockRules()
		return fmt.Errorf("専用dnsmasq(%s/udp)がLISTENしていません。DNATは適用しません", adblockDNSPort)
	}
	ip := adblockBrlanIPFn()
	if ip == "" {
		return fmt.Errorf("br-lanのIPアドレスを取得できません")
	}
	dest := ip + ":" + adblockDNSPort

	created := false
	if err := adblockIptablesRun("-t", "nat", "-N", adblockChain); err == nil {
		created = true
	} else if err := adblockIptablesRun("-t", "nat", "-L", adblockChain); err != nil {
		return fmt.Errorf("iptables -N/-L %s: %v", adblockChain, err)
	}
	cleanup := func() {
		_ = adblockIptablesRun("-t", "nat", "-D", "PREROUTING", "-j", adblockChain)
		_ = adblockIptablesRun("-t", "nat", "-F", adblockChain)
		if created {
			_ = adblockIptablesRun("-t", "nat", "-X", adblockChain)
		}
	}
	if err := adblockIptablesRun("-t", "nat", "-F", adblockChain); err != nil {
		cleanup()
		return fmt.Errorf("iptables -F %s: %v", adblockChain, err)
	}
	jumpPresent := adblockIptablesRun("-t", "nat", "-C", "PREROUTING", "-j", adblockChain) == nil
	jumpAdded := false
	if !jumpPresent {
		if err := adblockIptablesRun("-t", "nat", "-I", "PREROUTING", "1", "-j", adblockChain); err != nil {
			cleanup()
			return fmt.Errorf("iptables -I PREROUTING: %v", err)
		}
		jumpAdded = true
	}

	for mac := range macs {
		for _, proto := range []string{"udp", "tcp"} {
			if err := adblockIptablesRun("-t", "nat", "-A", adblockChain,
				"-m", "mac", "--mac-source", mac,
				"-p", proto, "--dport", "53",
				"-j", "DNAT", "--to-destination", dest); err != nil {
				// Never leave a working PREROUTING jump with only half of the
				// MAC/protocol rules. An empty chain means normal DNS remains.
				if jumpAdded || created {
					cleanup()
				} else {
					_ = adblockIptablesRun("-t", "nat", "-F", adblockChain)
				}
				return fmt.Errorf("iptables -A %s (%s/%s): %v", adblockChain, mac, proto, err)
			}
		}
	}
	return nil
}

// adblockBoot は起動時(sbair-adblock init script)から呼ばれる。hostsファイルを
// 書き出し、iptablesルールを反映する。専用dnsmasqの起動はshell側(init script)が行う
// (Goプロセスを常駐させずbusyboxのプロセス監視に任せるほうが単純なため)。
func adblockBoot() map[string]any {
	if err := writeAdblockHosts(); err != nil {
		_ = removeAdblockRules()
		return map[string]any{"error": fmt.Sprintf("hosts書き出し失敗: %v", err)}
	}
	if err := applyAdblockRules(); err != nil {
		_ = removeAdblockRules()
		return map[string]any{"error": fmt.Sprintf("ルール反映失敗: %v", err)}
	}
	return map[string]any{"result": "ok", "domains": strings.Count(adblockDomainsRaw, "\n")}
}

func adblockStop() map[string]any {
	if err := removeAdblockRules(); err != nil {
		return map[string]any{"error": fmt.Sprintf("広告ブロックDNATを解除できません: %v", err)}
	}
	return map[string]any{"result": "stopped"}
}
