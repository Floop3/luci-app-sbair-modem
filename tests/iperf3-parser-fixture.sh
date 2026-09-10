#!/bin/bash
# SPDX-License-Identifier: MIT
# Host-side fixtures for the dependency-free Air6 iperf3 parsers.
set -euo pipefail

repo=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT INT TERM
# shellcheck source=/dev/null
. "$repo/extras/iperf3/parsers.sh"

printf '%s\n' \
  '[SUM]  0.00-10.00  sec  554 MBytes  465 Mbits/sec  3  sender' \
  '[SUM]  0.00-10.00  sec  520 MBytes  436 Mbits/sec     receiver' > "$tmp/tcp.out"
tcp=$(parse_tcp_summary "$tmp/tcp.out")
printf '%s\n' "$tcp" | grep -qx 'sender_mbits=465'
printf '%s\n' "$tcp" | grep -qx 'receiver_mbits=436'
printf '%s\n' "$tcp" | grep -qx 'retrans=3'

printf '%s\n' \
  '[SUM]  0.00-2.00  sec  95.4 MBytes  400 Mbits/sec  0.000 ms  0/10000 (0%)  sender' \
  '[SUM]  0.00-2.00  sec  94.2 MBytes  395 Mbits/sec  0.000 ms  5/10000 (0.5%)  receiver' > "$tmp/udp.out"
udp=$(parse_udp_summary "$tmp/udp.out")
printf '%s\n' "$udp" | grep -qx 'sender_mbits=400'
printf '%s\n' "$udp" | grep -qx 'receiver_mbits=395'
printf '%s\n' "$udp" | grep -qx 'receiver_lost=5'
printf '%s\n' "$udp" | grep -qx 'receiver_total=10000'
printf '%s\n' "$udp" | grep -qx 'receiver_loss_pct=0.5'
printf '%s\n' "$udp" | grep -qx 'receiver_jitter_ms=0.000'

printf '%s\n' \
  '00000010 00000002 00000003 00000000 00000000 00000000 00000000 00000000 00000000 00000000 00000000' \
  '00000020 00000004 00000005 00000000 00000000 00000000 00000000 00000000 00000000 00000000 00000000' > "$tmp/softnet.before"
printf '%s\n' \
  '0000001a 00000005 00000008 00000000 00000000 00000000 00000000 00000000 00000000 00000000 00000000' \
  '0000002a 00000009 00000009 00000000 00000000 00000000 00000000 00000000 00000000 00000000 00000000' > "$tmp/softnet.after"
softnet=$(parse_softnet_delta "$tmp/softnet.before" "$tmp/softnet.after")
printf '%s\n' "$softnet" | grep -qx 'softnet_cpu0_processed_delta=10'
printf '%s\n' "$softnet" | grep -qx 'softnet_cpu0_dropped_delta=3'
printf '%s\n' "$softnet" | grep -qx 'softnet_cpu0_time_squeeze_delta=5'
printf '%s\n' "$softnet" | grep -qx 'softnet_cpu1_dropped_delta=5'

printf '%s\n' \
  'cpu0 100 0 50 800 0 10 20 0 0 0' \
  'cpu1 100 0 50 800 0 10 20 0 0 0' > "$tmp/stat.before"
printf '%s\n' \
  'cpu0 150 0 60 810 0 20 40 0 0 0' \
  'cpu1 105 0 52 840 0 11 21 0 0 0' > "$tmp/stat.after"
stat=$(parse_proc_stat_delta "$tmp/stat.before" "$tmp/stat.after")
printf '%s\n' "$stat" | grep -q '^cpu0 busy_pct='
printf '%s\n' "$stat" | grep -q '^cpu1 busy_pct='
printf '%s\n' "$stat" | grep -q '^hottest_cpu=cpu0$'

printf '%s\n' \
  '                    CPU0       CPU1' \
  'NET_RX:               10         20' \
  'NET_TX:                3          4' > "$tmp/softirqs.before"
printf '%s\n' \
  '                    CPU0       CPU1' \
  'NET_RX:               20         30' \
  'NET_TX:                5          9' > "$tmp/softirqs.after"
softirq=$(parse_softirq_delta "$tmp/softirqs.before" "$tmp/softirqs.after")
printf '%s\n' "$softirq" | grep -qx 'NET_RX_total_delta=20'
printf '%s\n' "$softirq" | grep -qx 'NET_TX_total_delta=7'

printf '%s\n' \
  '           CPU0       CPU1' \
  '  42:         10         20  wifi-rx' > "$tmp/interrupts.before"
printf '%s\n' \
  '           CPU0       CPU1' \
  '  42:         15         24  wifi-rx' > "$tmp/interrupts.after"
irq=$(parse_irq_deltas "$tmp/interrupts.before" "$tmp/interrupts.after")
printf '%s\n' "$irq" | grep -qx 'irq=42 delta=9 label=wifi-rx percpu_delta=5,4'

bash -n "$repo/extras/iperf3/air6-install-iperf3.sh"
bash -n "$repo/extras/iperf3/parsers.sh"
grep -q 'diagnose' "$repo/extras/iperf3/air6-install-iperf3.sh"
grep -q 'experiment' "$repo/extras/iperf3/air6-install-iperf3.sh"
grep -q 'rollback' "$repo/extras/iperf3/air6-install-iperf3.sh"

echo iperf3-parser-fixture-ok
