# USB NIC gadget の復旧方針

この機能は、USB UDC / ConfigFS の ownership を変更するため、別の LAN または Wi-Fi
管理経路を確保せずに有効化してはいけません。USB 側の接続を失っただけでは「失敗」と
判断せず、独立した管理経路から status を確認してください。

## まず行うこと

```sh
/usr/sbin/sbair-usb-nic status
/usr/sbin/sbair-usb-nic preflight
```

必要なら、独立した SSH / UART から次を実行します。

```sh
/usr/sbin/sbair-usb-nic disable
```

Disable は app-owned の exact gadget topology だけを unbind / cleanup します。未知の
ConfigFS object、vendor gadget の function、想定外の UDC binding がある場合は削除せず、
`rollback-required` として停止します。module は force unload しません。再起動や vendor
の USB init script の盲目的な再実行を復旧手段にしません。

## 手動復旧が必要な場合

status が示す snapshot の場所を、独立した管理経路から保全してください。snapshot は
有効化直前の ConfigFS と UDC の baseline を root-only で保存したものです。baseline を
正確に再構成できない場合、UDC は unbound のままにして、vendor topology を推測で再作成
しないでください。実機固有の vendor gadget 復旧は、Karin-Laboratory の upstream
[RECOVERY.md](https://github.com/Karin-Laboratory/sbat6-usb-nic/blob/main/docs/RECOVERY.md)
と、機体の UART 手順に従ってください。

この bundle は工場出荷状態への復元や firmware recovery を提供しません。リセット、
`firstboot`、firmware 書き込みなどはこの機能の自動復旧処理ではありません。
