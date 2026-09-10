// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Floop3
//
// Read-only Wi-Fi configuration drift monitor. The diagnostic buttons are the
// only paths that may explicitly run knsh save or wlan restart.

'use strict';
'require view';
'require rpc';
'require ui';
'require dom';
'require tools.sbair as sbair';

var callStatus = rpc.declare({ object: 'sbair', method: 'wifi_drift_status' });
var callSet = rpc.declare({ object: 'sbair', method: 'wifi_drift_set', params: [ 'enabled' ] });
var callMarkGood = rpc.declare({ object: 'sbair', method: 'wifi_drift_mark_good' });
var callLogs = rpc.declare({ object: 'sbair', method: 'wifi_drift_logs' });
var callSaveTest = rpc.declare({ object: 'sbair', method: 'wifi_drift_save_test' });
var callRestartTest = rpc.declare({ object: 'sbair', method: 'wifi_drift_restart_test' });

var bands = [ '2.4G', '5G', '6G' ];
var bandLabel = { '2.4G': '2.4GHz', '5G': '5GHz', '6G': '6GHz' };

function value(v) {
	return v === undefined || v === null || v === '' ? '-' : String(v);
}

function badge(text, color) {
	var colors = { green: '#5cb85c', yellow: '#e6a23c', red: '#d9534f', gray: '#777' };
	return E('span', { 'class': 'ifacebadge', 'style': 'margin-left:.5em;background:' + (colors[color] || colors.gray) + ';color:#fff' }, text);
}

function statusBadge(status) {
	var labels = {
		ok: [ '正常', 'green' ], config_drift: [ '設定差異あり', 'red' ],
		runtime_drift: [ 'Runtime差異あり', 'red' ], '6g_attention': [ '6GHz要確認', 'yellow' ],
		no_baseline: [ '正常状態未記録', 'yellow' ]
	};
	var item = labels[status] || [ '不明', 'gray' ];
	return badge(item[0], item[1]);
}

function featureValue(features, key) {
	var v = features && features[key];
	return v === 'on' ? badge('ON', 'gray') : (v === 'off' ? badge('OFF', 'gray') : badge('不明', 'gray'));
}

function runtimeValue(r, field) {
	if (!r) return '-';
	if (field === 'protocol') return value(r.hostapd && r.hostapd.protocol);
	if (field === 'channel') return value(r.channel);
	if (field === 'width') return value(r.width) === '-' ? '-' : value(r.width) + ' MHz';
	if (field === 'frequency') return value(r.primary_frequency) + ' / ' + value(r.center_frequency);
	if (field === 'hostapd') return r.hostapd && r.hostapd.available ? value(r.hostapd.state) : '-';
	if (field === 'mac_bssid') return value(r.mac) + ' / ' + value(r.hostapd && r.hostapd.bssid);
	if (field === 'beacon_power') return value(r.beacon_counter) + ' / ' + value(r.iwinfo_tx_power);
	return value(r[field]);
}

function bandRow(label, uci, vendor, runtime) {
	return E('tr', { 'class': 'tr' }, [
		E('td', { 'class': 'td left' }, label), E('td', { 'class': 'td left' }, value(uci)),
		E('td', { 'class': 'td left' }, value(vendor)), E('td', { 'class': 'td left' }, value(runtime))
	]);
}

function vendorValue(data) {
	var files = vendorFiles(data);
	if (!files.length) return '未検出（' + value(data.current && data.current.vendor_discovery) + '）';
	return '未解析（hash / mtime / sizeのみ監視）';
}

function vendorFiles(data) {
	var files = (data.current && data.current.files) || {};
	return Object.keys(files).filter(function(path) {
		return path !== '/etc/config/wireless' && path !== '/etc/config/knos';
	}).sort();
}

function vendorFilesSection(data) {
	var files = (data.current && data.current.files) || {};
	var paths = vendorFiles(data);
	if (!paths.length)
		return E('p', {}, 'Vendor persistentは未検出。内容は解析せず、存在するファイルのmetadataだけを監視します。');
	var rows = [ E('tr', { 'class': 'tr table-titles' }, [
		E('th', { 'class': 'th' }, 'path'), E('th', { 'class': 'th' }, 'sha256'),
		E('th', { 'class': 'th' }, 'mtime'), E('th', { 'class': 'th' }, 'size')
	]) ];
	paths.forEach(function(path) {
		var file = files[path] || {};
		rows.push(E('tr', { 'class': 'tr' }, [
			E('td', { 'class': 'td left' }, path), E('td', { 'class': 'td left' }, value(file.sha256)),
			E('td', { 'class': 'td left' }, value(file.mtime)), E('td', { 'class': 'td left' }, value(file.size))
		]));
	});
	return sbair.table(rows);
}

function driftTable(data) {
	var current = data.current || {};
	var currentBands = current.bands || {};
	var rows = [ E('tr', { 'class': 'tr table-titles' }, [
		E('th', { 'class': 'th' }, '項目'), E('th', { 'class': 'th' }, 'UCI設定'),
		E('th', { 'class': 'th' }, 'Vendor persistent'), E('th', { 'class': 'th' }, 'Runtime')
	]) ];
	bands.forEach(function(band) {
		var b = currentBands[band] || {};
		var vendor = vendorValue(data);
		var prefix = bandLabel[band] + ' ';
		rows.push(bandRow(prefix + 'Radio / AP interface', value(b.radio) + ' / ' + value(b.ap_interface), vendor, runtimeValue(b.runtime, 'interface')));
		rows.push(bandRow(prefix + 'Enabled', b.enabled, vendor, runtimeValue(b.runtime, 'hostapd')));
		rows.push(bandRow(prefix + 'Protocol', b.protocol, vendor, runtimeValue(b.runtime, 'protocol')));
		rows.push(bandRow(prefix + 'HTMode', b.htmode, vendor, '-'));
		rows.push(bandRow(prefix + 'Channel', value(b.channel_policy) + ' / ' + value(b.configured_channel), vendor, runtimeValue(b.runtime, 'channel')));
		rows.push(bandRow(prefix + 'Bandwidth', value(b.bandwidth_policy) + ' / ' + value(b.configured_bandwidth), vendor, runtimeValue(b.runtime, 'width')));
		rows.push(bandRow(prefix + 'Frequency (primary / center)', '-', vendor, runtimeValue(b.runtime, 'frequency')));
		rows.push(bandRow(prefix + 'Hostapd', '-', vendor, runtimeValue(b.runtime, 'hostapd')));
		rows.push(bandRow(prefix + 'MAC / BSSID', '-', vendor, runtimeValue(b.runtime, 'mac_bssid')));
		rows.push(bandRow(prefix + 'Beacon / Tx power', '-', vendor, runtimeValue(b.runtime, 'beacon_power')));
		rows.push(bandRow(prefix + 'Association count', '-', vendor, runtimeValue(b.runtime, 'association_count')));
	});
	rows.push(E('tr', { 'class': 'tr' }, [ E('td', { 'class': 'td left' }, 'MLO'), E('td', { 'class': 'td left' }, '-'),
		E('td', { 'class': 'td left' }, featureValue(current.features, 'mlo')), E('td', { 'class': 'td left' }, '-') ]));
	rows.push(E('tr', { 'class': 'tr' }, [ E('td', { 'class': 'td left' }, 'Band Steering'), E('td', { 'class': 'td left' }, '-'),
		E('td', { 'class': 'td left' }, featureValue(current.features, 'bandsteering')), E('td', { 'class': 'td left' }, '-') ]));
	return sbair.table(rows);
}

function changeSummary(data) {
	var s = data.summary || {};
	var last = data.last_change || {};
	var first = last.changes && last.changes[0];
	return sbair.table([
		sbair.row('最後の変化日時', value(last.timestamp)),
		sbair.row('変化したlayer / 項目', value(first && first.layer) + ' / ' + value(first && first.field)),
		sbair.row('起動後の変化時点', value(first && first.uptime_sec) + ' 秒'),
		sbair.row('UCI hash changed?', s.uci_hash_changed ? 'yes' : 'no'),
		sbair.row('Vendor persistent changed?', s.vendor_persistent_changed ? 'yes' : 'no'),
		sbair.row('Runtime only changed?', s.runtime_only_changed ? 'yes' : 'no'),
		sbair.row('Known-good profile', value(data.baseline_recorded_at))
	]);
}

function details(title, children, open) {
	return E('details', { 'open': open ? '' : null }, [
		E('summary', {}, title),
		E('div', {}, children)
	]);
}

function render(data, opts) {
	data = data || {};
	opts = opts || {};
	var monitor = data.monitor || {};
	var current = data.current || {};
	var body = [];
	body.push(sbair.softBrickWarning('wifi'));
	body.push(sbair.section('監視', [ sbair.table([
		sbair.row('モード', E('label', {}, [ E('input', { 'type': 'checkbox', 'checked': monitor.enabled ? '' : null,
			'change': function(ev) { opts.onEnable(ev.target.checked); } }), ' Monitor only（既定）' ]),
			monitor.enabled ? badge('監視中', 'green') : badge('OFF', 'gray'))
	]) ]));
	body.push(sbair.section('総合状態', [ sbair.table([
		sbair.row('状態', statusBadge(data.status)),
		sbair.row('UCI / vendor検出', value(current.vendor_discovery))
	]) ]));
	body.push(sbair.section('直近の変化 / Known-good', [ changeSummary(data) ]));
	body.push(details('設定詳細（UCI / Vendor persistent / Runtime）', [
		E('p', { 'style': 'opacity:.8' }, 'UCI設定、vendor persistent、実動作(runtime)を別layerとして表示します。Vendor persistentのband別実値は未解析で、hash / mtime / sizeだけを監視します。AUTOのチャンネル/帯域幅がACSで変化してもdriftとは判定しません。'),
		sbair.section('設定比較', [ driftTable(data) ]),
		details('Vendor persistent metadata', [ vendorFilesSection(data) ])
	]));

	var troubleshooting = [
		E('div', { 'class': 'sbair-button-group', 'style': 'margin-bottom:.75em' }, [
			E('button', { 'class': 'cbi-button cbi-button-positive', 'click': opts.onMarkGood }, '現在を正常状態として記録'),
			E('button', { 'class': 'cbi-button cbi-button-neutral', 'click': opts.onLogs }, '診断ログを表示'),
			E('button', { 'class': 'cbi-button cbi-button-neutral', 'click': opts.onSaveTest }, '安全な knsh save 差分テスト'),
			E('button', { 'class': 'cbi-button cbi-button-neutral', 'disabled': data.restart_test && data.restart_test.state === 'running' ? '' : null,
				'click': opts.onRestartTest }, data.restart_test && data.restart_test.state === 'running' ? 'Wi-Fi restart診断を実行中…' : '差分確認後にWi-Fi restartして比較')
		])
	];
	if (data.restart_test)
		troubleshooting.push(sbair.section('restart診断', [ sbair.table([
			sbair.row('状態', value(data.restart_test.state)),
			sbair.row('knsh wlan restart', data.restart_test.command_succeeded ? '成功' : '失敗'),
			sbair.row('比較結果', value((data.restart_test.differences || []).length) + ' 件')
		]) ]));
	if (opts.logs)
		troubleshooting.push(sbair.section('診断ログ（直近）', [ E('pre', { 'style': 'white-space:pre-wrap;max-height:30em;overflow:auto' }, opts.logs) ]));
	body.push(details('トラブルシューティング', troubleshooting, !!opts.logs || !!data.restart_test));

	if (data.differences && data.differences.length) {
		var diffRows = [ E('tr', { 'class': 'tr table-titles' }, [
			E('th', { 'class': 'th' }, 'layer'), E('th', { 'class': 'th' }, 'band'), E('th', { 'class': 'th' }, '項目'), E('th', { 'class': 'th' }, 'old'), E('th', { 'class': 'th' }, 'new')
		]) ];
		diffRows = diffRows.concat(data.differences.slice(0, 80).map(function(d) { return E('tr', { 'class': 'tr' }, [
			E('td', { 'class': 'td left' }, value(d.layer)), E('td', { 'class': 'td left' }, value(d.band)),
			E('td', { 'class': 'td left' }, value(d.field)), E('td', { 'class': 'td left' }, value(d.old)), E('td', { 'class': 'td left' }, value(d.new))
		]); }));
		body.push(details('Known-goodとの差分（' + data.differences.length + '件）', [ sbair.section('差分一覧', [ sbair.table(diffRows) ]) ]));
	}
	return body;
}

return view.extend({
	load: function() { return callStatus(); },
	render: function(data) {
		var self = this, container = E('div', {}), logs = null;
		function reload() {
			return callStatus().then(function(res) { self.data = res; logs = null; redraw(); })
				.catch(function(err) { ui.addNotification(null, E('p', {}, String(err)), 'warning'); });
		}
		function report(res) {
			if (res && res.error) ui.addNotification(null, E('p', {}, res.error), 'danger');
			return reload();
		}
		function redraw() {
			dom.content(container, render(self.data, {
				logs: logs, onEnable: function(v) { callSet(v ? '1' : '0').then(report); },
				onMarkGood: function() { if (confirm('現在のWi-Fi状態をKnown-goodとして記録しますか?')) callMarkGood().then(report); },
				onLogs: function() { callLogs().then(function(res) { logs = res && res.log || ''; redraw(); }); },
				onSaveTest: function() {
					if (!confirm('knsh saveだけを実行します。Wi-Fi restartは実行しません。続行しますか?')) return;
					callSaveTest().then(function(res) { if (res && res.error) throw new Error(res.error); ui.addNotification(null, E('p', {}, 'knsh save前後の差分を取得しました。Wi-Fi restartはしていません。'), 'info'); return reload(); })
						.catch(function(err) { ui.addNotification(null, E('p', {}, String(err)), 'danger'); });
				},
				onRestartTest: function() {
					if (!confirm('明示的にknsh wlan restartを実行し、runtimeを比較します。Wi-Fiは一時切断されます。続行しますか?')) return;
					callRestartTest().then(report);
				}
			}));
		}
		self.data = data || {};
		redraw();
		return E('div', { 'class': 'cbi-map' }, [ E('div', { 'style': 'margin-bottom:1em' }, [
			E('button', { 'class': 'cbi-button cbi-button-neutral', 'click': reload }, '再読み込み')
		]), container ]);
	},
	handleSave: null, handleSaveApply: null, handleReset: null
});
