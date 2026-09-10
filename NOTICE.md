# 第三者のソフトウェアについて

ライセンスは [LICENSE](LICENSE)(MIT)。
**`sbair-modem` の配布バイナリには、実機向けの target build (`CGO_ENABLED=0`,
`GOOS=linux`, `GOARCH=arm64`) で以下の third-party Go modules がリンクされます。**

## リンク済み Go modules

下表は `src/sbair-modem` で `go list -deps` を target build 条件で実行し、
その後 `build.sh` で生成した静的バイナリの `go version -m` と照合した現在の一覧です。
バージョンは `go.mod` / `go.sum` の解決結果です。

| module | version | license | 同梱 license / notice |
| --- | --- | --- | --- |
| `github.com/damonto/euicc-go` | `v1.1.2` | MIT | [`licenses/euicc-go.LICENSE`](licenses/euicc-go.LICENSE)、[`licenses/euicc-go-bertlv.LICENSE`](licenses/euicc-go-bertlv.LICENSE) |
| `github.com/dustin/go-humanize` | `v1.0.1` | MIT | [`licenses/go-humanize.LICENSE`](licenses/go-humanize.LICENSE) |
| `github.com/google/uuid` | `v1.6.0` | BSD-3-Clause | [`licenses/google-uuid.LICENSE`](licenses/google-uuid.LICENSE) |
| `github.com/remyoudompheng/bigfft` | `v0.0.0-20230129092748-24d4a6f8daec` | BSD-3-Clause | [`licenses/remyoudompheng-bigfft.LICENSE`](licenses/remyoudompheng-bigfft.LICENSE) |
| `golang.org/x/sys` | `v0.47.0` | BSD-3-Clause | [`licenses/golang-x-sys.LICENSE`](licenses/golang-x-sys.LICENSE) |
| `modernc.org/libc` | `v1.74.4` | BSD-3-Clause、同梱 third-party notices | [`licenses/modernc-libc.LICENSE`](licenses/modernc-libc.LICENSE)、[`licenses/modernc-libc.LICENSE-3RD-PARTY.md`](licenses/modernc-libc.LICENSE-3RD-PARTY.md)、[`licenses/modernc-libc-uint128.LICENSE`](licenses/modernc-libc-uint128.LICENSE)、[`licenses/modernc-libc-crypt.LICENSE`](licenses/modernc-libc-crypt.LICENSE) |
| `modernc.org/mathutil` | `v1.7.1` | BSD-3-Clause | [`licenses/modernc-mathutil.LICENSE`](licenses/modernc-mathutil.LICENSE) |
| `modernc.org/memory` | `v1.11.0` | BSD-3-Clause、mmap 部分の BSD notice | [`licenses/modernc-memory.LICENSE`](licenses/modernc-memory.LICENSE)、[`licenses/modernc-memory.LICENSE-MMAP-GO`](licenses/modernc-memory.LICENSE-MMAP-GO) |
| `modernc.org/sqlite` | `v1.56.0` | BSD-3-Clause、SQLite public domain、取り込み Go code の BSD notice | [`licenses/modernc-sqlite.LICENSE`](licenses/modernc-sqlite.LICENSE)、[`licenses/modernc-sqlite.SQLITE-LICENSE`](licenses/modernc-sqlite.SQLITE-LICENSE)、[`licenses/modernc-sqlite-go-database-sql.LICENSE`](licenses/modernc-sqlite-go-database-sql.LICENSE) |

`modernc.org/sqlite` は `smsdb.go` から実際に import され、SQLite 自体の public-domain
表示だけで wrapper/runtime の条件を置き換えていません。`modernc.org/libc` の生成コードに
含まれる third-party notice と inline license も分離して同梱しています。

ソース repository の公開に加えて、静的リンク済み `out/sbair-modem` またはそれを含む
rootfs/package/archive を配布する場合も、上記 `licenses/` の表示を同梱してください。
runtime filesystem へ不要な license file を自動配置する設計にはしていません。

## github.com/damonto/euicc-go v1.1.2 — MIT

SGP.22 (RSP) の実装としてこのライブラリを使う。
ES9+ の profile ダウンロードは SM-DP+ との TLS と ECDSA の署名検証を伴い、
規格に沿った実装が要るため、自前で書き直す対象にはしていない。

- ライセンス全文: [`licenses/euicc-go.LICENSE`](licenses/euicc-go.LICENSE)
- `bertlv` subpackage の license: [`licenses/euicc-go-bertlv.LICENSE`](licenses/euicc-go-bertlv.LICENSE)
- Copyright (c) 2025 Damon To

> ⚠ **`sbair-modem` は `CGO_ENABLED=0` の静的リンクで作る。**
> 生成されるバイナリには上記のリンク済み Go modules のコードが含まれるため、
> **バイナリを配布するときは `licenses/` のライセンス表示を一緒に配ること**。
> `licenses/` をそのまま同梱すればよい。

ソースコードそのものは Go モジュールとして取得され、このリポジトリには入っていない
(`src/sbair-modem/go.mod` / `go.sum` が版を固定している)。

## Karin-Laboratory/sbat6-usb-nic — GPL-2.0-only（任意機能）

`extras/usb-nic/` は、Air 6 を USB CDC-NCM gadget として動かすための実験的な任意機能です。
upstream の `t6a_usb_ncm_65532_candidate_v1.ko` をリポジトリへ再配布せず、固定 revision
から取得して SHA256 を検証します。この kernel module は本体の MIT ソフトウェアへリンク
されず、GPL-2.0-only の第三者ソフトウェアとして別 bundle に保存されます。

現在の upstream 公開 binary は live-validated ですが、source/binary 対応が provenance-based
の B2 扱いです。本リポジトリはそれを clean-build と同一のソース由来だとは主張せず、LuCI
上でも Experimental / 新規用途には非推奨として表示します。ライセンスと provenance の
詳細は [upstream repository](https://github.com/Karin-Laboratory/sbat6-usb-nic) を参照してください。

## 同梱データ

### `src/sbair-modem/data/adblock-domains.txt`

このリストは、複数ソースを混ぜた aggregate output ではなく、
[StevenBlack/hosts の `data/StevenBlack/hosts`](https://github.com/StevenBlack/hosts/blob/83dd698bbcdcb8c11a7796af7188d7ab4ccd02f1/data/StevenBlack/hosts)
だけから生成したドメイン一覧です。固定revisionは
`83dd698bbcdcb8c11a7796af7188d7ab4ccd02f1`（Release 3.16.113）です。
生成器は [`tools/update-adblock-domains.sh`](tools/update-adblock-domains.sh) で、コメントを除き、
有効なhostnameだけを正規化・重複除去・`LC_ALL=C`でソートして出力します。
このソースはupstream READMEでMITと明記され、ライセンス本文は
[`licenses/StevenBlack-hosts.LICENSE`](licenses/StevenBlack-hosts.LICENSE) に同梱しています。

### `src/sbair-modem/data/oui.tsv`

この TSV は MAC アドレスの OUI と組織名を収録した変換済みスナップショットです。
IEEE Registration Authority は OUI/MA-L と公開リストを案内していますが、現在のファイルには
正確な取得元 URL、取得日、変換手順、再配布条件が記録されていません。公開リストに掲載されて
いることだけを根拠に、自由な再配布ライセンスがあるとは扱いません。

**公開判定: 要対応。** 正確な snapshot の provenance と再配布条件を確認して記録するか、
条件を確認できない場合は同梱を見直してください。
