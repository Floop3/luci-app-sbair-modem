#!/bin/sh
# Static checks for the optional host/target LuCI bootstrap.
set -eu

repo=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
bootstrap="$repo/extras/luci-bootstrap"

sh -n "$bootstrap/install.sh"
sh -n "$bootstrap/target.sh"
sh -n "$bootstrap/check.sh"

awk -F '\t' '
	$1 ~ /^#/ || NF <= 1 { next }
	NF != 5 || $2 !~ /^[^\/]+\.ipk$/ || $3 !~ /^https:\/\/downloads\.openwrt\.org\// ||
	$4 !~ /^[0-9a-fA-F]{64}$/ || $5 == "" { bad=1 }
	{ rows++ }
	END { exit(rows != 34 || bad) }
' "$bootstrap/packages.lock"

[ "$(awk -F '\t' '$5 == "special-libnl" { n++ } END { print n + 0 }' "$bootstrap/packages.lock")" = 1 ]
grep -q 'libnl-tiny.so.1' "$bootstrap/target.sh"
grep -q 'opkg -f.*--noaction' "$bootstrap/target.sh"
grep -q 'firewall.sba6_user_include' "$bootstrap/target.sh"
grep -q 'DISTRIB_TARGET' "$bootstrap/target.sh"
grep -q '8080' "$bootstrap/check.sh"

# The application installer must remain an application-only installer.
! grep -q 'extras/luci-bootstrap' "$repo/install.sh"
! grep -q 'luci-base' "$repo/install.sh"

printf '%s\n' luci-bootstrap-fixture-ok
