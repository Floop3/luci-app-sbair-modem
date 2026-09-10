#!/bin/sh
# SPDX-License-Identifier: MIT
# Read-only LuCI fixture for the complete USB inventory screen.
set -eu

repo=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
node - "$repo/htdocs/luci-static/resources/view/sbair/usb.js" <<'NODE'
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
  return (node.attrs && node.attrs.title ? node.attrs.title : '') + textOf(node.children || []);
}

const inventory = {
  scope: 'all-usb-devices',
  usb_controllers: [{ name: 'xhci-hcd.0', driver: 'xhci-hcd', bus_speed: '5000' }],
  usb_devices: [
    {
      name: '1-1', kind: 'network', vid_pid: '0bda:8153', manufacturer: 'Realtek', product: 'USB 10/100/1000 LAN',
      bus_speed: '5000', bcd_usb: '0200', device_class: '02', driver: 'unbound', network_candidate: true,
      interfaces: [{ name: '1-1:1.0', class: '02', subclass: '06', protocol: '00', driver: 'unbound', netdevs: [], block_devices: [], modalias: 'usb:v0BDAp8153' }],
      driver_management: { device_class_allowed: true, provenance: 'not-bound', expected_driver: 'r8152（参照）', bundle_available: false, install_available: false, remove_available: false, reason: 'kernel-matched app bundle未提供' }
    },
    { name: '1-2', kind: 'hub', vid_pid: '2109:2817', bus_speed: '480', product: 'USB2.0 Hub', device_class: '09', network_candidate: false, interfaces: [], driver: 'hub', driver_management: { reason: 'USB Ethernet以外は対象外' } },
    { name: '1-3', kind: 'storage', vid_pid: '0781:5591', bus_speed: '5000', product: 'Flash Disk', device_class: '08', network_candidate: false, interfaces: [{ name: '1-3:1.0', class: '08', subclass: '06', protocol: '50', driver: 'usb-storage', netdevs: [], block_devices: ['sda'], modalias: 'usb:v0781p5591' }], driver: 'usb-storage', driver_management: { reason: 'USB Ethernet以外は対象外' } },
    { name: '1-4', kind: 'serial', vid_pid: '067b:2303', bus_speed: '12', product: 'Serial', device_class: '00', network_candidate: false, interfaces: [{ name: '1-4:1.0', class: 'ff', subclass: '00', protocol: '00', driver: 'pl2303', netdevs: [], block_devices: [], modalias: 'usb:v067Bp2303' }], driver: 'pl2303', driver_management: { reason: 'USB Ethernet以外は対象外' } },
    { name: '1-5', kind: 'vendor-specific', vid_pid: '1234:5678', bus_speed: '12', product: 'Vendor device', device_class: 'ff', network_candidate: false, interfaces: [], driver: 'unbound', driver_management: { reason: 'USB Ethernet候補ではないため対象外' } },
    { name: '1-6', kind: 'unknown', vid_pid: 'abcd:0001', bus_speed: 'unknown', product: 'Unknown', device_class: '00', network_candidate: false, interfaces: [], driver: 'unbound', driver_management: { reason: 'クラス未確定のため対象外' } }
  ]
};
const nic = {
  result: 'ok',
  bundle: { state: 'missing', reason: 'missing' },
  driver: {
    support_level: 'experimental-b2-live-validated-provenance-based',
    kernel: '5.4.238', architecture: 'aarch64',
    sha256: '7f0e5f3ec197a5f80f23195a3945a2d700bca9d97b8c04eadbacb02c247523c1',
    vermagic: '5.4.238 SMP mod_unload modversions aarch64'
  },
  udc: { name: '11201000.usb', present: false, state: 'unknown', current_speed: 'unknown', bound_gadget: 'none' },
  profile: { state: 'missing', path: '/etc/sbair/usb-nic/profile' },
  runtime: { state: 'preflight-ng', module_loaded: false },
  usb0: { state: 'absent', carrier: 'absent' },
  management_path: 'ng',
  preflight: { state: 'ng', reason: 'bundle-missing' }
};

const context = {
  Promise,
  E,
  rpc: { declare: function(options) { return function() {
    calls.push(options.method);
    if (options.method === 'usb_nic_status') return Promise.resolve(nic);
    return Promise.resolve(inventory);
  }; } },
  view: { extend: function(value) { return value; } },
  ui: { createHandlerFn: function(_self, fn) { return fn; }, addNotification: function() {} },
  dom: { content: function(node, children) { node.children = Array.isArray(children) ? children : [ children ]; } },
  sbair: {
    section: function(title, children) { return E('section', { title }, children); },
    table: function(rows) { return E('table', {}, rows); },
    row: function(label, value, extra) { return E('row', { label }, [ value, extra || '' ]); },
    errorBox: function(errors) { return E('error', {}, errors); }
  }
};
const view = vm.runInNewContext('(function() {\n' + source + '\n})()', context);

view.load().then(function(data) {
  assert.deepStrictEqual(calls, [ 'usb_status', 'usb_nic_status' ]);
  const rendered = view.render(data);
  const content = rendered.children[1];
  assert(content && content.children.every(node => !Array.isArray(node)), 'render contains nested child array');
  const text = textOf(rendered);
  for (const value of [ '1-1', '1-2', '1-3', '1-4', '1-5', '1-6', '0bda:8153', '5000 Mbps', 'sda', 'r8152（参照）' ])
    assert(text.includes(value), 'missing USB inventory value: ' + value);
  const buttons = flatten(rendered).filter(node => node.tag === 'button');
  const driverButtons = buttons.filter(button => /インストール|削除/.test(textOf(button)));
  assert.strictEqual(driverButtons.length, inventory.usb_devices.length * 2);
  assert(driverButtons.every(button => button.attrs.disabled === ''));
  assert(text.includes('USB Host'));
  assert(text.includes('USB Gadget（CDC-NCM NIC）'));
  assert(text.includes('実験的・高リスク機能'));
  assert(text.includes('未導入'));
  const nicButtons = buttons.filter(button => /Enable|Disable/.test(textOf(button)));
  assert.strictEqual(nicButtons.length, 2);
  assert(nicButtons[0].attrs.disabled === '');
  process.stdout.write('usb-js-fixture-ok\n');
}).catch(function(err) {
  console.error(err);
  process.exit(1);
});
NODE
