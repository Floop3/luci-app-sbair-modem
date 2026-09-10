# luci-app-sbair-modem

**SoftBank Air 6（RG620T-SBK / RUDOLF）専用のLuCIアプリ**です。
モデムの状態表示、eSIM管理、SIMロック、APN、SMSの受信に加えて、
SoftBank Air 6を安全にAP / Bridgeとして運用するための接続モード管理を扱います。

---

## 対象と前提

| | |
|---|---|
| 機体 | SoftBank Air 6 / RG620T-SBK（MediaTek MT6990 + MD800内蔵モデム） |
| OS | OpenWrt 21.02.7（ベンダー改造版） |
| ATの入口 | **`/dev/adb_atci_socket`**（`atcid`がlistenするUNIXソケット） |
| SIM | 物理スロット1 + 内蔵eSIM 1。**同時に有効にできるのは1つ**（`AT+ESIMMAP?`） |
| 搭載されていないもの | `ttyUSB*` / `cdc-wdm*` / `qmi_wwan` / `cdc_mbim` |

---

## 画面

`admin/sbair`の下に5つの機能領域があります。モバイル回線、Wi-Fi、ネットワーク、本体には
LuCI標準の子画面があります。

| | |
|---|---|
| **モバイル回線** | **状態**（回線概要 / 電波 / バンド / IMS / 詳細操作）、**SIM / eSIM**、**SMS**を子画面に分離 |
| **Wi-Fi** | **基本設定**（SSID / Radio / 適用）、**詳細設定**（無線出力 / Steering / Isolation / 11r / MACフィルタ / WPS）、**診断**（UCI / vendor persistent / runtime / Known-good）を子画面に分離 |
| **接続機器** | 有線・無線端末の一覧、メモ、ポートスキャン、一時切断、端末ごとの広告ブロックを1画面で管理 |
| **ネットワーク** | **接続モード**（AP / Bridge・未管理・Safe Apply）、**LANサービス**（LAN DHCPサーバー）、**診断**（Bridge / NIC / USB Ethernet候補）を子画面に分離 |
| **本体** | **本体情報**（機種 / ファームウェア / IMEI / 温度）、**USB機器**、**アップデート管理**（OTA / FOTA）を子画面に分離 |

**識別子（IMEI / IMSI / ICCID / EID / Cell ID / 電話番号 / SMSの送信者）は、既定では伏せて表示します。**
チェックボックスで表示／非表示を切り替えられます。

---

## 構成

```
luci-app-sbair-modem/
├── root/usr/libexec/rpcd/sbair        rpcdの入口（2行。中身はsbair-modem rpcd）
├── root/usr/sbin/sbair-netmode        AP / Bridge設定・状態監視・復旧CLI
├── root/usr/sbin/sbair-maintenance    LAN DHCPサーバー / OTA保守CLI
├── root/usr/sbin/sbair-usb-nic        任意のUSB CDC-NCM gadget安全ゲート
├── root/usr/sbin/sbair-netfix         15秒周期でvendor設定を補正するデーモン
├── root/usr/sbin/sbair-wifidrift      Wi-Fiの差分を監視する軽量ポーリングデーモン
├── root/usr/share/sbair/firewall.include AP時のDHCPパケットガード用fw3 include
├── root/usr/share/rpcd/acl.d/         ACL
├── root/usr/share/luci/menu.d/        メニュー
├── htdocs/luci-static/resources/
│   ├── tools/sbair.js                 タブ共通のUIヘルパー
│   ├── protocol/ql_datacall.js        Network → InterfacesでWANを扱えるようにする
│   └── view/sbair/*.js                機能領域ごとのLuCI view
├── root/etc/init.d/sbair-apn          起動時にAPNを設定し、AT+CNMIを再設定する
├── src/sbair-modem/                   バックエンド（Go）
└── docs/API.md                        ubus APIとLuCI画面（SMS / IMS / バンド / リセット）
```

```
sbair-modem at [-r] [-t SEC] '<AT>'   ATコマンドを1本送信
            simlock [on|off]          SIMロックの表示 / 切り替え
            ims [on|off]              IMSの表示 / 切り替え
            reset                     モデムをリセット（CFUN 0/1）し、wanをifup
            sms                       受信SMSを保管庫へ取り込む
            apn [apply|probe]         APNの表示 / 適用 / SIMから読み出す
            netmode show|get-config   接続モードの状態 / 設定
            netmode netdev-status     有線 / USB・Kernel能力の読み取り専用診断
            netmode set-config ...     非推奨。draftだけを保存（ネットワーク変更なし）
            netmode apply sim|ap      Safe Apply（正常性確認後に自動確定 / 最大120秒でrollback）
            netmode confirm|rollback|repair
            netmode recover            192.168.3.1 + ローカルDHCPへ緊急復旧
            wifi-drift status|logs|mark-good|save-test|restart-test
            overview                  モデム状態をJSONで表示
            status                    SIMマッピングとカードの種別
            simmap [1|2]              SIMマッピングの表示 / 切り替え
            list / enable / disable / delete
            nickname <ICCID> [<NAME>] profileに名前を付ける
            download / discovery      ES9+ / ES11
            gc                        残存した論理チャネルを回収する
            rpcd list | call <method> rpcdバックエンド（rpcdから呼び出される）
```

---

## ビルドと導入

```sh
./build.sh              # out/sbair-modemをaarch64向けにビルド
./install.sh /          # 稼働中の実機へ導入
./install.sh <tree>     # 展開済みrootfsツリーへ導入
```

本体のGoバイナリは、CGOを無効にした静的リンクでビルドします。そのため、ビルドホストがglibc環境でも
OpenWrt（musl）上で実行できます。ビルドにはGo 1.25以上が必要です（OpenWrt 21.02に含まれるgolangは1.18のため不足します）。
goenvを使う場合は、`export PATH=$HOME/.goenv/bin:$HOME/.goenv/shims:$PATH`を実行してください。

### LuCI未導入の純正SoftBank Air 6向け（任意）

純正のAir 6へLuCI実行環境を追加する補助installerは、アプリ本体とは独立した
[`extras/luci-bootstrap/`](extras/luci-bootstrap/) にあります。既存LuCI環境へ
アプリだけ導入する場合は不要です。

```sh
./extras/luci-bootstrap/install.sh root@<現在のAir6管理IP>
./extras/luci-bootstrap/install.sh --check root@<現在のAir6管理IP>
```

これはホスト側でOpenWrt 21.02.7の固定マニフェストを取得・検証してからAir 6へ転送し、
LuCIをuhttpd `:8080`へ追加します。純正lighttpd `:80`、管理IP、vendor feedは変更せず、
自動再起動もしません。詳細は [`extras/luci-bootstrap/README.md`](extras/luci-bootstrap/README.md)を参照してください。

### USB NIC（CDC-NCM Gadget）— 実験的・任意

Air 6本体をUSB CDC-NCM gadgetとして動かす機能は、通常のUSB機器インベントリとは別の高リスク機能です。
デフォルトでは未導入・未有効化で、必要な場合に限り[`extras/usb-nic/`](extras/usb-nic/)のホスト側installerから
bundleを導入します。bundleの導入と実行時の有効化は分離されており、kernel moduleの読み込み、ConfigFS、
UDC、ネットワーク設定、起動時の自動有効化は、通常のアプリインストールでは行いません。

出典・クレジット：[Karin-Laboratory/sbat6-usb-nic](https://github.com/Karin-Laboratory/sbat6-usb-nic)。
モジュールはGPL-2.0-onlyの第三者ソフトウェアであり、本体のMITソフトウェアとは別扱いです。

確認は [docs/API.md](docs/API.md)。

このリポジトリではGitHub Actionsを使用していないため、検証はローカルfixtureで行います。
`go test ./...`、`go vet ./...`、`./tests/netmode-fixture.sh`、
`./tests/wifi-drift-fixture.sh`、`./tests/netdev-fixture.sh`、`./tests/netmode-js-fixture.sh`、
`./tests/luci-bootstrap-fixture.sh`、`./tests/maintenance-fixture.sh`、
`./tests/network-diagnostics-js-fixture.sh`、`./tests/ui-structure-fixture.sh`、
`./tests/usb-js-fixture.sh`、`./tests/usb-nic-fixture.sh`、`./tests/publication-hygiene-fixture.sh`、`./build.sh`が基本的な検証項目です。

### ネットワーク / LANサービス

`admin/sbair/network/lan-services`（LANサービス）では、Air 6がLAN端末にIPアドレスを配布する
**LAN DHCPサーバー**を管理できます。ここでいうDHCPサーバーは`dhcp.lan.ignore`だけを対象とし、
ネットワーク全体は再起動しません。

用語を混同しないでください。

| 機能 | 意味 | 管理元 |
|---|---|---|
| **DHCPクライアント** | Air 6自身が親ルーターから管理IPを取得する | ネットワーク > 接続モード。`network.lan.*` / `management_proto`はLANサービスから変更しません |
| **DHCPサーバー** | Air 6がLAN端末へIPアドレスを配布する | ネットワーク > LANサービス。`dhcp.lan.ignore`だけを変更します |

接続モードがAP / Bridgeとして管理されている間は、LAN DHCPサーバーの有効化を拒否します。
EasyMeshの設定は自動変更しません。DHCPサーバーの変更前には`/root/sbair-backups/`へ
タイムスタンプ付きのバックアップを作成します。

AP / Bridgeの固定IP欄を空欄にすると、初回の管理開始前に保存した純正の`network.lan`設定を継承します。
空欄をFallback `192.168.3.1`へ置き換えることはありません。純正値を取得できない必須項目は、
ネットワーク変更前に拒否されます。画面の適用プレビューで、純正値・適用予定値・値の出所を確認できます。

### 本体 / アップデート管理

`admin/sbair/device/update`（アップデート管理）では、純正の`kn_fotad`によるOTA / FOTA自動更新を管理できます。
OTA / FOTAを無効にすると、`fota.config.enabled=0`と`fota.provision.enabled=0`を保存し、
`kn_fotad`を停止して自動起動を無効にします。`fota.config.respawn`は変更せず、約10秒待って再起動（respawn）
していないことを確認します。いずれも自動再起動は行いません。

---

## ⚠ 注意

- **内蔵eSIMにはISD-Rがありません。** eUICCを操作できるのは物理スロットのカードだけで、
  `AT+ESIMMAP?`が`1`のときに限られます。**ただし、そのカードがeUICCとは限りません。**
  通常のSIMが挿入されている状態も正常として扱います。
- **`AT+ESIMMAP=<n>`を直接入力しないでください。** 必ず`AT+CFUN=4`で停止してから実行します。
  切り替え後20～30秒間はATに応答しません。
- **再起動すると物理スロット側へ移ります。** そこに有効なprofileがなければ圏外になります。
- **SIMロックは`AT+ESMLCK`を直接発行して解除します。** ベンダーの`/bin/sim_lock.sh`は戻り値を確認しないため、
  使用しません。解除後は`AT+CFUN=0` → `1`の実行が必要です。
- **IMSは出荷時には無効です。** **SMSはIMS経由で配送されるため、未登録の場合は届きません。**
  モバイル回線 > 状態から有効にできます。設定変更後は再起動が必要です。設定を初期化すると
  SIMロックが戻って圏外になり、IMSも登録できなくなります。
- **SMSの取り込みは、モデム側の未読を既読に変更します**（`AT+CMGL`の仕様上、避けられません）。
  保管庫には最初に取り込んだ時点の未読状態が残りますが、純正WebUIの未読表示は消えます。
- **eSIMのインストールには、この機体からインターネットへ接続できることが必要です。**
  既定ではデフォルトルートがありません。
- **AP / Bridgeの管理IP用DHCPクライアントは利用できますが、非常に高いリスクを伴います。** これは
  Air 6自身が上流ルーターから管理IPを取得する設定です。切り替えや適用に失敗すると、すべてのネットワーク接続を失い、
  ソフトブリックしてUARTによる復旧が必要になるおそれがあります。UARTなどの復旧手段を確保できない場合は、
  選択・適用しないでください。Safe Applyの自動ロールバックも、あらゆる設定失敗からの復旧を保証しません。
  無効化する場合は`uci set sbair.bridge.ap_dhcp_enabled=0 && uci commit sbair`を実行します。
- **初回インストールでは、既存の`dhcp.lan.ignore`からAPモードを推測しません。** LuCIで明示的にAPを適用するまで、
  ネットワーク設定は変更しません。APモードでは、Air 6自身のIPv4 DHCP OFFER/ACKを`br-lan`外向きでDROPするguardも維持します。
- **有線／USB診断は読み取り専用です。** `network.wan`の信頼できるプロトコルとdevice、netifdの状態、sysfsの実測だけを表示し、
  自動bridge・WAN割り当てやkernel moduleのインストールは行いません。

---

## ライセンス

MIT（→ [LICENSE](LICENSE)）。第三者ソフトウェアの扱いは[NOTICE.md](NOTICE.md)を参照してください。
