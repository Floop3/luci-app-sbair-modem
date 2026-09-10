#!/bin/bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Floop3
# Current-tree publication hygiene checks; history requires a separate rewrite gate.
set -euo pipefail

repo=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
fail() { echo "[FAIL] $*" >&2; exit 1; }

for pattern in "$(printf '192.%s.%s.' 168 50)" "$(printf '192\\.%s\\.%s\\.' 168 50)"; do
  if rg -n --hidden -I -g '!.git/**' -g '!out/**' -F "$pattern" "$repo" >/dev/null 2>&1; then
    rg -n --hidden -I -g '!.git/**' -g '!out/**' -F "$pattern" "$repo" >&2 || true
    fail "maintainer-specific network value remains: $pattern"
  fi
done
origin_lineage="github.com/$(printf 'soralis0912')/$(printf 'sbair6-')$(printf 'rs')"
if rg -n --hidden -I -g '!.git/**' -g '!out/**' -F "$origin_lineage" "$repo" >/dev/null 2>&1; then
  fail 'original-lineage repository URL remains in the current tree'
fi

while IFS= read -r path; do
  [ ! -e "$repo/$path" ] || fail "tracked .DS_Store is still present: $path"
done < <(git -C "$repo" ls-files | rg '(^|/)\.DS_Store$' || true)
if find "$repo" -path "$repo/.git" -prune -o -name .DS_Store -print | grep -q .; then
  fail 'untracked .DS_Store remains outside .git'
fi

if ! (cd "$repo" && AIR6_HOST= bash extras/iperf3/air6-install-iperf3.sh install >"${TMPDIR:-/tmp}/sbair-publication-iperf3.$$" 2>&1); then
  output="${TMPDIR:-/tmp}/sbair-publication-iperf3.$$"
  grep -q 'Air6 address is required' "$output" || { cat "$output" >&2; rm -f "$output"; fail 'iperf3 helper did not reject a missing target'; }
  rm -f "$output"
else
  output="${TMPDIR:-/tmp}/sbair-publication-iperf3.$$"
  rm -f "$output"
  fail 'iperf3 helper accepted a missing target'
fi
if rg -n -e "AIR6_HOST=.*$(printf '192.%s.%s.' 168 50)" extras/iperf3 >/dev/null 2>&1; then
  fail 'iperf3 helper has a private default target'
fi

grep -Fq '83dd698bbcdcb8c11a7796af7188d7ab4ccd02f1' tools/update-adblock-domains.sh || fail 'adblock source revision is not pinned'
grep -Fq 'data/StevenBlack/hosts' tools/update-adblock-domains.sh || fail 'adblock generator is not using the single MIT source'
[ -f licenses/StevenBlack-hosts.LICENSE ] || fail 'StevenBlack license text is missing'

! grep -Fq '1 つだけ外部ライブラリ' NOTICE.md || fail 'NOTICE still claims a single external library'
linked_license_files=(
  euicc-go.LICENSE
  euicc-go-bertlv.LICENSE
  go-humanize.LICENSE
  google-uuid.LICENSE
  remyoudompheng-bigfft.LICENSE
  golang-x-sys.LICENSE
  modernc-libc.LICENSE
  modernc-libc.LICENSE-3RD-PARTY.md
  modernc-libc-uint128.LICENSE
  modernc-libc-crypt.LICENSE
  modernc-mathutil.LICENSE
  modernc-memory.LICENSE
  modernc-memory.LICENSE-MMAP-GO
  modernc-sqlite.LICENSE
  modernc-sqlite.SQLITE-LICENSE
  modernc-sqlite-go-database-sql.LICENSE
)
for license_file in "${linked_license_files[@]}"; do
  [ -f "licenses/$license_file" ] || fail "linked-module license file is missing: $license_file"
  grep -Fq "licenses/$license_file" NOTICE.md || fail "NOTICE does not reference: $license_file"
done

[ -f src/sbair-modem/data/oui.tsv ] || fail 'OUI snapshot is missing'
[ -f src/sbair-modem/oui.go ] || fail 'OUI enrichment implementation is missing'
rg -n 'macVendor|c\.vendor' src htdocs >/dev/null 2>&1 || fail 'OUI vendor enrichment is missing from clients'

while IFS= read -r file; do
  while IFS= read -r token; do
    link=${token#](}
    link=${link%)}
    case "$link" in
      ''|\#*|http://*|https://*|mailto:*) continue ;;
    esac
    target=${link%%#*}
    [ -n "$target" ] || continue
    [ -e "$(dirname "$file")/$target" ] || fail "broken internal Markdown link: $file -> $link"
  done < <(grep -oE '\]\([^)]*\)' "$file" || true)
done < <(find "$repo" -path "$repo/.git" -prune -o -type f -name '*.md' -print)

# Intentional platform/recovery constants remain allowed and documented.
rg -q -F '172.16.255.254' "$repo/root/usr/sbin/sbair-netmode" || fail 'platform alias constant disappeared'
rg -q -F '192.168.3.1' "$repo/root/usr/libexec/sbair/netmode/apply.sh" || fail 'factory/recovery address disappeared'

echo '[OK] publication hygiene current-tree checks passed'
