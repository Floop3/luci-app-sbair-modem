#!/bin/sh
# SPDX-License-Identifier: MIT
# Small Issue #1 regression check for menu hierarchy, client/adblock merging,
# and the shared spacing rule. This intentionally uses only Node's built-ins.
set -eu

repo=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
node - \
	"$repo/root/usr/share/luci/menu.d/luci-app-sbair-modem.json" \
	"$repo/htdocs/luci-static/resources/view/sbair/clients.js" \
	"$repo/htdocs/luci-static/resources/tools/sbair.js" \
	"$repo/htdocs/luci-static/resources/view/sbair/sim.js" <<'NODE'
const assert = require('assert');
const fs = require('fs');
const vm = require('vm');

const menu = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
const clientsSource = fs.readFileSync(process.argv[3], 'utf8');
const toolsSource = fs.readFileSync(process.argv[4], 'utf8');
const simSource = fs.readFileSync(process.argv[5], 'utf8');

const top = Object.keys(menu)
  .filter(path => path.indexOf('admin/sbair/') === 0 && path.split('/').length === 3)
  .sort((a, b) => menu[a].order - menu[b].order);
assert.deepStrictEqual(top, [
	'admin/sbair/mobile',
	'admin/sbair/wifi',
	'admin/sbair/clients',
	'admin/sbair/network',
	'admin/sbair/device'
]);

function entry(path, title, action) {
  assert.ok(menu[path], `missing menu entry: ${path}`);
  assert.strictEqual(menu[path].title, title);
  assert.strictEqual(menu[path].action.type, action);
}

entry('admin/sbair/mobile', 'モバイル回線', 'firstchild');
entry('admin/sbair/mobile/status', '状態', 'view');
entry('admin/sbair/mobile/sim', 'SIM / eSIM', 'view');
entry('admin/sbair/mobile/sms', 'SMS', 'view');
entry('admin/sbair/wifi', 'Wi-Fi', 'firstchild');
entry('admin/sbair/wifi/basic', '基本設定', 'view');
entry('admin/sbair/wifi/advanced', '詳細設定', 'view');
entry('admin/sbair/wifi/diagnostics', '診断', 'view');
entry('admin/sbair/network', 'ネットワーク', 'firstchild');
entry('admin/sbair/network/netmode', '接続モード', 'view');
entry('admin/sbair/network/lan-services', 'LANサービス', 'view');
entry('admin/sbair/network/diagnostics', '診断', 'view');
entry('admin/sbair/device', '本体', 'firstchild');
entry('admin/sbair/device/info', '本体情報', 'view');
entry('admin/sbair/device/usb', 'USB機器', 'view');
entry('admin/sbair/device/update', 'アップデート管理', 'view');
assert.strictEqual(menu['admin/sbair/adblock'], undefined);
assert.strictEqual(menu['admin/sbair/signal'], undefined);
assert.strictEqual(menu['admin/sbair/sim_sms'], undefined);
assert.strictEqual(menu['admin/sbair/netmode'], undefined);
assert.strictEqual(menu['admin/sbair/device/maintenance'], undefined);

assert.match(clientsSource, /callClientList/);
assert.match(clientsSource, /callAdblockList/);
assert.match(clientsSource, /callAdblockSet/);
assert.match(clientsSource, /adblockControl/);
assert.match(clientsSource, /広告ブロック/);
assert.match(clientsSource, /:8090\//);
assert.match(clientsSource, /key: 'device'/);
assert.doesNotMatch(clientsSource, /key: 'vendor'/);
assert.match(toolsSource, /\.sbair-section\{margin-bottom:28px\}/);
assert.match(toolsSource, /\.sbair-section > h3\{margin-bottom:12px\}/);
assert.doesNotMatch(toolsSource, /\.sbair-section\{margin-bottom:18px\}/);
assert.ok(simSource.indexOf("body.push(this.simLockSection());") < simSource.indexOf("body.push(sbair.section('通信設定'"));
assert.match(simSource, /SIMロック操作を表示（危険）/);
assert.match(simSource, /font-size:115%/);
assert.doesNotMatch(simSource, /details\('SIMロック',/);

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

const rpcCalls = [];
const rpc = {
  declare: function(options) {
    return function() {
      rpcCalls.push(options.method);
      if (options.method === 'client_list')
        return Promise.resolve({ clients: [{ name: 'Phone', mac: 'AA:BB:CC:DD:EE:FF', ip: '192.168.1.2', link: '5G' }] });
      if (options.method === 'adblock_list')
        return Promise.resolve({ clients: [{ mac: 'aa:bb:cc:dd:ee:ff', adblock: true }] });
      if (options.method === 'adblock_set') return Promise.resolve({ result: 'ok' });
      return Promise.resolve({});
    };
  }
};
const context = {
  Promise,
  Node: function Node() {},
  E,
  rpc,
  window: { location: { hostname: '192.168.1.1' } },
  view: { extend: value => value },
  ui: { createHandlerFn: (_self, fn) => fn, addNotification: function() {}, showModal: function() {}, hideModal: function() {} },
  dom: { content: function(node, children) { node.children = Array.isArray(children) ? children : [ children ]; } },
  sbair: {
    section: (title, children) => E('section', { title }, children),
    table: rows => E('table', {}, rows),
    errorBox: errors => errors && errors.length ? E('error', {}, errors) : ''
  },
  confirm: () => true
};
const view = vm.runInNewContext('(function() {\n' + clientsSource + '\n})()', context);

view.load().then(function(data) {
  assert.strictEqual(data.adblock_available, true);
  assert.strictEqual(data.clients[0].adblock, true);
  const rendered = view.render(data);
  assert.match(textOf(rendered), /広告ブロック/);
  assert.match(textOf(rendered), /有効（無効化）/);
  assert.match(textOf(rendered), /操作/);
  const headers = flatten(rendered).filter(node => node.tag === 'th').map(node => textOf(node).replace(/ [▲▼]$/, ''));
  assert.deepStrictEqual(headers, [ '端末', 'IPアドレス', '接続', 'メモ', '広告ブロック', '操作' ]);
  assert.ok(flatten(rendered).some(node => node.tag === 'a' && node.attrs.href === 'http://192.168.1.1:8090/'));
  assert.ok(rpcCalls.includes('client_list'));
  assert.ok(rpcCalls.includes('adblock_list'));
  process.stdout.write('ui-structure-fixture-ok\n');
}).catch(function(err) {
  console.error(err);
  process.exit(1);
});
NODE
