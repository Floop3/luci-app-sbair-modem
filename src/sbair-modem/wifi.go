// SPDX-License-Identifier: MIT
// Copyright (c) 2026 syado

package main

import (
	"encoding/json"
	"fmt"
	"os/exec"
	"regexp"
	"strconv"
	"strings"
	"syscall"
)

// Wi-Fi の現状表示と既存の編集経路。ドリフト監視は wifi_drift.go に分離し、
// 通常のmonitor daemonからは書き込みを行わない。
//
// mt_wifi は netifd の無線ドライバスクリプトに対応が無く、LuCI標準の
// Network → Wireless では触れない。設定を書き換えた
// あとの反映経路(wifi reload が効くか、hostapd を個別に叩き直す必要が
// あるか)が実機未検証のため、まずは uci の wireless 設定をそのまま
// 読んで一覧表示するところまでに留める。
//
// key / wpa_psk / passphrase / wps_pin の類は一切読み出さない。
type wifiIface struct {
	Iface      string `json:"iface"`
	Device     string `json:"device"`
	Band       string `json:"band,omitempty"`
	SSID       string `json:"ssid,omitempty"`
	Mode       string `json:"mode"`
	Disabled   bool   `json:"disabled"`
	Hidden     bool   `json:"hidden"`
	Encryption string `json:"encryption,omitempty"`
}

// parseWireless は "wireless.ra0.ssid='xxx'" 形式を { セクション: { フィールド: 値 } }
// に集める。wifiStatus と wifiAPBands(clients.go)の両方から使う共通部分。
func parseWireless() (map[string]map[string]string, []string, error) {
	raw, err := uci("show", "wireless")
	if err != nil {
		return nil, nil, err
	}

	sections := map[string]map[string]string{}
	var order []string
	for _, line := range strings.Split(raw, "\n") {
		line = strings.TrimSpace(line)
		eq := strings.IndexByte(line, '=')
		if eq < 0 {
			continue
		}
		key, val := line[:eq], strings.Trim(line[eq+1:], "'")
		dot := strings.IndexByte(key, '.')
		if dot < 0 {
			continue
		}
		rest := key[dot+1:]
		sub := strings.IndexByte(rest, '.')
		if sub < 0 {
			// "wireless.ra0=wifi-iface" のようなセクション宣言行。中身は
			// このあとの行で個別に来るので、ここでは何もしない。
			continue
		}
		section, field := rest[:sub], rest[sub+1:]
		switch strings.ToLower(field) {
		case "key", "password", "passphrase", "psk", "wpa_psk", "wps_pin", "sae_password":
			continue
		}
		if sections[section] == nil {
			sections[section] = map[string]string{}
			order = append(order, section)
		}
		sections[section][field] = val
	}
	return sections, order, nil
}

func wifiStatus() map[string]any {
	sections, order, err := parseWireless()
	if err != nil {
		return map[string]any{"error": fmt.Sprintf("uci show wireless: %v", err)}
	}

	// wifi-device セクションの band を、それを参照する wifi-iface へ引く。
	band := map[string]string{}
	for _, name := range order {
		if b, ok := sections[name]["band"]; ok {
			band[name] = b
		}
	}

	var list []wifiIface
	for _, name := range order {
		f := sections[name]
		mode := f["mode"]
		if mode != "ap" {
			// apcli (sta, 親APへの無線アップリンク) は今回の表示対象外。
			continue
		}
		// EasyMesh(マルチAP)のバックホール専用SSID(ssidがmulti_ap_backhaul_ssidと
		// 同じ値になっている隠しAP)と、Wi-Fi7 MLD(Multi-Link Device)用の予備インターフェース
		// (セクション名が"apmld"始まり)は、単独運用では実質使い道が無いシステム用の
		// ものなので一覧から除外する。ユーザーが編集可能なSSIDだけを見せる。
		if strings.HasPrefix(name, "apmld") {
			continue
		}
		if ssid := f["ssid"]; ssid != "" && ssid == f["multi_ap_backhaul_ssid"] {
			continue
		}
		list = append(list, wifiIface{
			Iface:      name,
			Device:     f["device"],
			Band:       band[f["device"]],
			SSID:       f["ssid"],
			Mode:       mode,
			Disabled:   f["disabled"] == "1",
			Hidden:     f["hidden"] == "1",
			Encryption: f["encryption"],
		})
	}

	// チャンネルはインターフェースではなく無線デバイス(radio)単位の値。
	// 編集画面がband別に1つずつ出せるよう、別枠で返す。
	type radioInfo struct {
		Device            string `json:"device"`
		Band              string `json:"band"`
		Channel           string `json:"channel"`   // UCI configured value (legacy field)
		Bandwidth         string `json:"bandwidth"` // UCI htmode width (legacy field)
		Protocol          string `json:"protocol"`  // UCI configured profile
		Source            string `json:"source"`
		ChannelPolicy     string `json:"channel_policy"`
		ConfiguredChannel string `json:"configured_channel"`
		BandwidthPolicy   string `json:"bandwidth_policy"`
		ConfiguredWidth   string `json:"configured_bandwidth"`
	}
	var radios []radioInfo
	for _, name := range order {
		f := sections[name]
		if b, ok := f["band"]; ok {
			radios = append(radios, radioInfo{
				Device: name, Band: b, Channel: f["channel"],
				Bandwidth:     htmodeWidth(f["htmode"]),
				Protocol:      protocolValueFromHtmode(b, f["htmode"], f["pure_11b"]),
				Source:        "uci",
				ChannelPolicy: driftPolicy(f["channel"]), ConfiguredChannel: driftChannel(f["channel"]),
				BandwidthPolicy: driftPolicy(f["htmode"]), ConfiguredWidth: driftWidth(f["htmode"]),
			})
		}
	}

	return map[string]any{"ifaces": list, "radios": radios}
}

// wifiAPBands は現在AP(親機)として動いている無線インターフェース名から
// 帯域("2.4G"/"5G"/"6G")への対応表を返す。clients.go の assoclist 突き合わせ用。
// disabled のインターフェースも一応含める(iwinfoが失敗するだけで実害は無い)。
func wifiAPBands() map[string]string {
	sections, order, err := parseWireless()
	if err != nil {
		return nil
	}
	band := map[string]string{}
	for _, name := range order {
		if b, ok := sections[name]["band"]; ok {
			band[name] = b
		}
	}
	out := map[string]string{}
	for _, name := range order {
		f := sections[name]
		if f["mode"] == "ap" {
			out[name] = band[f["device"]]
		}
	}
	return out
}

// wifiAPSSIDs は現在AP(親機)として動いている無線インターフェース名からSSID名への
// 対応表を返す。clients.go で接続機器がどのSSIDに繋がっているか表示するのに使う。
func wifiAPSSIDs() map[string]string {
	sections, order, err := parseWireless()
	if err != nil {
		return nil
	}
	out := map[string]string{}
	for _, name := range order {
		f := sections[name]
		if f["mode"] == "ap" {
			out[name] = f["ssid"]
		}
	}
	return out
}

// applyWifiRestart は Wi-Fi 設定変更のたびに呼ぶ。`knsh save`(UCIの内容を
// ドライバが読む.dat形式へ書き出すだけで、それ自体は何も反映しない)の後に
// `knsh wlan restart` を呼ぶことで、**本体を再起動せずにWi-Fiドライバだけを
// 再読み込みして設定を反映する**(2026-08-10、`/lib/wifi/mtwifi.lua`を読んで
// 発見。実機でSSID名の変更を往復とも無停止で確認済み)。
//
// `/sbin/wifi restart` → `mtwifi_restart()` の実体は、Wi-Fiドライバがモジュール
// としてロードされている場合(`/sys/module/mt_wifi`が存在する。この機体では
// 実機で確認済み)は `rmmod mt_wifi` → `modprobe mt_wifi` でドライバを
// 再読み込みするだけ。**この間、全帯域のWi-Fiが数秒切断される**(有線/SSHには影響しない)。
//
// 🔴 未検証の例外: `mtwifi_restart()`には「SSID数(BSS数)を変える場合、
// mt7915だと再起動必須」という分岐があり、その場合は何もせず
// `/tmp/mtk/wifi/reboot_required`を書くだけで終わる。このアプリは既存の
// SSIDの値を変更するだけで追加/削除は行わないため通常は該当しないはずだが、
// 万一この分岐に当たった場合はここでの再読み込みは効かず、引き続き手動での
// 本体再起動が必要になる(呼び出し元では判別できない)。
//
// 🔴 副作用: `knsh wlan restart`はファイアウォールの全体リロードも連動して
// 走らせ、`/usr/share/knos/isolate.include`が再実行される。apモード運用中は
// これでSSID2(`ra1`/`rai1`/`rax1`)の有線LANへのDROPルール(§6-9)が復活するため、
// ここで毎回reconcileし直す。
//
// 🔴 **実機で踏んだ罠: ここで1回だけ片付けても、少し遅れて復活することがある。**
// `knsh wlan restart`はWi-Fiインターフェースを一度down/upさせるため、
// `/etc/hotplug.d/iface/20-firewall`が非同期に発火してもう一度ファイアウォールを
// リロードし、`isolate.include`がDROPルールを再度足してしまうタイミング競合が
// あるとみられる(2026-08-10、実機でSSID2が再び繋がらなくなる形で発覚。
// 直後+数秒おきの複数回リトライでも間に合わないケースがあった)。
//
// **タイミングの予測を諦め、`recovery/files/etc/init.d/sbair-netfix`を
// 15秒おきに常時ループするprocd常駐サービスに変更して対処した。** そのため
// ここでの呼び出しは「常駐サービスの次の周期を待たずに素早く片付ける」ための
// 即時1回だけでよい。
func reconcileSSID2LanBlock() {
	if ignore, _ := uci("get", "dhcp.lan.ignore"); ignore == "1" {
		for _, mark := range []string{"0x102", "0x202", "0x302"} {
			_ = exec.Command("ebtables", "-t", "nat", "-D", "postrouting_wlan2lan",
				"--mark", mark, "-j", "DROP").Run()
		}
	}
}

// applyWifiRestart は `knsh wlan restart` をバックグラウンドで起動して即座に
// 戻る(2026-08-10、実機で発見: ここを同期実行していると、LuCI画面自体が
// Wi-Fi経由で開かれている場合、`knsh wlan restart`が全帯域を数秒切断する
// せいでrpcd呼び出しのHTTP応答そのものが届かなくなり、ブラウザ側で
// "XHR request timed out" になる)。
//
// `uci set`/`uci commit`/`knsh save`(設定の保存)はすでに同期的に完了済みの
// 状態でこれが呼ばれるため、応答を待たずに画面を再読み込みしても
// `wifiStatus()`はUCIから読むので新しい値がすぐ見える。実際のWi-Fi瞬断
// (ドライバ再読み込み)は数秒遅れてバックグラウンドで起きる。
//
// 呼び出し元プロセス(rpcdが呼ぶ`sbair-modem`はリクエスト毎に1回起動して
// 終了する使い捨てプロセス)がHTTP応答を返した直後に終了しても子プロセスが
// 道連れにならないよう、`Setsid: true`でセッションを分離する。
func applyWifiRestart() error {
	cmd := exec.Command("sh", "-c", "/usr/bin/sbair-modem wifi-drift snapshot wlan_restart_before >/dev/null 2>&1; "+
		"knsh wlan restart; "+
		"mode=\"$(uci -q get dhcp.lan.ignore)\"; "+
		"if [ \"$mode\" = \"1\" ]; then "+
		"ebtables -t nat -D postrouting_wlan2lan --mark 0x102 -j DROP 2>/dev/null; "+
		"ebtables -t nat -D postrouting_wlan2lan --mark 0x202 -j DROP 2>/dev/null; "+
		"ebtables -t nat -D postrouting_wlan2lan --mark 0x302 -j DROP 2>/dev/null; "+
		"fi; /usr/bin/sbair-modem wifi-drift snapshot wlan_restart_after >/dev/null 2>&1")
	cmd.SysProcAttr = &syscall.SysProcAttr{Setsid: true}
	if err := cmd.Start(); err != nil {
		return fmt.Errorf("Wi-Fi再起動の開始に失敗しました: %v", err)
	}
	return nil
}

func runKnshSave() error {
	if err := exec.Command("knsh", "save").Run(); err != nil {
		// Do not include command output here: future vendor versions might echo
		// wireless credentials while reporting an error.
		return fmt.Errorf("knsh saveに失敗しました: %v", err)
	}
	return nil
}

func finishWifiApply() map[string]any {
	wifiDriftRecord("wifi_apply_before_save")
	if err := runKnshSave(); err != nil {
		return map[string]any{"error": err.Error()}
	}
	wifiDriftRecord("wifi_apply_after_save")
	if err := applyWifiRestart(); err != nil {
		return map[string]any{"error": err.Error(), "saved": true}
	}
	return map[string]any{
		"result":          "started",
		"saved":           true,
		"wifi_restarting": true,
		"restart_async":   true,
	}
}

// wifiSet はSSID・ステルス・有効/無効・パスワードを変更する(Phase 2)。
//
// パスワードは純正UIが使う`knsh wlan encryption wpapskkey <1|2> <pwd>`
// (SSIDグループ単位、band跨ぎ)ではなく、**素の`uci set .key`をインターフェース単位**で
// 使う。どうせ再起動しないと反映されないなら、band別に個別編集できる
// このほうが単純で一貫性がある。
// validEncryption はLuCI側で提示する選択肢のみ許可する(hostapd/uciの生文字列)。
var validEncryption = map[string]bool{
	"none": true, "owe": true,
	"psk2+ccmp": true, "psk-mixed+ccmp": true,
	"sae": true, "sae-mixed": true,
}

// 純正UIの実際のテンプレート(angouka.phtml)には2.4GHz/5GHzに「WPA3単体」「OWE」の
// 選択肢が無いが、実機で試したところ普通に動作することを確認した(2026-08-09)。
// ハードウェア制約ではなく製品判断(互換性重視)と判断し、このアプリでは解禁する。
// WEP・WPA(TKIP)単体は脆弱なため除外のまま。
var validEncryption2G5G = map[string]bool{
	"none": true, "owe": true, "sae": true,
	"psk-mixed+ccmp": true, "sae-mixed": true,
}
var validEncryption6G = map[string]bool{"owe": true, "sae": true}

// wifiApply は互換用の保留変更反映。新しい画面は検証から再起動までを
// wifiApplyBatchで一括して行う。
func wifiApply() map[string]any {
	return finishWifiApply()
}

type wifiBatchRequest struct {
	Interfaces []wifiBatchInterface `json:"interfaces"`
	Bands      []wifiBatchBand      `json:"bands"`
}

type wifiBatchInterface struct {
	Iface      string `json:"iface"`
	SSID       string `json:"ssid"`
	Hidden     string `json:"hidden"`
	Disabled   string `json:"disabled"`
	Password   string `json:"password"`
	Encryption string `json:"encryption"`
}

type wifiBatchBand struct {
	Band     string `json:"band"`
	Channel  string `json:"channel"`
	Width    string `json:"bandwidth"`
	Protocol string `json:"protocol"`
}

// SBA6D's MT7990 vendor configuration uses txpower=100 as its maximum
// firmware power scale. It is a vendor value, not a dBm value. Keep the
// regulatory country/region untouched: this action only asks the existing
// firmware profile for its maximum and never bypasses its regulatory table.
const maxFirmwareTxPower = "100"

func wifiTxPowerMax() map[string]any {
	sections, order, err := parseWireless()
	if err != nil {
		return map[string]any{"error": fmt.Sprintf("uci show wireless: %v", err)}
	}
	if pending, pendingErr := uci("changes", "wireless"); pendingErr == nil && strings.TrimSpace(pending) != "" {
		return map[string]any{"error": "wirelessに未コミットの別変更があります。先に保存または破棄してください"}
	}

	var radios []string
	changed := false
	for _, name := range order {
		if sections[name]["band"] == "" {
			continue
		}
		radios = append(radios, name)
		if sections[name]["txpower"] == maxFirmwareTxPower {
			continue
		}
		if _, err := uci("set", "wireless."+name+".txpower="+maxFirmwareTxPower); err != nil {
			_, _ = uci("revert", "wireless")
			return map[string]any{"error": "無線出力設定の書き込みに失敗しました"}
		}
		changed = true
	}
	if len(radios) == 0 {
		return map[string]any{"error": "無線デバイスが見つかりません"}
	}
	if !changed {
		return map[string]any{
			"result":                   "already_max",
			"txpower":                  maxFirmwareTxPower,
			"radios":                   radios,
			"regulatory_settings_kept": true,
		}
	}
	if _, err := uci("commit", "wireless"); err != nil {
		_, _ = uci("revert", "wireless")
		return map[string]any{"error": fmt.Sprintf("uci commit wireless: %v", err)}
	}
	result := finishWifiApply()
	result["txpower"] = maxFirmwareTxPower
	result["radios"] = radios
	result["regulatory_settings_kept"] = true
	return result
}

// Delete the explicit vendor scale so mt_wifi/firmware can use its normal
// default. This is intentionally different from setting an arbitrary numeric
// value: txpower=100 is a firmware scale, not a dBm value, and the default is
// owned by the existing device profile.
func wifiTxPowerDefault() map[string]any {
	sections, order, err := parseWireless()
	if err != nil {
		return map[string]any{"error": fmt.Sprintf("uci show wireless: %v", err)}
	}
	if pending, pendingErr := uci("changes", "wireless"); pendingErr == nil && strings.TrimSpace(pending) != "" {
		return map[string]any{"error": "wirelessに未コミットの別変更があります。先に保存または破棄してください"}
	}

	var radios []string
	changed := false
	for _, name := range order {
		if sections[name]["band"] == "" {
			continue
		}
		radios = append(radios, name)
		if sections[name]["txpower"] == "" {
			continue
		}
		if _, err := uci("delete", "wireless."+name+".txpower"); err != nil {
			_, _ = uci("revert", "wireless")
			return map[string]any{"error": "無線出力設定の削除に失敗しました"}
		}
		changed = true
	}
	if len(radios) == 0 {
		return map[string]any{"error": "無線デバイスが見つかりません"}
	}
	if !changed {
		return map[string]any{
			"result":                   "already_default",
			"txpower":                  "default",
			"radios":                   radios,
			"regulatory_settings_kept": true,
		}
	}
	if _, err := uci("commit", "wireless"); err != nil {
		_, _ = uci("revert", "wireless")
		return map[string]any{"error": fmt.Sprintf("uci commit wireless: %v", err)}
	}
	result := finishWifiApply()
	result["txpower"] = "default"
	result["radios"] = radios
	result["regulatory_settings_kept"] = true
	return result
}

func wifiRadioForBand(sections map[string]map[string]string, order []string, band string) (string, map[string]string) {
	for _, name := range order {
		if sections[name]["band"] == band {
			return name, sections[name]
		}
	}
	return "", nil
}

func validWiFiChannel(value string) bool {
	n, err := strconv.Atoi(value)
	return err == nil && n >= 0 && n <= 233
}

func validBinaryOption(value string) bool {
	return value == "" || value == "0" || value == "1"
}

func protocolOption(band, value string) (*protocolOpt, bool) {
	for i := range protocolChoices[band] {
		if protocolChoices[band][i].Value == value {
			return &protocolChoices[band][i], true
		}
	}
	return nil, false
}

// wifiApplyBatch validates every requested mutation before touching UCI. The
// vendor channel command is inherently runtime-immediate, so it is performed
// only after UCI validation/commit and is reported as a non-atomic operation.
func wifiApplyBatch(changes string) map[string]any {
	if strings.TrimSpace(changes) == "" || len(changes) > 64*1024 {
		return map[string]any{"error": "Wi-Fi一括変更のデータが不正です"}
	}
	var request wifiBatchRequest
	if err := json.Unmarshal([]byte(changes), &request); err != nil {
		return map[string]any{"error": "Wi-Fi一括変更のデータを読み取れません"}
	}
	if len(request.Interfaces) == 0 && len(request.Bands) == 0 {
		return map[string]any{"result": "noop"}
	}
	sections, order, err := parseWireless()
	if err != nil {
		return map[string]any{"error": fmt.Sprintf("uci show wireless: %v", err)}
	}
	// Do not discard another writer's staged UCI edits when an operation fails.
	if pending, pendingErr := uci("changes", "wireless"); pendingErr == nil && strings.TrimSpace(pending) != "" {
		return map[string]any{"error": "wirelessに未コミットの別変更があります。先に保存または破棄してください"}
	}

	operations := make([][2]string, 0)
	seenIfaces := map[string]bool{}
	seenBands := map[string]bool{}
	channels := make([]wifiBatchBand, 0, len(request.Bands))
	changed := false
	for _, change := range request.Interfaces {
		if change.Iface == "" || seenIfaces[change.Iface] {
			return map[string]any{"error": "Wi-Fiインターフェース指定が重複または空です"}
		}
		seenIfaces[change.Iface] = true
		band, ok := wifiAPBandsFromSections(sections, order, change.Iface)
		if !ok {
			return map[string]any{"error": fmt.Sprintf("unknown AP interface %q", change.Iface)}
		}
		if !validBinaryOption(change.Hidden) || !validBinaryOption(change.Disabled) {
			return map[string]any{"error": "hidden/disabledは0または1です"}
		}
		if change.Encryption != "" {
			allowed := validEncryption2G5G
			if band == "6G" {
				allowed = validEncryption6G
			}
			if !validEncryption[change.Encryption] || !allowed[change.Encryption] {
				return map[string]any{"error": fmt.Sprintf("encryption %q is not supported on %s", change.Encryption, band)}
			}
		}
		for _, fieldValue := range []struct{ field, value string }{
			{"ssid", change.SSID}, {"hidden", change.Hidden}, {"disabled", change.Disabled},
			{"key", change.Password}, {"encryption", change.Encryption},
		} {
			field, value := fieldValue.field, fieldValue.value
			if value != "" {
				operations = append(operations, [2]string{change.Iface + "." + field, value})
				changed = true
			}
		}
	}

	for _, change := range request.Bands {
		if change.Band == "" || seenBands[change.Band] {
			return map[string]any{"error": "Wi-Fi帯域指定が重複または空です"}
		}
		_, supportedBand := map[string]string{"2.4G": "2.4GHz", "5G": "5GHz", "6G": "6GHz"}[change.Band]
		if !supportedBand {
			return map[string]any{"error": fmt.Sprintf("unknown band %q", change.Band)}
		}
		seenBands[change.Band] = true
		device, current := wifiRadioForBand(sections, order, change.Band)
		if device == "" {
			return map[string]any{"error": fmt.Sprintf("band %q の無線デバイスが見つかりません", change.Band)}
		}
		if change.Channel != "" && !validWiFiChannel(change.Channel) {
			return map[string]any{"error": fmt.Sprintf("band %sのchannelが不正です", change.Band)}
		}
		prefix := htmodePrefixRe.FindString(current["htmode"])
		if prefix == "" {
			prefix = "NOHT"
		}
		chosenPrefix := prefix
		pureB := current["pure_11b"]
		if change.Protocol != "" {
			chosen, ok := protocolOption(change.Band, change.Protocol)
			if !ok {
				return map[string]any{"error": fmt.Sprintf("%sでは通信規格%qは選べません", change.Band, change.Protocol)}
			}
			chosenPrefix = chosen.Prefix
			pureB = "0"
			if chosen.PureB {
				pureB = "1"
			}
		}
		width := htmodeWidth(current["htmode"])
		if change.Width != "" {
			width = change.Width
		}
		if change.Width != "" {
			if chosenPrefix == "NOHT" {
				return map[string]any{"error": "レガシー通信規格では帯域幅を変更できません"}
			}
			validWidth := false
			for _, choice := range widthChoicesForProtocol(change.Band, chosenPrefix) {
				if choice == width {
					validWidth = true
					break
				}
			}
			if !validWidth {
				return map[string]any{"error": fmt.Sprintf("%sでは帯域幅%qは選べません", change.Band, width)}
			}
		}
		if change.Protocol != "" {
			validWidth := false
			for _, choice := range widthChoicesForProtocol(change.Band, chosenPrefix) {
				if choice == width {
					validWidth = true
					break
				}
			}
			if !validWidth {
				width = "20"
			}
		}
		newHtmode := chosenPrefix
		coex := "0"
		if chosenPrefix != "NOHT" {
			newHtmode += width
			if width == "40" {
				coex = "1"
			}
		}
		if change.Protocol != "" || change.Width != "" {
			for _, kv := range [][2]string{
				{device + ".htmode", newHtmode},
				{device + ".pure_11b", pureB},
				{device + ".ht_coex", coex},
				{device + ".ht_extcha", "0"},
			} {
				operations = append(operations, kv)
			}
			changed = true
		}
		if change.Channel != "" {
			channels = append(channels, change)
			changed = true
		}
	}
	if !changed {
		return map[string]any{"result": "noop"}
	}

	for _, operation := range operations {
		if _, err := uci("set", "wireless."+operation[0]+"="+operation[1]); err != nil {
			_, _ = uci("revert", "wireless")
			return map[string]any{"error": "wireless設定の書き込みに失敗しました"}
		}
	}
	if len(operations) > 0 {
		if _, err := uci("commit", "wireless"); err != nil {
			_, _ = uci("revert", "wireless")
			return map[string]any{"error": fmt.Sprintf("uci commit wireless: %v", err)}
		}
	}
	for _, change := range channels {
		token := map[string]string{"2.4G": "2.4GHz", "5G": "5GHz", "6G": "6GHz"}[change.Band]
		wifiDriftRecord("wifi_channel_before")
		if _, err := exec.Command("knsh", "wlan", token, "channel", change.Channel).CombinedOutput(); err != nil {
			// Do not echo vendor output: it could contain unrelated credentials.
			return map[string]any{"error": fmt.Sprintf("%sのチャンネル変更に失敗しました（UCI設定は保存済み）", change.Band), "saved": len(operations) > 0}
		}
		wifiDriftRecord("wifi_channel_after")
	}
	result := finishWifiApply()
	result["changes"] = len(request.Interfaces) + len(request.Bands)
	return result
}

func wifiAPBandsFromSections(sections map[string]map[string]string, order []string, iface string) (string, bool) {
	f, ok := sections[iface]
	if !ok || f["mode"] != "ap" {
		return "", false
	}
	device := f["device"]
	for _, name := range order {
		if name == device && sections[name]["band"] != "" {
			return sections[name]["band"], true
		}
	}
	return "", false
}

// wifiSetChannel はチャンネルを変更する。
//
// 🔴 **チャンネルは`wireless.<iface>.channel`(uci)からは効かない**
// (channel / 帯域幅 / txpowerは`.dat`の持ち物で、uciからは動かせない実装)。
// 純正UIも`system("knsh wlan {2.4,5,6}GHz channel <値>")`を使っている
// (実機のPHPソースで確認済み)ので、それをそのまま踏襲する。
func wifiSetChannel(band, channel, apply string) map[string]any {
	token := map[string]string{"2.4G": "2.4GHz", "5G": "5GHz", "6G": "6GHz"}[band]
	if token == "" {
		return map[string]any{"error": fmt.Sprintf("unknown band %q", band)}
	}
	if channel == "" {
		return map[string]any{"error": "channel is required"}
	}
	if !validWiFiChannel(channel) {
		return map[string]any{"error": "channel must be a decimal value from 0 to 233"}
	}
	if apply == "0" {
		return map[string]any{"error": "channelの保留変更はwifi_apply_batchから送信してください"}
	}
	wifiDriftRecord("wifi_channel_before")
	if err := exec.Command("knsh", "wlan", token, "channel", channel).Run(); err != nil {
		return map[string]any{"error": fmt.Sprintf("knsh wlan %s channel %sに失敗しました: %v", token, channel, err)}
	}
	wifiDriftRecord("wifi_channel_after")
	return finishWifiApply()
}

var htmodePrefixRe = regexp.MustCompile(`^[A-Za-z]+`)
var htmodeWidthRe = regexp.MustCompile(`\d+$`)

// htmodeWidth はhtmode文字列("HE160"等)から帯域幅(MHz)部分を取り出す。
// NOHTのように数字が無いものは20MHz相当として扱う。
func htmodeWidth(htmode string) string {
	if w := htmodeWidthRe.FindString(htmode); w != "" {
		return w
	}
	return "20"
}

// bandwidthChoices は帯域ごとに選べる帯域幅(MHz)の全候補(UIの選択肢用)。
// 実際に有効な組み合わせは通信規格にも依存するため、書き込み時は
// widthChoicesForProtocol でさらに絞り込んで検証する。
var bandwidthChoices = map[string][]string{
	"2.4G": {"20", "40"},
	"5G":   {"20", "40", "80", "160"},
	"6G":   {"20", "40", "80", "160", "320"},
}

// widthChoicesForProtocol は帯域(band)と通信規格の接頭辞(htmodeのprefix、
// "NOHT"/"HT"/"VHT"/"HE"/"EHT")の組み合わせで実際に選べる帯域幅を返す。
// 実機のPHPソース(Wlan.class.php の get_wireless_mode / set_bandwith)の
// switch文をそのまま踏襲している。
//   - NOHT(レガシー): 常に20MHzのみ
//   - 2.4GHzはHT/HE/EHTのどれでも20/40MHzまで(80MHz以上は無い)
//   - 5GHzはHT(802.11n)のみ20/40MHz、VHT/HE/EHTは20/40/80/160MHz
//   - 6GHzはHT/VHTが存在せず、HE/EHTのみで20/40/80/160/320MHz
func widthChoicesForProtocol(band, prefix string) []string {
	if prefix == "NOHT" {
		return []string{"20"}
	}
	if band == "2.4G" {
		return []string{"20", "40"}
	}
	if band == "5G" && prefix == "HT" {
		return []string{"20", "40"}
	}
	return bandwidthChoices[band]
}

// protocolOpt は選べる通信規格1つ分。Prefixがhtmodeの接頭辞に対応する。
type protocolOpt struct {
	Value  string // LuCIからのAPI値("ax"/"be"等)
	Label  string
	Prefix string // htmodeの接頭辞
	PureB  bool   // 2.4GHzの「802.11bのみ」判定用(pure_11b)
}

// protocolChoices は帯域ごとに選べる通信規格。実機PHPソースの
// CFG_MODE_2G_*/CFG_MODE_5G_*/CFG_MODE_6G_* とそのまま対応する。
var protocolChoices = map[string][]protocolOpt{
	"2.4G": {
		{"b", "802.11b", "NOHT", true},
		{"bg", "802.11b/g", "NOHT", false},
		{"n", "802.11n/b/g", "HT", false},
		{"ax", "802.11ax/n/b/g", "HE", false},
		{"be", "802.11be(Wi-Fi 7)", "EHT", false},
	},
	"5G": {
		{"a", "802.11a", "NOHT", false},
		{"n", "802.11n/a", "HT", false},
		{"ac", "802.11ac/n/a", "VHT", false},
		{"ax", "802.11ax/ac/n/a", "HE", false},
		{"be", "802.11be(Wi-Fi 7)", "EHT", false},
	},
	"6G": {
		{"ax", "802.11ax", "HE", false},
		{"be", "802.11be(Wi-Fi 7)", "EHT", false},
	},
}

// protocolValueFromHtmode は現在のhtmode(+2.4GHzのみpure_11b)からLuCI表示用の
// 短い値("ax"/"be"等)を逆引きする。一致しなければ空文字。
func protocolValueFromHtmode(band, htmode, pureB string) string {
	prefix := htmodePrefixRe.FindString(htmode)
	for _, o := range protocolChoices[band] {
		if o.Prefix != prefix {
			continue
		}
		if prefix == "NOHT" && band == "2.4G" {
			if o.PureB != (pureB == "1") {
				continue
			}
		}
		return o.Value
	}
	return ""
}

// wifiSetBandwidth はチャンネル幅を変更する。インターフェースではなく
// 無線デバイス(radio)単位の値なので、bandで対象デバイスを引く(wifiSetChannelと同様)。
//
// 現在の通信規格(htmodeの接頭辞)は変えず、帯域幅の数字部分だけ差し替える。
// `ht_coex`は実機PHPソースの挙動に合わせ、40MHzを選んだ時だけ`1`にする
// (80/160/320では0のまま)。反映には本体の再起動が要る(他のWi-Fi設定と同様)。
func wifiSetBandwidth(band, width, apply string) map[string]any {
	sections, order, err := parseWireless()
	if err != nil {
		return map[string]any{"error": fmt.Sprintf("uci show wireless: %v", err)}
	}
	var device, curHtmode string
	for _, name := range order {
		f := sections[name]
		if f["band"] == band {
			device, curHtmode = name, f["htmode"]
			break
		}
	}
	if device == "" {
		return map[string]any{"error": fmt.Sprintf("band %q の無線デバイスが見つかりません", band)}
	}

	prefix := htmodePrefixRe.FindString(curHtmode)
	if prefix == "" {
		prefix = "NOHT"
	}
	choices := widthChoicesForProtocol(band, prefix)
	valid := false
	for _, c := range choices {
		if c == width {
			valid = true
			break
		}
	}
	if !valid {
		return map[string]any{"error": fmt.Sprintf("現在の通信規格では帯域幅 %q は選べません(選択肢: %v)", width, choices)}
	}
	if prefix == "NOHT" {
		return map[string]any{"error": "現在の通信規格(レガシー)では帯域幅を変更できません。先に通信規格を変更してください"}
	}

	newHtmode := prefix + width
	coex := "0"
	if width == "40" {
		coex = "1"
	}

	for _, kv := range [][2]string{
		{"htmode", newHtmode},
		{"ht_coex", coex},
		{"ht_extcha", "0"},
	} {
		if _, err := uci("set", "wireless."+device+"."+kv[0]+"="+kv[1]); err != nil {
			return map[string]any{"error": fmt.Sprintf("uci set %s: %v", kv[0], err)}
		}
	}
	if _, err := uci("commit", "wireless"); err != nil {
		return map[string]any{"error": fmt.Sprintf("uci commit wireless: %v", err)}
	}
	if apply == "0" {
		return map[string]any{"result": "ok", "applied": false, "htmode": newHtmode}
	}
	result := finishWifiApply()
	result["htmode"] = newHtmode
	return result
}

// wifiSetProtocol は通信規格(802.11b/g/n/ac/ax/be)を変更する。帯域幅は
// 可能な限り現在の値を維持し、新しい規格で選べない場合だけ20MHzへ落とす
// (実機PHPソースのset_mode_protocolと同じ考え方)。
func wifiSetProtocol(band, protocol, apply string) map[string]any {
	opts, ok := protocolChoices[band]
	if !ok {
		return map[string]any{"error": fmt.Sprintf("unknown band %q", band)}
	}
	var chosen *protocolOpt
	for i := range opts {
		if opts[i].Value == protocol {
			chosen = &opts[i]
			break
		}
	}
	if chosen == nil {
		return map[string]any{"error": fmt.Sprintf("%s では通信規格 %q は選べません", band, protocol)}
	}

	sections, order, err := parseWireless()
	if err != nil {
		return map[string]any{"error": fmt.Sprintf("uci show wireless: %v", err)}
	}
	var device, curHtmode string
	for _, name := range order {
		f := sections[name]
		if f["band"] == band {
			device, curHtmode = name, f["htmode"]
			break
		}
	}
	if device == "" {
		return map[string]any{"error": fmt.Sprintf("band %q の無線デバイスが見つかりません", band)}
	}

	var newHtmode, coex string
	if chosen.Prefix == "NOHT" {
		newHtmode, coex = "NOHT", "0"
	} else {
		width := htmodeWidth(curHtmode)
		valid := false
		for _, w := range widthChoicesForProtocol(band, chosen.Prefix) {
			if w == width {
				valid = true
				break
			}
		}
		if !valid {
			width = "20"
		}
		newHtmode = chosen.Prefix + width
		coex = "0"
		if width == "40" {
			coex = "1"
		}
	}
	pureB := "0"
	if chosen.PureB {
		pureB = "1"
	}

	for _, kv := range [][2]string{
		{"htmode", newHtmode},
		{"pure_11b", pureB},
		{"ht_coex", coex},
		{"ht_extcha", "0"},
	} {
		if _, err := uci("set", "wireless."+device+"."+kv[0]+"="+kv[1]); err != nil {
			return map[string]any{"error": fmt.Sprintf("uci set %s: %v", kv[0], err)}
		}
	}
	if _, err := uci("commit", "wireless"); err != nil {
		return map[string]any{"error": fmt.Sprintf("uci commit wireless: %v", err)}
	}
	if apply == "0" {
		return map[string]any{"result": "ok", "applied": false, "htmode": newHtmode}
	}
	result := finishWifiApply()
	result["htmode"] = newHtmode
	return result
}

// systemReboot は本体を再起動する。Wi-Fi設定の反映にはこれが要る
// (wifiSet参照)。呼び出し元(LuCI)は必ず確認を取ってから呼ぶこと。
func systemReboot() map[string]any {
	if err := exec.Command("reboot").Start(); err != nil {
		return map[string]any{"error": fmt.Sprintf("reboot: %v", err)}
	}
	return map[string]any{"result": "rebooting"}
}
