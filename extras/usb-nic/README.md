# SBA6 USB NIC（CDC-NCM Gadget）— experimental optional bundle

これは、SoftBank Air 6 / SBA6D 自身を USB CDC-NCM gadget として動かすための
**実験的・高リスク**な補助機能です。Air 6 に接続した USB Ethernet などを調べる
既存の「本体 > USB機器」インベントリや、そこにある将来用のドライバ操作欄とは別物です。

通常の `install.sh` には含まれず、デフォルトでは未導入・未ロード・未有効です。
`.ko` もこのリポジトリには同梱しません。

## インストール（bundle の導入だけ）

Mac / Linux ホストで次を実行します。

```sh
./extras/usb-nic/install.sh root@<Air6の管理IP>
```

ホスト側で upstream の固定 revision から候補バイナリを取得し、SHA256 を検証して
SSH 転送します。Air 6 自身に Internet、DNS、default route は要求しません。
導入後も module の load、ConfigFS、UDC、`usb0`、LAN/WAN、bridge、firewall、Wi-Fi、
再起動は行いません。

状態確認だけを行う場合は次です。

```sh
./extras/usb-nic/install.sh --check root@<Air6の管理IP>
```

## 有効化の前提

有効化は別操作であり、LuCI の「本体 > USB機器 > USB NIC（CDC-NCM Gadget）」からのみ
明示的に行います。まず upstream の実機でレビューした値を含む activation profile を
`--profile FILE` で導入してください。次の値を推測・自動生成・ベンダ gadget からの
自動コピーはしません。

```text
VID_HEX
PID_HEX
DEV_MAC
HOST_MAC
USB0_ADDR
PEER_IPV4
```

profile は owner-only（mode 600）で保存され、値は status やログに表示しません。profile
が無い／不正な場合、bundle が導入済みでも Enable は利用できません。USB path を
`br-lan` へ bridge したり、LAN/WAN/DHCP/Wi-Fi を変更したりしません。USB host を切断し、
別の LAN または Wi-Fi 管理経路と物理復旧手段を確保してから操作してください。

## 固定している upstream 情報

`driver.lock` は upstream revision、artifact、SHA256、kernel、architecture、vermagic、
license、検証済み topology を固定しています。現在の候補は次の topology です。

```text
gadget   = t6a_ncm_test
function = t6a_ncm.test0
config   = c.1
UDC      = 11201000.usb
network  = usb0
```

候補 v1 は upstream の live-validated binary ですが、公開 source と binary の対応は
provenance-based の B2 扱いで、upstream 自身が新規用途には非推奨としています。したがって
この bundle を通常サポートの製品ドライバとして扱わず、実験機能として表示します。詳細は
[Karin-Laboratory/sbat6-usb-nic](https://github.com/Karin-Laboratory/sbat6-usb-nic) と
同リポジトリの安全文書を確認してください。

## 有効化・無効化と復旧

初期実装では cold boot の autostart を追加しません。再起動後に自動で UDC を奪いません。
Enable 前には read-only preflight、profile、module hash、kernel/vermagic、ConfigFS の
所有状態、UDC、USB speed、`usb0`、`br-lan` 管理経路を確認します。失敗時は専用 gadget
だけを対象にした限定 rollback を試み、未知の ConfigFS object や vendor topology を
削除しません。`rmmod -f`、vendor gadget の再作成・削除、UDC driver 操作、blind reboot は
行いません。

復旧手順は [docs/RECOVERY.md](docs/RECOVERY.md) を参照してください。
