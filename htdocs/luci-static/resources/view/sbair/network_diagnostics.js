// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Floop3
//
// Read-only LAN / bridge diagnostics. The existing netmode_netdev_status RPC
// remains the source of truth; this view only gives its network information a
// dedicated owner and does not display the generic USB inventory.

'use strict';
'require view';
'require rpc';
'require ui';
'require dom';
'require tools.sbair as sbair';

var callStatus = rpc.declare({ object: 'sbair', method: 'netmode_netdev_status' });

function valueOrDash(value) {
	return value === undefined || value === null || value === '' ? '-' : String(value);
}

function mbps(value) {
	value = valueOrDash(value);
	return value === '-' || value === 'unknown' || value === 'none' ? value : value + ' Mbps';
}

function networkDeviceTable(devices) {
	var rows = [ E('tr', { 'class': 'tr table-titles' }, [
		E('th', { 'class': 'th' }, 'interface'),
		E('th', { 'class': 'th' }, 'role'),
		E('th', { 'class': 'th' }, 'state / carrier'),
		E('th', { 'class': 'th' }, 'MAC / MTU'),
		E('th', { 'class': 'th' }, 'master'),
		E('th', { 'class': 'th' }, 'driver / bus'),
		E('th', { 'class': 'th' }, 'link / duplex')
	]) ];
	(devices || []).forEach(function(device) {
		rows.push(E('tr', { 'class': 'tr' }, [
			E('td', { 'class': 'td left' }, valueOrDash(device.name)),
			E('td', { 'class': 'td left' }, valueOrDash(device.role)),
			E('td', { 'class': 'td left' }, valueOrDash(device.operstate) + ' / ' + valueOrDash(device.carrier)),
			E('td', { 'class': 'td left' }, valueOrDash(device.mac) + ' / ' + valueOrDash(device.mtu)),
			E('td', { 'class': 'td left' }, valueOrDash(device.master)),
			E('td', { 'class': 'td left' }, valueOrDash(device.driver) + ' / ' + valueOrDash(device.bus_type)),
			E('td', { 'class': 'td left' }, mbps(device.link_speed) + ' / ' + valueOrDash(device.duplex))
		]));
	});
	return sbair.table(rows);
}

function usbCandidateTable(devices) {
	var rows = [ E('tr', { 'class': 'tr table-titles' }, [
		E('th', { 'class': 'th' }, 'USB Host network candidate'),
		E('th', { 'class': 'th' }, 'VID:PID'),
		E('th', { 'class': 'th' }, 'driver'),
		E('th', { 'class': 'th' }, 'bus speed')
	]) ];
	(devices || []).filter(function(device) { return device.network_candidate; }).forEach(function(device) {
		rows.push(E('tr', { 'class': 'tr' }, [
			E('td', { 'class': 'td left' }, valueOrDash(device.name)),
			E('td', { 'class': 'td left' }, valueOrDash(device.vid_pid)),
			E('td', { 'class': 'td left' }, valueOrDash(device.driver)),
			E('td', { 'class': 'td left' }, mbps(device.bus_speed))
		]));
	});
	return sbair.table(rows);
}

function render(data) {
	data = data || {};
	if (data.error)
		return [ sbair.errorBox([ data.error ]) ];

	var bridge = data.bridge || {};
	var devices = data.network_devices || [];
	var candidates = (data.usb_devices || []).filter(function(device) {
		return device.network_candidate;
	});
	return [
		E('p', { 'style': 'opacity:.8' },
			'sysfsを主に参照する読み取り専用診断です。USB Host Ethernetを自動でWAN/LANへ割り当てず、UCI・bridge・kernel moduleも変更しません。'),
		sbair.section('Bridge', [ sbair.table([
			sbair.row('Bridge', valueOrDash(bridge.name)),
			sbair.row('Bridge members', bridge.members && bridge.members.length ? bridge.members.join(', ') : '未検出')
		]) ]),
		sbair.section('Network devices', [
			devices.length ? networkDeviceTable(devices) : E('p', {}, 'network deviceは未検出')
		]),
		sbair.section('USB Host network candidates', [
			candidates.length ? usbCandidateTable(data.usb_devices) : E('p', {}, 'USB Host network device候補は未検出（全USB Host機器は「本体 > USB機器」で確認できます）')
		])
	];
}

return view.extend({
	load: function() {
		return callStatus().catch(function(err) {
			return { error: 'ネットワーク診断の取得に失敗しました: ' + String(err) };
		});
	},

	render: function(data) {
		var self = this;
		self.data = data || {};
		var container = E('div', {}, render(self.data));

		function reload() {
			return callStatus().then(function(result) {
				self.data = result || {};
				dom.content(container, render(self.data));
			}).catch(function(err) {
				ui.addNotification(null, E('p', {}, String(err)), 'warning');
			});
		}

		return E('div', { 'class': 'cbi-map' }, [
			E('div', { 'style': 'margin-bottom:1em' }, [
				E('button', {
					'class': 'cbi-button cbi-button-neutral',
					'click': reload
				}, '再読み込み')
			]),
			container
		]);
	},

	handleSave: null,
	handleSaveApply: null,
	handleReset: null
});
