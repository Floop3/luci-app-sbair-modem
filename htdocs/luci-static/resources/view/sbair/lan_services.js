// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Floop3
//
// LAN services. DHCP here means the LAN DHCP *server* only; the Air 6's own
// management-IP DHCP client remains owned by netmode.

'use strict';
'require view';
'require rpc';
'require ui';
'require dom';
'require tools.sbair as sbair';

var callStatus = rpc.declare({ object: 'sbair', method: 'maintenance_status' });
var callDHCPServer = rpc.declare({ object: 'sbair', method: 'dhcp_server_set', params: [ 'enabled' ] });

function value(v) {
	return v === undefined || v === null || v === '' ? '-' : String(v);
}

function onOff(v) {
	if (v === true || v === 1 || v === '1' || v === 'running' || v === 'enabled')
		return '有効 / 稼働中';
	if (v === false || v === 0 || v === '0' || v === 'stopped' || v === 'disabled')
		return '無効 / 停止';
	return value(v);
}

function statusTable(rows) {
	return sbair.table(rows.map(function(row) {
		return sbair.row(row[0], row[1]);
	}));
}

function actionButton(label, enabled, action) {
	return E('button', {
		'class': enabled ? 'cbi-button cbi-button-positive' : 'cbi-button cbi-button-negative',
		'click': action
	}, label);
}

function render(data, onSet) {
	data = data || {};
	if (data.error)
		return [ sbair.errorBox([ data.error ]) ];

	var d = data.dhcp_server || {};
	var enabled = d.enabled === true || d.enabled === 1 || d.enabled === '1';
	return [ sbair.section('LAN DHCPサーバー', [
		E('p', { 'style': 'opacity:.8' }, 'Air 6からLANクライアントへのIP配布を管理します。'),
		E('p', {}, [
			'この設定はAir 6がLAN端末へIPを配る「LAN DHCPサーバー」です。',
			E('br'),
			'Air 6自身が親ルーターから管理IPを取得する「DHCPクライアント設定」には影響しません。'
		]),
		statusTable([
			[ 'LAN DHCPサーバー', onOff(enabled) ],
			[ 'dhcp.lan.ignore', value(d.uci_ignore) ],
			[ 'UDP/67', onOff(d.udp67_listening) + ' / ' + value(d.udp67_scope) ],
			[ 'dnsmasq', value(d.dnsmasq) ],
			[ 'DNS :53', onOff(d.port53_listening) + ' / TCP: ' + value(d.port53_tcp_scope) + ' / UDP: ' + value(d.port53_udp_scope) ],
			[ 'odhcpd', value(d.odhcpd) ],
			[ 'RA / DHCPv6 / NDP', value(d.ra) + ' / ' + value(d.dhcpv6) + ' / ' + value(d.ndp) ],
			[ '管理元', d.owner === 'netmode-ap' ? '接続モード（AP / Bridge）' : '手動' ],
			[ 'DHCP packet guard', onOff(d.guard_active) ],
			[ 'Safe Apply pending', onOff(d.pending) ]
		]),
		E('div', { 'class': 'sbair-button-group', 'style': 'margin-top:.75em' }, [
			actionButton('DHCPサーバーを無効化', false, function() {
				if (confirm('LAN端末へのDHCPサーバーを無効化します。DHCPをAir 6に依存する端末はIPを更新できなくなる場合があります。続行しますか?'))
					onSet(false);
			}),
			actionButton('DHCPサーバーを有効化', true, function() {
				if (confirm('LAN端末へのDHCPサーバーを有効化します。同一LAN上に別のDHCPサーバーがあると競合する場合があります。続行しますか?'))
					onSet(true);
			})
		]),
		E('p', { 'class': 'alert-message warning' },
			'EasyMeshが有効になっている場合、自動的にDHCPが有効に戻ることがあります。本機能ではEasyMeshの設定を自動変更しません。' +
			'AP / Bridgeとして運用する前に、必要に応じて純正WebUI側でEasyMeshの設定を手動で確認してください。')
	]) ];
}

return view.extend({
	load: function() {
		return callStatus().catch(function(err) {
			return { error: String(err) };
		});
	},

	render: function(data) {
		var self = this;
		self.data = data || {};
		var container = E('div', {});

		function reload() {
			return callStatus().then(function(result) {
				self.data = result || {};
				dom.content(container, render(self.data, change));
			}).catch(function(err) {
				ui.addNotification(null, E('p', {}, String(err)), 'danger');
			});
		}

		function change(enabled) {
			return callDHCPServer(enabled).then(function(result) {
				if (result && result.error) {
					ui.addNotification(null, E('p', {}, result.error), 'danger');
					return;
				}
				if (result && result.warning)
					ui.addNotification(null, E('p', {}, result.warning), 'warning');
				return reload();
			}).catch(function(err) {
				ui.addNotification(null, E('p', {}, String(err)), 'danger');
			});
		}

		dom.content(container, render(self.data, change));
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
