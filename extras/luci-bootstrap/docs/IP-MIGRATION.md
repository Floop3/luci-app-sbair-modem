# Optional IP migration notes

bootstrapの標準処理は、LAN IP、DHCP、gateway、DNSを変更しません。
`network.lan.ipaddr` とruntimeの `br-lan` IPが一致しない場合も、section番号を推測して
削除せず停止します。

## 状態を確認

```sh
uci show network.lan
uci show network | grep -B3 -A10 "name='br-lan'"
ip -4 addr show br-lan
```

`network.lan.ipaddr` とruntimeの値が違う個体だけ、UARTなどの復旧経路を確保してから
作業します。`network.@device[3]` のようなsection番号は個体間で決め打ちしません。

## 古いdevice IPを除去する場合

該当sectionを表示内容から特定し、先に設定を保存します。

```sh
cp -p /etc/config/network /root/network.before-ipfix
uci -q delete network.<確認したsection>.proto
uci -q delete network.<確認したsection>.ipaddr
uci -q delete network.<確認したsection>.netmask
uci commit network
/etc/init.d/network restart
```

再起動後ではなく、まずruntimeが意図した値になったことを確認します。

```sh
ip -4 addr show br-lan
```

## 別サブネットのgateway/DNS

Air6を `<AIR6_IP>`、親ルーターを `<UPSTREAM_ROUTER_IP>` にした個体だけ、必要に応じて
次を設定します。純正 `192.168.3.1` のままで外部通信が成立する個体には不要です。

```sh
uci set network.lan.gateway='<UPSTREAM_ROUTER_IP>'
uci -q delete network.lan.dns
uci add_list network.lan.dns='<UPSTREAM_ROUTER_IP>'
uci add_list network.lan.dns='1.1.1.1'
uci add_list network.lan.dns='8.8.8.8'
uci commit network
```

この文書は任意のネットワーク移行手順です。LuCI bootstrapの標準インストールは、
IP変更が必要だと判断しても自動でこれらを実行しません。
