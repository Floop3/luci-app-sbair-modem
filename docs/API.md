<!-- SPDX-License-Identifier: MIT -->
# ubus API と LuCI 画面

このリポジトリは、アプリ本体の仕様と、SoftBank Air 6向け実装の安全境界を扱う。
ATコマンドの応答、ファームウェア固有の挙動、通信事業者ごとの開通条件などは、
使用する機体・回線・ファームウェアの仕様を別途確認すること。ここに記載していない
実機依存の挙動を、本アプリのAPI契約として扱わない。

---

rpcd は exec バックエンドを**呼び出しごとに 1 プロセス起こす**。
`/usr/libexec/rpcd/sbair` は 2 行の shim で、中身は `sbair-modem rpcd`。

```
sbair list              → メソッド表を JSON で
sbair call <method>     → 引数を JSON で stdin、結果を stdout
```

守ること:

- **`list` は AT を一切叩かない。** rpcd は起動時と ACL 列挙のたびに呼ぶ。
  ここで eUICC を開くと、LuCI にログインするたびカードに論理チャネルが増える
- **メソッドは粗く。** 1 呼び出し = 1 プロセス + 1 flock + 1 AT セッション
- **引数の型は値で宣言する。** rpcd はサンプル値の blobmsg 型から型を決めるので、
  `{"mapping": 0}` が整数、`{"mapping": "int"}` は**文字列**の宣言になる
- **失敗しても終了コードは 0。** 理由は payload に入れる。rpcd は非ゼロ終了を
  「壊れたバックエンド」と見なして LuCI に何も渡さない

## メソッド

| | 引数 | |
|---|---|---|
| `overview` | — | モデム状態一式(登録 / 電波 / バンド / 温度) |
| `esim_status` | — | SIM マッピング、eUICC の可否、EID、profile 一覧 |
| `esim_list` | — | profile 一覧のみ |
| `esim_enable` | `iccid` | profile 有効化 |
| `esim_disable` | `iccid` | profile 無効化 |
| `esim_delete` | `iccid` | profile 削除(不可逆) |
| `esim_nickname` | `iccid` `nickname` | profile に名前を付ける(空で消す) |
| `simmap_get` | — | SIM マッピング |
| `simmap_set` | `mapping` | SIM マッピングの切替を**開始**する(すぐ返る) |
| `simmap_status` | — | 切替の進捗。**AT に触らない** |
| `esim_download` | `activation_code` `confirmation_code` | eSIM のインストールを**開始**する(すぐ返る) |
| `esim_download_status` | — | インストールの進捗。**AT に触らない** |
| `simlock_get` | — | SIM ロックの状態とカテゴリ別の残り試行回数 |
| `simlock_set` | `on` | ロックの切替を**開始**する(すぐ返る) |
| `simlock_status` | — | 切替の進捗。**AT に触らない** |
| `apn_status` | — | 保存済みの APN 一覧、現在の SIM、`network.wan` の値 |
| `apn_set` | `iccid` `apn` `auth` `username` `password` `iptype` `label` `unlock` `ims` | 保存 |
| `apn_delete` | `iccid` | 削除 |
| `apn_apply` | — | 今の SIM に対応するものを `network.wan` **と `/etc/config/lte`** へ流して `ifup wan` |
| `apn_probe` | — | **SIM に APN を聞く。**提案を返すだけで保存も適用もしない |
| `band_set` | `lte` `nr` | 有効バンドの変更を**開始**する(すぐ返る) |
| `band_status` | — | 変更の進捗。**AT に触らない** |
| `sms_status` | — | 件数と容量。**本文を読まない** |
| `sms_list` | — | モデムから読んで PDU を解く。保存しない |
| `sms_import` | — | `sms_list` の結果を保管庫へ |
| `sms_sims` | — | 保管庫が知っている SIM(ICCID / 電話番号 / 件数) |
| `sms_messages` | `iccid` `limit` | その SIM のメッセージ。新しい順 |
| `sms_delete` | `hash` | 1 通を保管庫とモデムの両方から削除。**取り消せない** |
| `sms_purge` | `iccid` | その SIM の全件 + モデムの保存領域を空に。**取り消せない** |
| `ims_status` | — | IMS の登録状態 |
| `ims_set` | `on` | IMS の切替 |
| `modem_reset` | — | モデムのリセットを**開始**する(すぐ返る) |
| `modem_reset_status` | — | 進捗。**AT に触らない** |
| `netmode_status` | — | 接続モード、DHCP/UDP67、Bridge、Cellular経路、Wi-Fi実状態 |
| `netmode_netdev_status` | — | ネットワーク > 診断で使う、有線 / USB Host Ethernet候補とKernel能力の読み取り専用診断。汎用USB機器一覧は返すが、専用画面では表示しない |
| `netmode_get_config` | — | `/etc/config/sbair` の接続モード設定 |
| `wifi_drift_status` | — | UCI / vendor persistent / runtimeのMonitor only状態と差分 |
| `wifi_drift_logs` | — | 直近の安全化済みイベント/相関ログ |
| `wifi_drift_set` | `enabled` | Monitor daemonのON/OFF。明示操作時のみUCIを変更 |
| `wifi_drift_mark_good` | — | 現在の安全なmetadataをKnown-goodとして保存 |
| `wifi_drift_save_test` | — | 明示確認後に`knsh save`だけ実行し前後を比較。restartしない |
| `wifi_drift_restart_test` | — | 明示確認後に`knsh wlan restart`を実行しruntimeを比較 |
| `netmode_set_config` | `proto` `ipaddr` `netmask` `gateway` `dns` `fallback_enabled` `fallback_ip` `fallback_netmask` `fallback_timeout` | 非推奨互換API。draftだけを保存し、ネットワークは変更しない |
| `netmode_apply` | `mode` (`sim` / `ap`) と管理IP/Fallback一式 | Safe Applyを開始。APの管理経路が実機側で正常と確認できれば自動確定し、確認できない場合だけ120秒以内のconfirmが必要 |
| `netmode_confirm` | — | 保留中の変更を確定 |
| `netmode_rollback` | — | 保留中の変更を旧設定へ戻す |
| `netmode_repair` | — | APモードのDHCP、IPv6配布、Cellular経路、Fallbackを補正 |
| `maintenance_status` | — | LAN DHCPサーバーとOTA/FOTAの実状態。読み取り専用 |
| `dhcp_server_set` | `enabled` (boolean) | `dhcp.lan.ignore`だけを変更し、dnsmasqだけを再起動。DHCPクライアント設定は変更しない |
| `fota_set` | `enabled` (boolean) | `fota.config.enabled` / `fota.provision.enabled` とkn_fotadの停止・自動起動だけを管理。`respawn`は変更しない |
| `usb_status` | — | Air 6 に接続された USB host device / interface の読み取り専用インベントリ。既存のドライバ操作欄は無効 |
| `usb_nic_status` | — | 任意の USB CDC-NCM gadget bundle、profile、UDC、ConfigFS、`usb0`、管理経路、preflight の構造化状態 |
| `usb_nic_enable` | `ack` (boolean) | explicit acknowledgement 後に、固定 topology の実験的 USB gadget を有効化。profile / hash / kernel / UDC 等の安全ゲートを再検証 |
| `usb_nic_disable` | — | app-owned の exact gadget topology だけを限定 cleanup。未知の ConfigFS object や vendor gadget は削除しない |

`dhcp_server_set` の `enabled` は、Air 6がLAN端末へ配るDHCPサーバーの有効化です。
Air 6自身が親ルーターから管理IPを取得するDHCPクライアント
（`network.lan.*` / `management_proto`）とは別で、LANサービス画面からは変更しません。
接続モードがmanaged AP中、またはSafe Applyがpending中の書き込みは拒否されます。

## 接続モード (AP / Bridge)

接続モードの設定は `dhcp.lan.ignore` だけでは判定せず、専用の
`/etc/config/sbair` に保持する。初回導入時は `dhcp.lan.ignore` からAPを推測せず、
明示的な適用までネットワークを変更しない。`root/usr/sbin/sbair-netmode` が、
既存の `br-lan` とWi-Fi設定を変更せずにL3/DHCPだけを管理する。

```text
config bridge 'bridge'
	option mode 'ap'
	option management_proto 'static'
	option ipaddr ''
	option netmask ''
	option gateway ''
	option dns ''
	option oem_baseline_ready '0'
	option ap_dhcp_enabled '1'
	option dhcp_server '0'
	option cellular_wan '0'
	option fallback_enabled '1'
	option fallback_ip '192.168.3.1'
	option fallback_netmask '255.255.255.0'
	option fallback_timeout '15'
```

`ap_dhcp_enabled=1` が既定値で、APの管理IP DHCPクライアントを選択できる。ただしこれは
非常に高いリスクを伴うネットワーク変更で、適用に失敗すると全てのネットワーク接続を失い、
ソフトブリックしてUART復旧が必要になるおそれがある。UARTなどの復旧手段を確保できない場合は
選択・適用しないこと。Safe Applyの自動ロールバックもあらゆる設定失敗からの復旧を保証しない。
`ap_dhcp_enabled=0` にすると安全のため固定IPだけを受け付ける。SIMモードのDHCPには影響しない。

AP / Bridgeの固定IP設定では、`ipaddr`、`netmask`、`gateway`、`dns` の空欄は削除や
`192.168.3.1`への置換を意味せず、初回の管理開始前に保存した純正の論理
`network.lan.ipaddr` / `netmask` / `gateway` / `dns` を継承する。必須の固定IPまたは
ネットマスクを純正設定からも解決できない場合は、ネットワーク変更前に拒否する。
明示指定と純正値の継承は、`netmode_get_config` の `effective.*_source` でそれぞれ
`明示指定` / `純正設定を継承` と表示する。純正ベースラインは一度だけ保存し、Safe Applyの
トランザクションスナップショットやFallback IPとは別管理する。

`netmode_get_config` は、入力値を `ipaddr` / `netmask` / `gateway` / `dns` に、保存した
純正値を `oem.*` に、解決後に適用する値を `effective.*` に返す。`fallback_ip` は
DHCPクライアントの取得失敗時だけ使う復旧用アドレスで、通常の固定IP解決には使わない。

APモードでは `dhcp.lan.ignore=1`、RA / DHCPv6 / NDP無効、Cellular WANの
自動起動停止を維持する。加えて、Air 6自身から `br-lan` へ出るIPv4 DHCP
OFFER/ACK (`UDP 67 -> 68`) をiptablesでDROPするfail-closed guardを保持する。
`netmode_status.dhcp_server.udp67_listening` はシステム全体の待受観測
（`udp67_scope=system`）であり、別interfaceのlistenerだけでAPを危険判定しない。
APの安全性は `dhcp.lan.ignore` と、`br-lan`向けのpacket guardの有効性で判定する。
DHCP clientが15秒以内に管理IPを取得できない場合だけ、ARP probe後にFallback IPを
`br-lan` へ追加する。上流DHCPが `bound` / `renew` になればFallbackは削除される。
`network.lan1` の `172.16.255.254` は変更しない。SIMモード復帰時はdnsmasqを再起動し、
UDP/67がLISTENしたことを確認する。

Wi-Fi、MLO、Band Steering、SSID、チャンネル、帯域幅はこの機能の補正対象外である。
有線 / USBの診断は `sbair-modem netmode netdev-status` または
`netmode_netdev_status` で参照できる。sysfs、`network.wan` のプロトコル / device、
必要なら `ubus network.interface.wan status` だけを根拠にし、自動でWAN/LAN、bridge、
USB Host Ethernetやkernel moduleを割り当てたり変更したりしない。USBの `bus_speed` は
実際にsysfsが報告した交渉速度であり、ポートの外観や「USB 3」と書かれた端子だけから
USB 3対応とは表示しない。`usb_controllers` は実際のhost controllerの詳細ではなく、
`/sys/bus/usb/devices/usbN` のUSB bus / root hubを表示する。USB network candidateは
descriptor classだけでなく、vendor-specific classでも実際にLinux netdevがbind済みなら
候補として扱い、未bindのvendor-specific deviceは `unbound` とも捏造しない。診断RPCの
取得失敗は診断欄だけに表示し、接続モードの表示・Safe Apply・Confirm・Rollback・Repairは
継続して利用できる。

能力表示の根拠は、公式に確認できた機体情報、kernel / sysfsの技術的観測、値を取得できない
`unknown` を混同しない。公式情報や実機で裏付けられない値は能力として断定しない。

## USB Gadget（CDC-NCM NIC）

`usb_status` が扱う「Air 6 の USB Host に接続された device」のインベントリと、
`usb_nic_*` が扱う「Air 6 自身を USB Gadget にする」機能は別系統である。
後者は `extras/usb-nic/` の任意 bundle が存在しない限り有効化できず、module の load、
ConfigFS、UDC bind、`usb0`、LAN/WAN/bridge、firewall、Wi-Fi、自動起動を通常のアプリ導入で
変更しない。Enable は backend でも acknowledgement、activation profile、固定 hash / vermagic、
platform、UDC、既存 gadget の ownership、独立した `br-lan` 管理経路を再検証する。

## `sbair-netmode` の所有権と互換性

ネットワーク変更の実体は `root/usr/sbin/sbair-netmode` に一元化し、LuCI / rpcd / Go はこの
helperへ委譲する。helperの `version` は、次の安定した機械可読マーカーを返す。

```text
implementation=luci-app-sbair-modem
schema=1
version=1
```

`sim` / `ap` は旧呼び出し元向けの互換エイリアスだが、現在の `apply` と同じ Safe Apply の
transaction pathを通り、即時のネットワーク変更を行わない。`install.sh` は既存helperを、
このマーカーまたは履歴上のアプリ所有ハッシュで判定する。未知の外部実装は上書きせず停止する。
検証済みのpre-fork recovery実装を特定できるまで、その許可リストは空のままとし、未知の実装を
自動移行しない。旧実装を明示的に認識できる場合だけ、`/root/sbair-backups/netmode-legacy/`
へ一度だけ退避してから置き換える。自動復元は行わない。

有効化の初期実装には boot-time autostart がなく、再起動後に UDC を自動取得しない。candidate v1
は upstream の live-validated binary だが、source/binary の対応は B2 provenance 扱いであり、
新規用途には非推奨である。ライセンスは本体 MIT と分離された GPL-2.0-only の第三者 module として
扱う。profile の VID/PID、MAC、USB0 address、peer address は推測・ログ出力しない。

緊急復旧は以下で行う。

```sh
sbair-modem netmode recover
# または
sbair-netmode recover
```

## Wi-Fi診断 (Monitor only)

`admin/sbair/wifi/diagnostics` は、Wi-Fiを自動修復せず、次のlayerを別々に記録する。

- UCI: `/etc/config/wireless` と `/etc/config/knos` のchecksum/mtime/size、band別設定
- Vendor persistent: `/lib/wifi/mtwifi.lua`から実在する`.dat`を検出し、内容ではなくchecksum/mtime/sizeだけを保存。既知の安全なparserが実機で確認できない限り、band別の値を解析したとは表示しない
- Vendor feature state: Wi-Fi enabled、MLO、Band Steering、Mesh
- Runtime: `iw dev`を優先し、Hostapd、beacon counter、association、iwinfoを補助として収集

PSK、password、WPS PIN、その他credentialは収集・ログ・Known-good保存の対象外である。
相関ログは部品名と件数など最小限にし、生の `logread` 行は保存しない。診断ログを表示する際も
credential / SSIDらしい行は行全体を置換する。通常ログはroot専用の`/var/run/sbair/wifi-drift/`に最大512KBのringとして保持し、Known-goodは
`/etc/sbair/wifi-drift-baseline.json`へ安全なmetadataだけを保存する。起動直後、30/60/120/300秒と
30秒周期でpollingする。AUTOのACSによるruntime channel/width変更はdriftにしない。

「安全な knsh save 差分テスト」とrestart比較は自動実行せず、LuCIの明示確認が必要である。
通常のpolling、既存Wi-Fi Applyの前後記録、MLO/Band Steeringの状態収集は、UCI書き戻し・`knsh save`・
`wlan restart`を起こさない。MLO、Band Steering、SSID、チャンネルを含むWi-Fi設定自体も変更しない。
package-ownedのnetwork/firewall reloadとWi-Fi restart境界には前後のaction markerを付け、
純正WebUIなど外部からの変更はchecksum/pollingで検知する。

## APN

UCI は**外部コマンドで触る**。libuci の Go バインディングは CGO が要り、
static バイナリという前提を壊すため。

**ICCID をキーに `/etc/config/sbair` へ保存する。** `network.wan` は 1 つしか
無いので、SIM を差し替えたり eSIM の profile を切り替えるたびに手で入れ直す
ことになる。ICCID ごとに覚えておけば、その SIM に対応するものが当たる。

```
config apn 's8981****************'
	option iccid '8981…'
	option apn   'uno.au-net.ne.jp'
	option auth  '2'
	option username '…'
	option password '…'
	option label 'au'
	option unlock '1'
	option ims    '1'
```

適用先は `network.wan`(proto `ql_datacall`)の apn / auth / username /
password / iptype。書いたあと `ifup wan`。
起動時は `/etc/init.d/sbair-apn` が `sbair-modem boot` を呼ぶ。

> ⚠ **`network.wan` だけでは足りない。** ベンダの起動処理が `/etc/config/lte`
> から流し込み直すので、`apn_apply` は両方へ書く。
> APNとデータコールの挙動は、使用する機体・回線・ファームウェアの仕様を確認すること。

> ⚠ **登録が無い SIM では `apn_apply` は `skipped` を返し、`lte.*` も触らない。**
> つまり**前の SIM の APN が `/etc/config/lte` に残る**。

> ⚠ **`uci get` の stderr を値として読まないこと。** 未設定の option に対して
> `uci: Entry not found` を標準エラーへ出すので、`CombinedOutput` で拾うと
> それが値になり、書き戻すと設定として保存されてしまう
> (実際に `network.wan.iptype='uci: Entry not found'` を作ってしまった)。

### この SIM に要るモデム側の状態も一緒に持つ

`unlock` と `ims` を APN の登録に持たせてある。**適用のたびに揃える。**

| | |
|---|---|
| `unlock` | `1` なら SIM ロックを解除しておく |
| `ims` | `1` なら IMS を有効にしておく |

> **どちらも「今そうでないときだけ」動く。** SIM ロックの解除は 40〜60 秒かかり
> 電波を落とすので、既に解除済みなら触らない。整っていれば `boot` は 0.3 秒で終わる。

> ⚠ **重い操作は起動経路だけ。** `apn_apply`(画面から)は SIM ロックが
> 掛かっていても解除せず、注意書きを返すだけにする — 画面を 1 分待たせないため。
> `sbair-modem boot`(`init.d/sbair-apn` が呼ぶ)は待つ。

### `apn_probe`

SIM は自分の APN を知っているので、読み出して欄を埋められる:

```sh
sbair-modem apn probe
→ {"suggestion":{"apn":"…","auth":"2","username":"…","password":"…","iptype":"3"}}
```

返るキーは netifd の proto が使うものと同じ対応(`apn`/`auth_type`/`user`/
`password`/`protocol` → `apn`/`auth`/`username`/`password`/`iptype`)。

> **提案するだけで保存も適用もしない。** ⚠ **返る値がその契約で正しいとは
> 限らない**(実際に繋がらない APN を返す SIM がある)。確認してから保存する。

> ⚠ **登録が無ければ WAN を触らない。** 空の APN を書き込むと、ベンダが
> SIM から APN を引く仕組みを潰しかねない。

## バンドとアンテナごとの電波品質

**読みに専用のメソッドは無い。`overview` の `band` に入る。** 1 呼び出し =
1 プロセス + 1 AT セッションなので分けない。上乗せは AT 7 本、実測 30 ms 程度。

```json
"band": {
  "serving_rat": "LTE", "serving_bands": [1],
  "carriers": [ {"role":"PCC","band":1,"earfcn":100,"pci":168} ],
  "lte_supported": [1,8,41,42], "lte_enabled": [1,41,42],
  "nr_supported":  [3,28,77,79], "nr_enabled":  [3,28,77],
  "lte_rsrp": [-86,-83], "lte_sinr": [25,26],
  "ecbdinfo": "…", "epbseh": "…", "dmfapp": "…"
}
```

`ecbdinfo` / `epbseh` / `dmfapp` は生の応答。**解釈は上の配列を使い、
生の行は突き合わせ用**に添えているだけ。

> ⚠ **`serving_bands` は空になりうる。** モデムが報告しないことがある。
> **「バンド無し」と表示しないこと。**

> ⚠ **`nr_*` の測定値は 5G に載っていないとき落とす。** モデムは全部 0 を返すが
> それは欠測。同じ理由で、**`access_tech` が NR5G でも `serving_bands` が LTE
> なのは矛盾ではない** — 5G NSA は LTE のアンカーに繋いでから NR を足す。

### 変更 (`band_set`)

引数はどちらもコンマ区切りのバンド番号(`"1,41,42"`)。

- **LTE を空にできない。** 5G は LTE のアンカーに繋いでから足す方式なので、
  空にすると 5G ごと繋がらなくなる
- 対応していないバンドは弾く

> ⚠ **適用すると数秒だけネットワークから切れる。** だから非同期。ワーカーは
> 登録を 45 秒待ち、**戻らなければ元の設定に書き戻して、戻ったことまで確かめる**。
> 巻き戻し先は `sbair.band.previous` に置く — **`/tmp` のジョブファイルは
> 再起動で消える**ので、そこには置けない。

> ⚠ **モデム側の設定は再起動をまたがない。** SIM ロックや IMS と同じ扱いで、
> **選んだ組み合わせを `sbair.band.lte` / `sbair.band.nr` に保存し、起動時に
> 入れ直す**(`ensureBands`)。**バンドは SIM ではなく機体に紐づく**ので、
> `apnApplyMode` の「APN 未登録なら skip」より前で処理する。
>
> **一度書くだけでは足りない。** モデムはアプリより遅れて初期化をやり直し、
> そこで書いた値が消える。`settleBands` が boot の最後で見張り、消されたら
> 書き直す。この間 **AT の flock を握り続ける**(1 分前後、最悪 2 分)ので、
> 起動直後に画面を開くと「モデムを使用中」が出る。
> **バンドを一度も選んでいなければ即座に戻る。**

> **管理経路はこのモデムではない。** 画面と SSH は LAN 側なので、
> バンドを外して WAN が落ちても操作は続けられる。

## SMS (受信のみ)

### 削除

**保管庫だけ消しても意味が無い。** モデムには残るので次の取り込みで戻ってくる。

モデム側は `AT+CMGD` で消すが、**索引は保存しない** — 消す直前に読み直し、
**生の PDU が一致したものだけ**を消す。

`deleted` テーブルに hash を残すので、モデム側の削除に失敗しても
(既に無い / AT が落ちている)**取り込み直しで戻らない**。

> ⚠ **`sms_purge` はモデムの保存領域を丸ごと空にする**(選んでいる SIM が
> いま刺さっているものと同じときだけ)。取り込む前に届いたぶんも消える。
> 「この SIM の全件を削除」という表示どおりの挙動にしてある。

> ⚠ **`raw` 列は後から足した。** それ以前に取り込んだ行は空で、そのままだと
> 削除でモデム側の該当を特定できない。取り込み時に埋め戻す。
> **`unread` は触らない。**

### 保管庫 (SQLite)

既定は `/etc/sbair/sms.db`。**モデムに置いたままにできない理由が 2 つある:**

1. モデムの保存領域は溢れれば消える
2. 読み出しが未読を既読に変える。**最初に取り込んだときの未読状態は、
   そのとき記録しないと二度と分からない**

なので取り込みは `INSERT OR IGNORE`。**2 回目以降の取り込みで未読を上書きしない。**

同一性は**生の PDU の SHA-256**。送信者・時刻・本文の組では足りない —
一括送信は同じ秒に同じ本文を複数投げてくる。

#### 置き場所は uci で変えられる

```sh
uci set sbair.sms=sms
uci set sbair.sms.db=/data/sbair/sms.db
uci commit sbair
mv /etc/sbair/sms.db /data/sbair/sms.db      # ★ 自分で移すこと
```

環境変数 `SBAIR_SMS_DB` でも上書きできる(uci より優先。試すとき用)。
**相対パスは受けない** — rpcd から呼ばれるときの作業ディレクトリが何も
保証されないので、呼ばれ方によって別のファイルを開くことになる。

**自動移行はしない。** 黙って動かすと、どちらが本物か分からなくなる。
代わりに、**既定の場所に古い DB が残っていれば警告を出す**(移し忘れると
「SMS が全部消えた」ように見えるが、実際は置き去りなだけ)。

> ⚠ **既定の `/etc` は、この機体でいちばん壊れやすい場所である。**
>
> | | 再起動 | A/B 切替 | rootfs を `dd` で焼き直す |
> |---|---|---|---|
> | `/etc` (overlay) | 残る | **消える** | **消える** |
> | `/data` (user_data) | 残る | 残る | 残る |
>
> overlay は **rootfs パーティションの中**にあるので、その面を焼くと消える。
> **実際に 2026-08-08 の焼き直しで消した。**
>
> **それでも既定は `/etc` のまま。** `/data` はベンダ領域 (`/data/knos`,
> `/data/mdlog`) で、**工場出荷リセットでどうなるかを確かめていない**。
> 確かめたら既定を変えてよい。

#### sysupgrade で持ち越す

`install.sh` が `/lib/upgrade/keep.d/luci-app-sbair-modem` を置く:

```
/etc/config/sbair
/etc/sbair/
```

**これが無いと正規の更新手順でも消える。** ただし **`dd` で焼くときには
効かない**(overlay ごと消えるため)。そのときは別途 tar で退避すること。
DB を別の場所へ移したら、**その行も keep.d に足すこと。**

> **純 Go の SQLite (`modernc.org/sqlite`) を使う。** この機体向けは
> `CGO_ENABLED=0` の静的ビルドが前提で、機体にある `libsqlite3.so.0` に
> 動的リンクするとその前提が崩れる。**バイナリは 6.1 MB → 10.4 MB。**

> **電話番号 (`AT+CNUM`) は空のことがある。** EF_MSISDN を持たない profile は
> 珍しくないので、`sim.number` は NULL 可、画面は ICCID でも選べるようにする。

> ⚠ **`sms_list` は未読を既読に変える**(3GPP の規定で避けようがない)。
> そのため画面は**開いただけでは読みに行かない**。定期更新は `sms_status`
> (件数のみ) で回し、本文は明示のボタンで取る。

デコーダは `pdu.go`。`pdu_test.go` に GSM 7bit / UCS2 / 連結 (septet offset) /
SCTS のタイムゾーン / DCS のベクタがある — **実機に 1 通も入っていない状態でも
壊れたことが分かるように**、`go test ./src/sbair-modem` で回る。

返る 1 通の形:

```json
{ "indexes": [1,2], "from": "+8190...", "time": "2026-08-07T19:22:31+09:00",
  "text": "…", "unread": true, "parts": 2, "missing": [3] }
```

`missing` は届いていない分割の番号。**揃うまで伏せずに、届いているぶんを出す。**

> ⚠ **連結メッセージ (UDH) は実データで未検証。** 単体テストは通っている。

> **SMS が届かないときはまず IMS を見ること。** SMS は IMS 経由で配送される。

## IMS

| メソッド | |
|---|---|
| `ims_status` | 登録状態と、使えるサービスの一覧 |
| `ims_set` | 切替 |

**出荷状態では無効。** そのままだと SMS が 1 通も届かない。

> ⚠ **モデムが返す設定値を判定に使わない。** 登録しているのに `Off` を返す
> ことがあるので、`ims_status` は登録状態のほうを真とする。

> ⚠ **「オン/オフ」と断定しない。** 無効にしても登録と SMS が残ることがある。
> 画面はモデムが申告するサービスのビットをそのまま出す。

> **再起動はまたぐ。** 効かなくなるのは設定を初期化したときで、そのとき
> SIM ロックが出荷既定へ戻り、圏外になるので IMS も登録できない。

## モデムのリセット

| メソッド | |
|---|---|
| `modem_reset` | 電波を落として上げ直し、WAN を張り直す。非同期 (30〜60 秒) |
| `modem_reset_status` | 進捗。**AT を開かない** |

> データコールの失敗のしかたによってはモデム側のセッションが詰まり、
> netifd がいくら再試行しても上がらなくなることがある。そのときの逃げ道。
> **自動では走らせない** — 固着しない失敗もあり、毎回落とすと通信が余計に切れる。

## 時間のかかる処理

`simmap_set` / `esim_download` / `simlock_set` / `modem_reset` / `band_set` は
同じ形。足回りは `job.go`、状態はroot専用の`/var/run/sbair/jobs/<job>.json`。

1. **ワーカーを `setsid` で切り離して起動し、すぐ返る**。
   rpcd は呼び出し終了時にプロセスグループを殺すので、`setsid` が無いと
   **途中で切られる**
2. ワーカーは進捗を `/var/run/sbair/jobs/<job>.json` に、0600で原子的に書く
3. `*_status` は**そのファイルだけ**を読む。**AT には触らない** —
   ワーカーが flock を握っている間こそ進捗を見たいため

## 画面

`admin/sbair` の下に 5 つの機能領域。各領域はLuCIの標準 `firstchild` 子画面で
グループ化する。共通の小物は
`htdocs/luci-static/resources/tools/sbair.js`(`require tools.sbair`)。

| | |
|---|---|
| `admin/sbair/mobile` | モバイル回線の親画面（状態へ移動） |
| `admin/sbair/mobile/status` | 回線概要 / 電波 / バンド / IMS / モデムのリセット |
| `admin/sbair/mobile/sim` | SIM / eSIM。SIMマッピング、ロック、APN、profile操作を含む |
| `admin/sbair/mobile/sms` | 受信SMS。SIMごとに一覧 |
| `admin/sbair/wifi` | Wi-Fiの親画面（基本設定へ移動） |
| `admin/sbair/wifi/basic` | Wi-Fi基本設定。通常のSSID / radio操作 |
| `admin/sbair/wifi/advanced` | Wi-Fi詳細設定。無線出力 / Steering / Isolation / 11r / MACフィルタ / WPS / 再起動 |
| `admin/sbair/wifi/diagnostics` | Wi-Fi診断。UCI / vendor persistent / runtime / Known-goodのMonitor only |
| `admin/sbair/clients` | 接続機器一覧。端末ごとの広告ブロック操作を含む |
| `admin/sbair/network` | ネットワークの親画面（接続モードへ移動） |
| `admin/sbair/network/netmode` | 接続モード。高リスク設定とSafe Apply |
| `admin/sbair/network/lan-services` | LAN DHCPサーバーの状態・切替。DHCPクライアントとは分離 |
| `admin/sbair/network/diagnostics` | Bridge / NIC / link / USB Host Ethernet候補の読み取り専用診断 |
| `admin/sbair/device` | 本体の親画面（本体情報へ移動） |
| `admin/sbair/device/info` | 機種 / ファームウェア / IMEI と温度 |
| `admin/sbair/device/usb` | USB機器の読み取り専用診断 |
| `admin/sbair/device/update` | アップデート管理。OTA / FOTA自動更新の管理 |

自動更新するのはモバイル回線 > 状態だけ(15 秒)。他は明示のボタンで読み直す。
処理中だけ `*_status` を 3 秒間隔で見に行き、終わったら止める。

**メニューは `admin/sbair` に置いてある。** `admin/modem` は他のモデム系アプリと
親ノードを奪い合うので使わない。

- **識別子(IMEI / IMSI / ICCID / EID / Cell ID / 電話番号 / SMS の送信者)は
  既定で伏せる**
- **ネットワークに登録されていないときは電波の数値に注記を出す。** モデムは
  登録されていなくても見えているセルの測定値を返すので、素の数字だけ出すと
  繋がっているように見える
- **eUICC の操作は物理スロットを見ていて、かつカードが eUICC のときだけ。**
  通常の SIM が挿さっているのは正常な状態として出す
- **切替と profile 操作には確認ダイアログを出す。** 切替は電波を止めるし、
  `delete` は取り消せない

## 動作確認

```sh
ubus list | grep sbair
ubus -v list sbair
ubus call sbair overview
ubus call sbair esim_status
```

画面が使う経路(LuCI セッション → `/ubus/`)まで見るなら:

```sh
curl -s -c cj -d 'luci_username=root&luci_password=PASS' http://<ip>/cgi-bin/luci
SID=$(curl -s -b cj http://<ip>/cgi-bin/luci/admin/sbair/overview \
      | grep -oE 'sessionid"?:"?[0-9a-f]{32}' | grep -oE '[0-9a-f]{32}')
curl -s -b cj -H 'Content-Type: application/json' \
  -d "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"call\",\"params\":[\"$SID\",\"sbair\",\"overview\",{}]}" \
  http://<ip>/ubus/
```

画面の描画は node で回せる(LuCI の枠組みだけスタブし、`tools/sbair.js` と
view は本物を読む)。**枠組み以外をスタブで代用しないこと** — 代用した
`sbair.row` が本物と違っていて、`[object HTMLSpanElement]` を見逃した。
