#!/bin/sh
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Floop3
#
# Exercise sbair-maintenance with small command mocks. The client/server
# regression assertions below intentionally capture network.lan.* and
# management_proto before every server action.
set -eu

repo=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT INT TERM

fakebin="$tmp/bin"
state="$tmp/uci.state"
log="$tmp/commands.log"
proc="$tmp/fota.process"
rcdir="$tmp/rc.d"
backup="$tmp/backups"
mkdir -p "$fakebin" "$rcdir" "$backup"
: > "$log"
printf 'stopped\n' > "$proc"

cat > "$state" <<'EOF'
dhcp.lan.ignore=0
dhcp.lan.ra=server
dhcp.lan.dhcpv6=server
dhcp.lan.ndp=hybrid
network.lan.proto=dhcp
network.lan.ipaddr=198.51.100.11
network.lan.netmask=255.255.255.0
network.lan.gateway=198.51.100.1
network.lan.dns=198.51.100.1
management_proto=dhcp
sbair.bridge.managed=0
sbair.bridge.mode=unmanaged
sbair.bridge.pending_id=
fota.config.enabled=1
fota.config.respawn=1
fota.provision.enabled=1
EOF
printf 'config dhcp lan\n' > "$tmp/dhcp.config"
printf 'config fota config\n' > "$tmp/fota.config"

cat > "$fakebin/uci" <<'EOF'
#!/bin/sh
set -eu
state=${TEST_UCI_STATE:?}
log=${TEST_COMMAND_LOG:?}
printf 'uci %s\n' "$*" >> "$log"
case "${1:-}" in
  -q) shift;;
esac
case "${1:-}" in
  get)
    key=${2:-}
    awk -F= -v k="$key" '$1 == k { print substr($0, index($0, "=") + 1); found=1; exit } END { if (!found) exit 1 }' "$state"
    ;;
  set)
    assignment=${2:-}
    key=${assignment%%=*}
    value=${assignment#*=}
    tmpfile="$state.tmp"
    awk -F= -v k="$key" -v v="$value" '
      $1 == k { print k "=" v; found=1; next }
      { print }
      END { if (!found) print k "=" v }
    ' "$state" > "$tmpfile"
    mv "$tmpfile" "$state"
    ;;
  commit)
    :
    ;;
  *) exit 1;;
esac
EOF
chmod 755 "$fakebin/uci"

cat > "$fakebin/netstat" <<'EOF'
#!/bin/sh
state=${TEST_UCI_STATE:?}
ignore=$(awk -F= '$1 == "dhcp.lan.ignore" { print $2; exit }' "$state")
printf '%s\n' 'Proto Recv-Q Send-Q Local Address           Foreign Address         State       PID/Program name'
case "$*" in
  *u*)
    printf '%s\n' 'udp        0      0 0.0.0.0:53              0.0.0.0:*                           1/dnsmasq'
    [ "$ignore" = 1 ] || printf '%s\n' 'udp        0      0 0.0.0.0:67              0.0.0.0:*                           1/dnsmasq'
    ;;
  *t*)
    printf '%s\n' 'tcp        0      0 0.0.0.0:53              0.0.0.0:*               LISTEN      1/dnsmasq'
    ;;
esac
EOF
chmod 755 "$fakebin/netstat"

cat > "$fakebin/pidof" <<'EOF'
#!/bin/sh
case "${1:-}" in
  dnsmasq|odhcpd) printf '1\n'; exit 0;;
  kn_fotad)
    [ "$(cat "${TEST_FOTA_PROCESS:?}")" = running ] && { printf '2\n'; exit 0; }
    exit 1
    ;;
esac
exit 1
EOF
chmod 755 "$fakebin/pidof"

cat > "$fakebin/sleep" <<'EOF'
if [ "${TEST_FORCE_RESPAWN:-0}" = 1 ]; then
  printf 'running\n' > "${TEST_FOTA_PROCESS:?}"
fi
exit 0
EOF
chmod 755 "$fakebin/sleep"

cat > "$tmp/dnsmasq.init" <<'EOF'
#!/bin/sh
printf 'dnsmasq %s\n' "$1" >> "${TEST_COMMAND_LOG:?}"
[ "${1:-}" = restart ]
EOF
chmod 755 "$tmp/dnsmasq.init"

cat > "$tmp/fota.init" <<EOF
#!/bin/sh
printf 'kn_fotad %s\n' "\$1" >> "${log}"
case "\${1:-}" in
  stop) printf 'stopped\n' > "${proc}";;
  disable) rm -f "${rcdir}/S50kn_fotad";;
  enable) ln -sf /etc/init.d/kn_fotad "${rcdir}/S50kn_fotad";;
  start) printf 'running\n' > "${proc}";;
  *) exit 1;;
esac
EOF
chmod 755 "$tmp/fota.init"

cat > "$tmp/netmode" <<'EOF'
#!/bin/sh
state=${TEST_UCI_STATE:?}
get() { awk -F= -v k="$1" '$1 == k { print substr($0, index($0, "=") + 1); exit }' "$state"; }
printf 'dhcp.guard_active=0\nmanaged=%s\nmode=%s\n' "$(get sbair.bridge.managed)" "$(get sbair.bridge.mode)"
EOF
chmod 755 "$tmp/netmode"

helper_env="SBAIR_MAINTENANCE_PATH=$fakebin:/usr/bin:/bin:/usr/sbin:/sbin TEST_UCI_STATE=$state TEST_COMMAND_LOG=$log TEST_FOTA_PROCESS=$proc SBAIR_MAINTENANCE_BACKUP_DIR=$backup SBAIR_MAINTENANCE_DHCP_CONFIG=$tmp/dhcp.config SBAIR_MAINTENANCE_FOTA_CONFIG=$tmp/fota.config SBAIR_MAINTENANCE_FOTA_INIT=$tmp/fota.init SBAIR_MAINTENANCE_DNSMASQ_INIT=$tmp/dnsmasq.init SBAIR_MAINTENANCE_NETMODE=$tmp/netmode SBAIR_MAINTENANCE_RC_DIR=$rcdir SBAIR_MAINTENANCE_WAIT_SECONDS=0"
run_helper() { env $helper_env "$repo/root/usr/sbin/sbair-maintenance" "$@"; }
get_state() { awk -F= -v k="$1" '$1 == k { print substr($0, index($0, "=") + 1); exit }' "$state"; }
capture_client() {
  for key in network.lan.proto network.lan.ipaddr network.lan.netmask network.lan.gateway network.lan.dns management_proto; do
    printf '%s=%s\n' "$key" "$(get_state "$key")"
  done > "$tmp/client.before"
}
assert_client_unchanged() {
  for key in network.lan.proto network.lan.ipaddr network.lan.netmask network.lan.gateway network.lan.dns management_proto; do
    printf '%s=%s\n' "$key" "$(get_state "$key")"
  done > "$tmp/client.after"
  cmp -s "$tmp/client.before" "$tmp/client.after"
}

# 1: status is read-only and reports the server/listener split.
cp "$state" "$tmp/status.before"
run_helper status > "$tmp/status.out"
cmp -s "$tmp/status.before" "$state"
grep -q '^dhcp_server.udp67_listening=1$' "$tmp/status.out"
grep -q '^dhcp_server.port53_listening=1$' "$tmp/status.out"
grep -q '^dhcp_server.dnsmasq=running$' "$tmp/status.out"

# 2-10, 13-14, 6: server actions change only dhcp.lan.ignore.
capture_client
: > "$log"
run_helper dhcp-server disable > "$tmp/dhcp-disable.out"
grep -q '^result=disabled$' "$tmp/dhcp-disable.out"
[ "$(get_state dhcp.lan.ignore)" = 1 ]
assert_client_unchanged
grep -q '^dnsmasq restart$' "$log"
! grep -Eq 'network restart|ifup lan|ifdown lan' "$log"
run_helper status > "$tmp/status-disabled.out"
grep -q '^dhcp_server.udp67_listening=0$' "$tmp/status-disabled.out"
grep -q '^dhcp_server.dnsmasq=running$' "$tmp/status-disabled.out"
grep -q '^dhcp_server.port53_listening=1$' "$tmp/status-disabled.out"

: > "$log"
run_helper dhcp-server disable | grep -q '^result=already_disabled$'
! grep -q 'dnsmasq restart' "$log"

: > "$log"
run_helper dhcp-server enable > "$tmp/dhcp-enable.out"
grep -q '^result=enabled$' "$tmp/dhcp-enable.out"
[ "$(get_state dhcp.lan.ignore)" = 0 ]
assert_client_unchanged
grep -q '^dnsmasq restart$' "$log"
grep -q '^verification.udp67_listening=1$' "$tmp/dhcp-enable.out"

: > "$log"
run_helper dhcp-server enable | grep -q '^result=already_enabled$'
! grep -q 'dnsmasq restart' "$log"

# 11: managed AP owns the DHCP state and rejects enable.
env $helper_env "$fakebin/uci" -q set sbair.bridge.managed=1
env $helper_env "$fakebin/uci" -q set sbair.bridge.mode=ap
capture_client
if run_helper dhcp-server enable > "$tmp/ap-reject.out"; then exit 1; fi
grep -q 'AP / Bridge.*有効化できません' "$tmp/ap-reject.out"
assert_client_unchanged
env $helper_env "$fakebin/uci" -q set sbair.bridge.managed=0
env $helper_env "$fakebin/uci" -q set sbair.bridge.mode=unmanaged

# 12: pending Safe Apply rejects maintenance writes.
env $helper_env "$fakebin/uci" -q set sbair.bridge.pending_id=transaction-1
before_pending=$(cat "$state")
if run_helper fota disable > "$tmp/pending-reject.out"; then exit 1; fi
grep -q 'Safe Apply.*保留中' "$tmp/pending-reject.out"
[ "$(cat "$state")" = "$before_pending" ]
env $helper_env "$fakebin/uci" -q set sbair.bridge.pending_id=

# 15-18, 20-21: FOTA disable/enable and idempotence.
ln -sf /etc/init.d/kn_fotad "$rcdir/S50kn_fotad"
printf 'running\n' > "$proc"
: > "$log"
run_helper fota disable > "$tmp/fota-disable.out"
grep -q '^result=disabled$' "$tmp/fota-disable.out"
[ "$(get_state fota.config.enabled)" = 0 ]
[ "$(get_state fota.provision.enabled)" = 0 ]
[ "$(get_state fota.config.respawn)" = 1 ]
[ "$(cat "$proc")" = stopped ]
[ ! -e "$rcdir/S50kn_fotad" ]
grep -q '^kn_fotad stop$' "$log"
grep -q '^kn_fotad disable$' "$log"

: > "$log"
run_helper fota disable | grep -q '^result=already_disabled$'
! grep -q '^kn_fotad ' "$log"

# 19: a respawn after the wait becomes an explicit warning.
env $helper_env "$fakebin/uci" -q set fota.config.enabled=1
env $helper_env "$fakebin/uci" -q set fota.provision.enabled=1
printf 'running\n' > "$proc"
ln -sf /etc/init.d/kn_fotad "$rcdir/S50kn_fotad"
TEST_FORCE_RESPAWN=1 env $helper_env "$repo/root/usr/sbin/sbair-maintenance" fota disable > "$tmp/fota-respawn.out"
grep -q '^warning=.*再起動しました' "$tmp/fota-respawn.out"

env $helper_env "$fakebin/uci" -q set fota.config.enabled=0
env $helper_env "$fakebin/uci" -q set fota.provision.enabled=0
printf 'stopped\n' > "$proc"
rm -f "$rcdir/S50kn_fotad"
run_helper fota enable > "$tmp/fota-enable.out"
grep -q '^result=enabled$' "$tmp/fota-enable.out"
[ "$(get_state fota.config.enabled)" = 1 ]
[ "$(get_state fota.provision.enabled)" = 1 ]
[ "$(get_state fota.config.respawn)" = 1 ]
[ "$(cat "$proc")" = running ]
[ -e "$rcdir/S50kn_fotad" ] || [ -L "$rcdir/S50kn_fotad" ]

: > "$log"
run_helper fota enable | grep -q '^result=already_enabled$'
! grep -q '^kn_fotad ' "$log"

# 22: malformed helper output is returned as a structured rpcd error.
cat > "$fakebin/sbair-maintenance" <<'EOF'
#!/bin/sh
printf 'malformed-output\n'
EOF
chmod 755 "$fakebin/sbair-maintenance"
(cd "$repo/src/sbair-modem" && GOCACHE="$tmp/go-cache" go build -o "$tmp/sbair-modem" .)
printf '{}' | PATH="$fakebin:/usr/bin:/bin" "$tmp/sbair-modem" rpcd call maintenance_status > "$tmp/rpc-error.json"
grep -q '"error"' "$tmp/rpc-error.json"
grep -q 'malformed output' "$tmp/rpc-error.json"

# UI smoke check: the two focused pages keep the existing RPC ownership and
# use unambiguous DHCP server / FOTA labels.
node - \
  "$repo/htdocs/luci-static/resources/view/sbair/lan_services.js" \
  "$repo/htdocs/luci-static/resources/view/sbair/update.js" <<'NODE'
const assert = require('assert');
const fs = require('fs');
const vm = require('vm');
const lanSource = fs.readFileSync(process.argv[2], 'utf8');
const updateSource = fs.readFileSync(process.argv[3], 'utf8');
function E(tag, attrs, children) {
  return { tag, attrs: attrs || {}, children: Array.isArray(children) ? children : (children === undefined ? [] : [ children ]) };
}
function flatten(node, out) {
  out = out || [];
  if (Array.isArray(node)) return node.reduce((all, child) => flatten(child, all), out);
  if (!node || typeof node !== 'object') return out;
  out.push(node);
  return flatten(node.children || [], out);
}
function textOf(node) {
  if (Array.isArray(node)) return node.map(textOf).join('');
  if (!node || typeof node !== 'object') return String(node || '');
  return textOf(node.children || []);
}
const context = {
  Promise,
  Node: function Node() {},
  E,
  rpc: { declare: function() { return function() { return Promise.resolve({}); }; } },
  view: { extend: function(value) { return value; } },
  ui: { createHandlerFn: function(_self, fn) { return fn; }, addNotification: function() {} },
  dom: { content: function(node, children) { node.children = Array.isArray(children) ? children : [ children ]; } },
  sbair: {
    section: function(title, children) { return E('section', { title }, [ E('h3', {}, title) ].concat(children)); },
    table: function(rows) { return E('table', {}, rows); },
    row: function(label, value) { return E('row', { label }, [ value ]); },
    errorBox: function(errors) { return errors && errors.length ? E('error', {}, errors) : ''; }
  },
  confirm: function() { return true; }
};
function loadView(source) {
  return vm.runInNewContext('(function() {\n' + source + '\n})()', context);
}
const lanView = loadView(lanSource);
const updateView = loadView(updateSource);
const lanRendered = lanView.render({
  dhcp_server: { enabled: true, uci_ignore: '0', udp67_listening: true, udp67_scope: '0.0.0.0:67', dnsmasq: 'running', port53_listening: true, port53_tcp_scope: '0.0.0.0:53', port53_udp_scope: '0.0.0.0:53', odhcpd: 'stopped', ra: 'server', dhcpv6: 'server', ndp: 'hybrid', owner: 'manual', guard_active: false, pending: false },
});
const updateRendered = updateView.render({
  fota: { config_enabled: '1', provision_enabled: '1', config_respawn: '1', kn_fotad: 'running', autostart: 'enabled' }
});
assert.match(textOf(lanRendered), /LAN DHCPサーバー/);
assert.match(textOf(lanRendered), /DHCPクライアント設定/);
assert.match(textOf(lanRendered), /DHCPサーバーを無効化/);
assert.match(textOf(lanRendered), /DHCPサーバーを有効化/);
assert.match(textOf(updateRendered), /OTA \/ FOTA 自動更新/);
assert.match(textOf(updateRendered), /OTA\/FOTA自動更新を無効化/);
assert.match(lanSource, /maintenance_status/);
assert.match(lanSource, /dhcp_server_set/);
assert.match(updateSource, /maintenance_status/);
assert.match(updateSource, /fota_set/);
assert.doesNotMatch(lanSource, /fota_set/);
assert.doesNotMatch(updateSource, /dhcp_server_set/);
console.log('maintenance-js-fixture-ok');
NODE

echo maintenance-fixture-ok
