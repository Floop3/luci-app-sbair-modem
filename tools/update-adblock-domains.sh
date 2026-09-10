#!/bin/sh
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Floop3
#
# Rebuild the embedded adblock domain list from Steven Black's single-source
# ad-hoc list. The normal path downloads only the pinned source revision.
set -eu

repo=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
revision='83dd698bbcdcb8c11a7796af7188d7ab4ccd02f1'
source_url="https://raw.githubusercontent.com/StevenBlack/hosts/$revision/data/StevenBlack/hosts"
output=${SBAIR_ADBLOCK_OUTPUT:-$repo/src/sbair-modem/data/adblock-domains.txt}
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT INT TERM

if [ -n "${SBAIR_ADBLOCK_SOURCE_FILE:-}" ]; then
	input=$tmp/source
	cp -- "$SBAIR_ADBLOCK_SOURCE_FILE" "$input"
	source_revision=${SBAIR_ADBLOCK_SOURCE_REVISION:-test-input}
else
	input=$tmp/source
	curl --fail --silent --show-error --location --retry 2 --connect-timeout 15 \
		"$source_url" -o "$input"
	source_revision=$revision
fi

parsed=$tmp/domains
LC_ALL=C awk '
function valid(host) {
	n = split(host, labels, ".")
	if (host == "localhost" || host == "localhost.localdomain" || host == "broadcasthost") return 0
	if (host !~ /\./) return 0
	if (host ~ /^[0-9]+(\.[0-9]+){3}$/) return 0
	if (host ~ /^[0-9]+(\.[0-9]+){3}\./) return 0
	if (host !~ /^[A-Za-z0-9](([A-Za-z0-9-]*[A-Za-z0-9])?\.)*[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?$/) return 0
	for (i = 1; i <= n; i++) if (length(labels[i]) > 63) return 0
	if (length(host) > 253) return 0
	return 1
}

/^[[:space:]]*#/ { next }
{
	if ($1 !~ /^(0\.0\.0\.0|127\.0\.0\.1|::1?|::ffff:0:0)$/) next
	for (i = 2; i <= NF; i++) {
		if ($i ~ /^#/) break
		host = tolower($i)
		if (valid(host)) print host
	}
}
' "$input" | LC_ALL=C sort -u > "$parsed"

mkdir -p "$(dirname "$output")"
target_tmp=$(mktemp "$(dirname "$output")/.adblock-domains.XXXXXX")
trap 'rm -rf "$tmp"; rm -f "$target_tmp"' EXIT INT TERM
cp "$parsed" "$target_tmp"
mv -f "$target_tmp" "$output"

count=$(wc -l < "$output" | tr -d ' ')
if command -v sha256sum >/dev/null 2>&1; then
	hash=$(sha256sum "$output" | awk '{print $1}')
else
	hash=$(shasum -a 256 "$output" | awk '{print $1}')
fi
printf 'source_revision=%s\nentry_count=%s\nsha256=%s\n' "$source_revision" "$count" "$hash"
