#!/bin/sh
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Floop3
set -eu

repo=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT INT TERM
input=$tmp/input
output=$tmp/output
expected=$tmp/expected

printf '%s\n' \
	'# comment' \
	'0.0.0.0 Z.example.com' \
	'0.0.0.0 z.example.com' \
	'127.0.0.1 localhost localhost.localdomain' \
	'0.0.0.0 bad host name # ignored' \
	'0.0.0.0 valid-name.example' \
	'0.0.0.0 192.0.2.1' > "$input"
printf '%s\n' valid-name.example z.example.com > "$expected"

out=$(SBAIR_ADBLOCK_SOURCE_FILE="$input" SBAIR_ADBLOCK_SOURCE_REVISION=test-fixture \
	SBAIR_ADBLOCK_OUTPUT="$output" sh "$repo/tools/update-adblock-domains.sh")
printf '%s\n' "$out" | grep -q '^source_revision=test-fixture$'
printf '%s\n' "$out" | grep -q '^entry_count=2$'
cmp -s "$expected" "$output"
first_hash=$(shasum -a 256 "$output" | awk '{print $1}')

SBAIR_ADBLOCK_SOURCE_FILE="$input" SBAIR_ADBLOCK_SOURCE_REVISION=test-fixture \
	SBAIR_ADBLOCK_OUTPUT="$output" sh "$repo/tools/update-adblock-domains.sh" >/dev/null
second_hash=$(shasum -a 256 "$output" | awk '{print $1}')
[ "$first_hash" = "$second_hash" ]
echo 'adblock-generator-fixture-ok'
