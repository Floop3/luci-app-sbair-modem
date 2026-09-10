#!/bin/sh
# SPDX-License-Identifier: MIT
# LuCI fixture: connection-mode UI remains usable without the moved network
# diagnostics and keeps the risky mode controls isolated.
set -eu

repo=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
node - "$repo/htdocs/luci-static/resources/view/sbair/netmode.js" <<'NODE'
const assert = require('assert');
const fs = require('fs');
const vm = require('vm');

const source = fs.readFileSync(process.argv[2], 'utf8');
const calls = [];
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
const rpc = {
  declare: function(options) {
    return function() {
      calls.push(options.method);
      if (options.method === 'netmode_status')
        return Promise.resolve({ mode: 'sim', managed: 0, health: 'unmanaged' });
      if (options.method === 'netmode_get_config')
        return Promise.resolve({ mode: 'sim', proto: 'dhcp' });
      return Promise.resolve({});
    };
  }
};

const context = {
  Promise,
  Node: function Node() {},
  E,
  rpc,
  view: { extend: function(value) { return value; } },
  ui: { createHandlerFn: function(_self, fn) { return fn; }, addNotification: function() {} },
  dom: { content: function(node, children) { node.children = Array.isArray(children) ? children : [ children ]; } },
  sbair: {
    section: function(title, children) { return E('section', { title }, children); },
    table: function(rows) { return E('table', {}, rows); },
    row: function(label, value, extra) { return E('row', { label }, [ value, extra || '' ]); },
    errorBox: function(errors) { return errors && errors.length ? E('error', {}, errors) : ''; },
    softBrickWarning: function() { return E('warning', {}, 'ソフトブリック UART firstboot'); }
  },
  setTimeout: function() { return 1; },
  clearTimeout: function() {}
};
const view = vm.runInNewContext('(function() {\n' + source + '\n})()', context);

view.load().then(function(data) {
  assert.strictEqual(data.status.mode, 'sim');
  assert.strictEqual(data.config.proto, 'dhcp');
  assert.deepStrictEqual(calls, [ 'netmode_status', 'netmode_get_config' ]);

  const unmanaged = view.render({
    status: { mode: 'sim', configured_mode: 'sim', managed: 0, health: 'unmanaged' },
    config: { mode: 'sim', configured_mode: 'sim', proto: 'dhcp' }
  });
  let inputs = flatten(unmanaged).filter(n => n.tag === 'input' && n.attrs.name === 'sbair-mode');
  assert.strictEqual(inputs.find(n => n.attrs.value === 'unmanaged').attrs.checked, '');
  assert.strictEqual(inputs.some(n => n.attrs.value === 'sim'), false);
  assert.strictEqual(inputs.some(n => n.attrs.value === 'ap'), true);
  assert.match(textOf(unmanaged), /既存設定.*未管理/);
  assert.doesNotMatch(textOf(unmanaged), /SIMルーター/);
  assert.ok(flatten(unmanaged).some(n => n.tag === 'details'));
  assert.match(textOf(unmanaged), /ソフトブリック/);
  assert.match(textOf(unmanaged), /UART/);
  assert.match(source, /softBrickWarning/);
  const initialDetails = flatten(unmanaged).find(n => n.tag === 'details');
  initialDetails.attrs.toggle({ target: { open: true } });
  inputs.find(n => n.attrs.value === 'ap').attrs.change();
  assert.strictEqual(flatten(unmanaged).find(n => n.tag === 'details').attrs.open, '');

  for (const [mode, expected] of [['ap', 'ap']]) {
    const rendered = view.render({ status: { mode, configured_mode: mode, managed: 1 }, config: { proto: 'dhcp' } });
    inputs = flatten(rendered).filter(n => n.tag === 'input' && n.attrs.name === 'sbair-mode');
    assert.strictEqual(inputs.find(n => n.attrs.value === expected).attrs.checked, '');
    assert.strictEqual(inputs.filter(n => n.attrs.checked === '').length, 1);
  }
  const managedLegacySim = view.render({
    status: { mode: 'sim', configured_mode: 'sim', managed: 1 },
    config: { proto: 'dhcp' }
  });
  const legacyInputs = flatten(managedLegacySim).filter(n => n.tag === 'input' && n.attrs.name === 'sbair-mode');
  assert.strictEqual(legacyInputs.find(n => n.attrs.value === 'unmanaged').attrs.checked, '');
  assert.strictEqual(legacyInputs.some(n => n.attrs.value === 'sim'), false);
  const apStatic = view.render({
    status: { mode: 'ap', configured_mode: 'ap', managed: 1 },
    config: { proto: 'dhcp', ap_dhcp_enabled: 0, fallback_ip: '192.168.3.1' }
  });
  const protoInputs = flatten(apStatic).filter(n => n.tag === 'input' && n.attrs.name === 'sbair-management-proto');
  assert.strictEqual(protoInputs.some(n => n.attrs.value === 'dhcp'), false);
  assert.strictEqual(protoInputs.find(n => n.attrs.value === 'static').attrs.checked, '');
  assert.match(textOf(apStatic), /DHCP.*安全フラグで無効化/);
  assert.match(textOf(apStatic), /非推奨設定を表示/);
  assert.match(textOf(apStatic), /ソフトブリック/);
  assert.match(textOf(apStatic), /DHCPクライアント設定は非常に高いリスク/);
  const inheritedStatic = view.render({
    status: { mode: 'ap', configured_mode: 'ap', managed: 1 },
    config: {
      proto: 'static', ap_dhcp_enabled: 0, ipaddr: '', netmask: '', gateway: '', dns: '',
      fallback_ip: '192.168.3.1', fallback_netmask: '255.255.255.0',
      oem_baseline_ready: 1,
      oem: { ipaddr: '198.51.100.11', netmask: '255.255.255.0', gateway: '198.51.100.1', dns: '198.51.100.1' },
      effective: { ipaddr: '198.51.100.11', netmask: '255.255.255.0' }
    }
  });
  const staticInputs = flatten(inheritedStatic).filter(n => n.tag === 'input' && n.attrs.type === 'text');
  assert.strictEqual(staticInputs[0].attrs.value, '');
  assert.strictEqual(staticInputs[1].attrs.value, '');
  assert.match(textOf(inheritedStatic), /純正設定を継承/);
  assert.match(textOf(inheritedStatic), /198\.51\.100\.11/);
  assert.match(textOf(inheritedStatic), /固定IPの適用プレビュー/);
  assert.doesNotMatch(source, /config\.fallback_ip \|\| '192\.168\.3\.1'/);
  assert.doesNotMatch(source, /config\.netmask \|\| config\.fallback_netmask/);
  const apDhcp = view.render({
    status: { mode: 'ap', configured_mode: 'ap', managed: 1 },
    config: { proto: 'dhcp', ap_dhcp_enabled: 1, fallback_ip: '192.168.3.1' }
  });
  const enabledProtoInputs = flatten(apDhcp).filter(n => n.tag === 'input' && n.attrs.name === 'sbair-management-proto');
  assert.strictEqual(enabledProtoInputs.some(n => n.attrs.value === 'dhcp'), true);
  assert.strictEqual(enabledProtoInputs.some(n => n.attrs.value === 'static'), true);
  assert.match(textOf(apDhcp), /DHCPクライアント設定は非常に高いリスク/);
  const concise = view.render({
    status: { mode: 'ap', configured_mode: 'ap', managed: 1, health: 'ok',
      management: { address: '198.51.100.11', proto: 'static', gateway: '198.51.100.1', dns: '198.51.100.1' },
      cellular: { default_route: false }, dhcp_server: { configured: false, uci_ignore: true } },
    config: { proto: 'static' }
  });
  assert.match(source, /LAN DHCPサーバー/);
  assert.doesNotMatch(textOf(concise), /MLO|バンドステアリング|2\.4GHz|5GHz|6GHz/);
  assert.doesNotMatch(textOf(concise), /有線 \/ USBネットワーク診断/);
  assert.match(source, /self\.draft = \{\};/);
  assert.match(source, /netmode_unmanage/);
  assert.doesNotMatch(source, /netmode_netdev_status/);
  process.stdout.write('netmode-js-fixture-ok\n');
}).catch(function(err) {
  console.error(err);
  process.exit(1);
});
NODE
