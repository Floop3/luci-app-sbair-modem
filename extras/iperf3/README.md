# Air6 iperf3 installer

\`air6-install-iperf3.sh\` は、Mac側でOpenWrt 21.02.7の公式
\`aarch64_generic\` feedから \`iperf3\` と、Air6に不足している直接の
ユーザー空間依存パッケージだけを取得・SHA256検証し、SSH経由でSoftBank Air 6
へ転送してローカルインストールする補助スクリプトです。

Air6自身はパッケージをダウンロードしません。MacからHTTPSで取得・検証した
IPKを既存のLAN上のSSH接続でAir6の\`/tmp\`へ送り、Air6側の\`opkg\`には
そのローカルファイルだけを渡します。DNS、default route、gateway、DHCP、
LAN、Wi-Fi、cellular WAN、LuCI、SSH、FOTAは変更しません。

## 使い方

\`\`\`sh
./extras/iperf3/air6-install-iperf3.sh install <AIR6_IP>
./extras/iperf3/air6-install-iperf3.sh check <AIR6_IP>
./extras/iperf3/air6-install-iperf3.sh start <AIR6_IP>
./extras/iperf3/air6-install-iperf3.sh stop <AIR6_IP>
./extras/iperf3/air6-install-iperf3.sh test <AIR6_IP>
\`\`\`

\`AIR6_HOST\`、\`AIR6_USER\`、\`AIR6_SSH_PORT\`でも指定できます。Air6のアドレスに既定値はありません。
ユーザー名の既定値は\`root\`、SSHポートの既定値は22番です。

\`\`\`sh
AIR6_HOST=<AIR6_IP> ./extras/iperf3/air6-install-iperf3.sh install
\`\`\`

パスワード認証が必要な場合は、スクリプト実行時にSSHのパスワードプロンプト
へ入力します。Homebrew、Python、jq、sshpassは要求しません。

## 実際に確認したパッケージ

2026-09-10に公式Packages.gzを確認した結果、iperf3は次の内容でした。

- Package: \`iperf3\`
- Architecture: \`aarch64_generic\`
- Version: \`3.10.1-1\`
- Depends: \`libc\`
- SHA256検証対象: \`iperf3_3.10.1-1_aarch64_generic.ipk\`

\`libc\`はcore/vendorパッケージなので、Air6に存在しない場合は安全のため
中止し、置換・アップグレードしません。

## 安全性

- Air6のリリースが\`21.02.7\`、CPUが\`aarch64\`、\`opkg\`が存在することを事前確認。
- \`Packages.gz\`から\`iperf3/aarch64_generic\`のVersion、Filename、SHA256sum、
  Dependsを取得し、同じfeedから該当IPKを取得。
- SHA256はMac上で検証し、\`sha256sum\`がAir6に存在する場合は転送後にも再検証。
- Air6側のopkgには\`all\`、\`noarch\`、\`aarch64_generic\`、vendor architectureを
  コマンド単位で一時追加するだけで、\`/etc/opkg/arch.conf\`やfeed設定は変更しない。
- dry-runの出力にupgrade、downgrade、remove、download、libc/libubus/libuci/
  libubox、kernel、kmod、kn_、mtk_系の危険な処理があれば中止。
- \`opkg upgrade\`、\`opkg update\`、core/vendorパッケージの強制置換は実行しない。
- \`start\`のTCP/5201許可は\`br-lan\`からだけの一時iptablesルール。
  \`/etc/firewall.user\`には書き込まず、\`stop\`はこのヘルパーが追加した
  同一ルールだけを削除する。
- iperf3のinit scriptやboot autostartは追加しない。
- installではAir6のネットワーク、Wi-Fi、LuCI、SSH、FOTA設定を変更せず、再起動もしない。

\`aarch64_generic\`はAir6のvendor architectureと互換性のある公式ユーザー空間
パッケージを選ぶための一時指定です。永続化されません。

## Wi-Fi経路の測定

`start` と `test` は従来どおり使用できます。`test` は既存の TCP/5201 サーバーを
起動・再利用し、MacからAir6自身へ直接測定します。OMV、SMB、ストレージ、別ホストの
Ethernet中継は使用しません。

```sh
./extras/iperf3/air6-install-iperf3.sh test <AIR6_IP>
```

診断用の新しいコマンドは次のとおりです。

```sh
# 読み取り診断、一時サーバー、-P4対独立4プロセス、UDP受信側ロス sweep
./extras/iperf3/air6-install-iperf3.sh diagnose <AIR6_IP>

# 上記に加え、RPS -> backlog -> 高信頼IRQ affinityを段階的に試し、自動復元
./extras/iperf3/air6-install-iperf3.sh experiment <AIR6_IP>

# 中断やSSH断などで残った一時スナップショットを復元
./extras/iperf3/air6-install-iperf3.sh rollback <AIR6_IP>
```

`diagnose` と `experiment` の TCP 既定時間は10秒、UDP各段階は2秒です。
`--duration SEC`、`--udp-duration SEC` で短縮・延長できます。必要な場合だけ
`--reference-host HOST` を追加すると、外部iperf3サーバーへの任意の比較も行います。
Mac側にiperf3が無い場合はインストールを自動化せず、必要な対応を表示して終了します。

## 測定の解釈

- 最初に、Air6上の1つのiperf3サーバーへMacが `-P 4` で接続する場合と、5211--5214
  の4つの一時サーバーへ4つのMacクライアントを同時に起動する場合を比較します。
  Air6のiperf3は3.10.1で、`-P 4` が4コアを有効利用するとは仮定しません。
- TCPの表は常に receiver summary の delivered throughput を使います。独立プロセスは
  4プロセス分を合計します。解析不能な場合は値を推測せず、生の出力を残します。
- UDPは100Mから1000Mまでを両方向で測定し、requested bitrate、sender/receiver bitrate、
  receiverのlost/total datagrams、receiver loss%、jitterを表示します。エンドツーエンドの
  ロス判定はreceiver側だけを正とし、sender側の `0%` をロスなしとは解釈しません。
- `-Z` / `--zerocopy` が利用可能な場合だけ追加比較します。非対応でも診断全体は失敗しません。

各ベンチマークの前後に、Air6の `/proc/stat`、`/proc/interrupts`、`/proc/softirqs`、
`/proc/net/softnet_stat`、`/proc/net/dev`、CPU周波数・温度、関連sysctl、選択した
netdevのqueue設定を生のまま保存します。CPUごとの busy/idle/irq/softirq、NET_RX/NET_TX、
`softnet_stat` の processed/dropped/time_squeeze 差分を表示します。

Wi-Fiインターフェースは `br-lan` の実メンバーと sysfs/`iw` のAP情報から動的に選びます。
候補が複数ならMac→Air6の短い ingress `rx_bytes` probeで比較し、同率・不明確なら
RPSを自動適用しません。既存アプリと同じ `iw dev`、`hostapd_cli`、`iwinfo` の
テレメトリ経路を読み取りに使い、Wi-Fi設定自体は変更しません。

IRQも名前だけで選ばず、選択netdevのsysfs device IRQと、測定前後の `/proc/interrupts`
差分を突き合わせます。timer/IPIや共有・同程度の候補は除外し、高信頼でない場合は
affinity変更をスキップします。USB-NIC記事のxHCI affinityコマンドは、今回の
Mac Wi-Fi → Air6ローカルsocket経路にxHCIが存在する証拠がないためコピーしません。

## 可逆性と測定経路の注意

`experiment` は最初の tuning write 前に、変更対象の `rps_cpus`、
`net.core.netdev_max_backlog`、IRQ affinityをAir6の `/tmp` に保存します。変更は
RPS、必要な場合のbacklog=5000、最後に高信頼IRQ affinityだけです。中断、SSH断、
iperf/parserエラーでも復元を試み、正常終了時にも全値を読み戻して `[OK] restored`
を確認します。スナップショットが残った場合は `rollback` を再実行してください。

一時ファイアウォールルールは `br-lan` INPUT の測定ポートだけで、作成した同一ルール
だけを削除します。`/etc/sysctl.conf`、`/etc/rc.local`、init script、firewall設定、
Wi-Fi設定には書き込みません。XPS/RFS、GRO/GSO/TSO、TCP buffer/輻輳制御、MTU、CPU
周波数、thermal、vendor Wi-Fi設定、パッケージ更新も行いません。

Air6ローカルiperf3の結果は、
`Mac Wi-Fi → Air6 kernel → Air6 iperf3 userspace` の経路の測定です。これは
`Mac Wi-Fi → Air6 bridge/vendor datapath → 外部サーバー` のAP転送性能と同じではありません。
`--reference-host` の比較を使っても、ネットワーク設定を変更せずに別経路の差を観測する
だけです。永続的な性能調整は、再現性のある測定結果が得られるまで追加しません。
