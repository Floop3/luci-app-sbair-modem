#!/bin/sh
# SPDX-License-Identifier: MIT
# Read-only LuCI fixture for the dedicated network diagnostics page.
set -eu

repo=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
node - "$repo/htdocs/luci-static/resources/view/sbair/network_diagnostics.js" <<'NODE'
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

const report = {
  kernel: { release: '5.4.238', architecture: 'aarch64' },
  bridge: { name: 'br-lan', members: [ 'eth0', 'ra0' ] },
  network_devices: [{
    name: 'eth0', role: 'bridge member', operstate: 'up', carrier: '1',
    mac: '00:11:22:33:44:55', mtu: '1500', master: 'br-lan',
    driver: 'mtk_soc_eth', bus_type: 'platform', link_speed: '1000', duplex: 'full'
  }],
  usb_controllers: [{ name: 'usb1', driver: 'xhci-hcd', bus_speed: '5000' }],
  usb_devices: [
    { name: '1-1', vid_pid: '0bda:8153', driver: 'r8152', bus_speed: '5000', network_candidate: true },
    { name: '1-2', vid_pid: '0781:5591', driver: 'usb-storage', bus_speed: '5000', network_candidate: false }
  ]
};

const context = {
  Promise,
  E,
  rpc: { declare: function(options) { return function() { calls.push(options.method); return Promise.resolve(report); }; } },
  view: { extend: function(value) { return value; } },
  ui: { addNotification: function() {} },
  dom: { content: function(node, children) { node.children = Array.isArray(children) ? children : [ children ]; } },
  sbair: {
    section: function(title, children) { return E('section', { title }, children); },
    table: function(rows) { return E('table', {}, rows); },
    row: function(label, value) { return E('row', { label }, [ value ]); },
    errorBox: function(errors) { return errors && errors.length ? E('error', {}, errors) : ''; }
  }
};
const view = vm.runInNewContext('(function() {\n' + source + '\n})()', context);

view.load().then(function(data) {
  assert.deepStrictEqual(calls, [ 'netmode_netdev_status' ]);
  const rendered = view.render(data);
  const text = textOf(rendered);
  for (const value of [ 'br-lan', 'eth0', 'up / 1', 'mtk_soc_eth', 'USB Host network candidate', '0bda:8153', 'r8152' ])
    assert(text.includes(value), 'missing network diagnostic value: ' + value);
  assert(!text.includes('xhci-hcd'));
  assert(!text.includes('0781:5591'));
  assert.match(source, /netmode_netdev_status/);
  assert.doesNotMatch(source, /USB buses \/ root hubs/);
  console.log('network-diagnostics-js-fixture-ok');
}).catch(function(err) {
  console.error(err);
  process.exit(1);
});
NODE
