# Troubleshooting

## SSHで到達できない

Air6自身のInternet接続はhost-assisted installの前提ではありません。まずホストから
SSHだけを確認します。

```sh
ssh root@<current-LAN-IP> 'cat /etc/openwrt_release; ip -4 addr show br-lan'
```

AP/Bridge構成では、ホストがAir6と同じL2にいるか、ARPが解決できるかを確認します。
`install.sh` はIPを推測・変更しません。

## preflightでplatformが拒否される

このbootstrapは次の組み合わせ以外を変更しません。

```text
DISTRIB_RELEASE=21.02.7
DISTRIB_TARGET=gem6xxx/evb6990_cpe_mt7990_emmc
DISTRIB_ARCH=aarch64_cortex-a55_neon-vfpv4
```

vendor firmwareやOpenWrtの別releaseへ無理に適用せず、対象用のmanifestを別途検証して
から実装を分けてください。

## `--check` がTCP/8080だけNG

まずAir6自身で、LuCIがlocalhostから動くかを見ます。

```sh
ps w | grep '[u]httpd'
netstat -lntp 2>/dev/null | grep ':8080 '
curl -i http://127.0.0.1:8080/cgi-bin/luci/
```

未ログイン時の `403 Forbidden` は正常です。localhostが成功してLANからだけ失敗する
場合はFirewallを確認します。

```sh
iptables -C INPUT -i br-lan -p tcp --dport 8080 -j ACCEPT
uci show firewall.sba6_user_include
grep -n 'LUCI-LAN-SBA6' /etc/firewall.user
```

必要なら次を実行します。これはパッケージを再導入しません。

```sh
./extras/luci-bootstrap/install.sh --repair root@<current-LAN-IP>
```

## 再起動後だけ接続できない

uhttpdの自動起動とnamed includeが持続しているか確認します。

```sh
/etc/init.d/uhttpd enabled
uci show firewall.sba6_user_include
iptables -C INPUT -i br-lan -p tcp --dport 8080 -j ACCEPT
```

`uhttpd`がlistenしていてもFirewallだけ消えている場合、`--repair`でuhttpd設定、
firewall.user、named include、rpcd cacheを再構築できます。

## package dry-runが停止する

`target.sh` は次を危険な計画としてabortします。

- downgradeまたはremove
- libc、kernel、kmod、libubus、libuci、libubox、libjson、liblua、libnlなどのvendor ABI変更
- vendorの `libiwinfo20230701` 変更

`/root/sba6-pre-luci-*/opkg.before.txt` と、失敗時のhost側ログを保存したまま、
platformとvendor package statusを確認してください。`opkg upgrade`で先に整合させる
方法は採りません。

## `libnl-tiny.so` ABI testに失敗する

公式21.02.7の `libnl-tiny1` はopkg installされず、`data.tar.gz`から一時展開されます。
失敗時はvendorの `/usr/lib/libnl-tiny.so.1` を変更せず停止します。Air6上で、
vendor package statusと空き容量を確認してから再実行してください。
