#!/bin/bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Floop3
# Small dependency-free parsers used by the Air6 iperf3 diagnostics.

# Parse the final sender/receiver summaries from a fixed "-f m" TCP run.
# The receiver line is the delivered-throughput value used by the reports.
parse_tcp_summary() {
	local file=${1:?output file is required}
	awk '
	function rate(    i) {
		for (i = 1; i <= NF; i++)
			if ($i == "Mbits/sec" && i > 1) return $(i - 1)
		return ""
	}
	function retrans(    i) {
		for (i = 1; i <= NF; i++)
			if ($i == "Mbits/sec" && i < NF && $(i + 1) ~ /^[0-9]+$/) return $(i + 1)
		return "unknown"
	}
	/ sender[[:space:]]*$/ { s = rate(); r = retrans() }
	/ receiver[[:space:]]*$/ { v = rate() }
	END {
		if (s == "" || v == "") exit 1
		printf "sender_mbits=%s\nreceiver_mbits=%s\nretrans=%s\n", s, v, r
	}
	' "$file"
}

# Parse both UDP summaries. Receiver-side loss is authoritative. iperf3 3.10
# has emitted slightly different sender lines over time, so sender loss fields
# are intentionally optional and are never used for the loss conclusion.
parse_udp_summary() {
	local file=${1:?output file is required}
	awk '
	function value_before(needle,    i) {
		for (i = 1; i <= NF; i++)
			if ($i == needle && i > 1) return $(i - 1)
		return ""
	}
	function pair(    i) {
		for (i = 1; i <= NF; i++)
			if ($i ~ /^[0-9]+\/[0-9]+$/) return $i
		return ""
	}
	function loss_pct(    i) {
		for (i = 1; i <= NF; i++)
			if ($i ~ /^\([0-9]+([.][0-9]+)?%\)$/) { gsub(/[()%]/, "", $i); return $i }
		return ""
	}
	function jitter(    i) {
		for (i = 1; i <= NF; i++)
			if ($i == "ms" && i > 1) return $(i - 1)
		return ""
	}
	/ sender[[:space:]]*$/ {
		srate = value_before("Mbits/sec"); spair = pair(); sloss = loss_pct(); sjit = jitter()
	}
	/ receiver[[:space:]]*$/ {
		rrate = value_before("Mbits/sec"); rpair = pair(); rloss = loss_pct(); rjit = jitter()
	}
	END {
		if (srate == "" || rrate == "") exit 1
		printf "sender_mbits=%s\nreceiver_mbits=%s\n", srate, rrate
		if (spair != "") { split(spair, a, "/"); printf "sender_lost=%s\nsender_total=%s\n", a[1], a[2] }
		if (sloss != "") printf "sender_loss_pct=%s\n", sloss
		if (sjit != "") printf "sender_jitter_ms=%s\n", sjit
		if (rpair == "") exit 2
		split(rpair, b, "/")
		printf "receiver_lost=%s\nreceiver_total=%s\nreceiver_loss_pct=%s\n", b[1], b[2], rloss
		if (rjit != "") printf "receiver_jitter_ms=%s\n", rjit
	}
	' "$file"
}

# BSD awk and BusyBox awk do not consistently provide strtonum(). Keep the
# hexadecimal conversion in the shell, where bash printf handles 0xNN safely.
hex_to_dec() {
	local value=${1:-}
	case "$value" in
		''|*[!0-9a-fA-F]*) return 1 ;;
		*) printf '%d' "0x$value" ;;
	esac
}

# Report CPU deltas from two /proc/stat captures. The values are intentionally
# plain key/value records so the caller can preserve them in a report without
# requiring jq, Python, or another target package.
parse_proc_stat_delta() {
	local before=${1:?before /proc/stat is required} after=${2:?after /proc/stat is required}
	awk '
	FNR == NR && $1 ~ /^cpu[0-9]+$/ {
		btotal[$1] = 0
		for (i = 2; i <= NF; i++) btotal[$1] += $i
		bidle[$1] = $5 + $6
		birq[$1] = $7
		bsoft[$1] = $8
		next
	}
	$1 ~ /^cpu[0-9]+$/ {
		if (!($1 in btotal)) next
		total = 0; for (i = 2; i <= NF; i++) total += $i
		idle = $5 + $6
		dt = total - btotal[$1]; if (dt <= 0) next
		busy = dt - (idle - bidle[$1])
		irq = ($7 - birq[$1]); soft = ($8 - bsoft[$1])
		busy_pct = 100 * busy / dt; idle_pct = 100 - busy_pct
		irq_pct = 100 * irq / dt; soft_pct = 100 * soft / dt
		printf "%s busy_pct=%.1f idle_pct=%.1f irq_pct=%.1f softirq_pct=%.1f\n", $1, busy_pct, idle_pct, irq_pct, soft_pct
		if (busy_pct > hot) { hot = busy_pct; hotcpu = $1 }
	}
	END { if (hotcpu != "") printf "hottest_cpu=%s\n", hotcpu }
	' "$before" "$after"
}

# NET_RX/NET_TX are counters with one value per CPU in /proc/softirqs.
parse_softirq_delta() {
	local before=${1:?before /proc/softirqs is required} after=${2:?after /proc/softirqs is required}
	awk '
	function load(kind,    i) {
		for (i = 2; i <= NF; i++) base[kind, i - 2] = $i
		count[kind] = NF - 1
	}
	FNR == NR && ($1 == "NET_RX:" || $1 == "NET_TX:") { load($1); next }
	($1 == "NET_RX:" || $1 == "NET_TX:") {
		kind = $1; name = substr(kind, 1, length(kind) - 1); total = 0
		for (i = 2; i <= NF; i++) { d = $i - base[kind, i - 2]; printf "%s_cpu%d_delta=%d\n", name, i - 2, d; total += d }
		printf "%s_total_delta=%d\n", name, total
	}
	' "$before" "$after"
}

# /proc/net/softnet_stat fields 1..3 are hexadecimal processed/dropped/
# time_squeeze counters. Conversion is deliberately done in bash below.
parse_softnet_delta() {
	local before=${1:?before /proc/net/softnet_stat is required} after=${2:?after /proc/net/softnet_stat is required}
	local line cpu bp bd bs ap ad as pd dd sd
	cpu=0
	while IFS=' ' read -r bp bd bs ap ad as; do
		[ -n "$bp" ] || continue
		pd=$(hex_to_dec "$bp") || return 1
		dd=$(hex_to_dec "$bd") || return 1
		sd=$(hex_to_dec "$bs") || return 1
		ap=$(hex_to_dec "$ap") || return 1
		ad=$(hex_to_dec "$ad") || return 1
		as=$(hex_to_dec "$as") || return 1
		pd=$((ap - pd))
		dd=$((ad - dd))
		sd=$((as - sd))
		printf 'softnet_cpu%d_processed_delta=%d\nsoftnet_cpu%d_dropped_delta=%d\nsoftnet_cpu%d_time_squeeze_delta=%d\n' "$cpu" "$pd" "$cpu" "$dd" "$cpu" "$sd"
		cpu=$((cpu + 1))
	done < <(paste "$before" "$after" | awk '{ n = int(NF / 2); print $1, $2, $3, $(n + 1), $(n + 2), $(n + 3) }')
}

# Emit IRQ deltas with the original label and per-CPU deltas. Selection is
# intentionally left to the caller, which can correlate labels with the
# dynamically discovered Wi-Fi netdev and exclude timers/IPIs.
parse_irq_deltas() {
	local before=${1:?before /proc/interrupts is required} after=${2:?after /proc/interrupts is required}
	awk '
	FNR == NR {
		if ($1 !~ /^[0-9]+:$/) next
		irq = substr($1, 1, length($1) - 1); total = 0; i = 2; cpu = 0
		while (i <= NF && $i ~ /^[0-9]+$/) {
			bcount[irq, cpu] = $i
			total += $i
			cpu++
			i++
		}
		if (i > NF) next
		label = $i
		for (i++; i <= NF; i++) label = label " " $i
		btotal[irq] = total
		bcpus[irq] = cpu
		blabel[irq] = label
		next
	}
	{
		if ($1 !~ /^[0-9]+:$/) next
		irq = substr($1, 1, length($1) - 1); total = 0; counts = ""; i = 2; cpu = 0
		while (i <= NF && $i ~ /^[0-9]+$/) {
			delta = $i - bcount[irq, cpu]
			total += delta
			counts = counts (counts == "" ? "" : ",") delta
			cpu++
			i++
		}
		if (i > NF || !(irq in btotal)) next
		label = $i; for (i++; i <= NF; i++) label = label " " $i
		delta = total; if (delta <= 0) next
		printf "irq=%s delta=%d label=%s percpu_delta=%s\n", irq, delta, label, counts
	}
	' "$before" "$after"
}
