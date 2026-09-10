// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Floop3
//
// OTA/FOTA controls. Keep the vendor update semantics in the existing
// maintenance backend; this view only gives the feature its own UI owner.

'use strict';
'require view';
'require rpc';
'require ui';
'require dom';
'require tools.sbair as sbair';

var callStatus = rpc.declare({ object: 'sbair', method: 'maintenance_status' });
var callFOTA = rpc.declare({ object: 'sbair', method: 'fota_set', params: [ 'enabled' ] });

function value(v) {
	return v === undefined || v === null || v === '' ? '-' : String(v);
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

	var f = data.fota || {};
	return [ sbair.section('OTA / FOTA 自動更新', [
		E('p', { 'style': 'opacity:.8' }, '純正のkn_fotadによる本体自動更新を管理します。サーバー遮断、バイナリ変更、respawn設定の変更は行いません。'),
		statusTable([
			[ 'FOTA本体', value(f.config_enabled) ],
			[ 'Provisioning', value(f.provision_enabled) ],
			[ 'respawn設定', value(f.config_respawn) ],
			[ 'kn_fotad', value(f.kn_fotad) ],
			[ '自動起動', value(f.autostart) ]
		]),
		E('div', { 'class': 'sbair-button-group', 'style': 'margin-top:.75em' }, [
			actionButton('OTA/FOTA自動更新を無効化', false, function() {
				if (confirm('OTA/FOTA自動更新を無効化します。fota.config.enabled と fota.provision.enabled を0にし、kn_fotadを停止・自動起動無効化します。続行しますか?'))
					onSet(false);
			}),
			actionButton('OTA/FOTA自動更新を有効化', true, function() {
				if (confirm('OTA/FOTA自動更新を有効化し、kn_fotadを起動します。続行しますか?'))
					onSet(true);
			})
		]),
		E('p', { 'style': 'opacity:.8;font-size:90%' }, '無効化時も fota.config.respawn は変更しません。10秒待機後にkn_fotadの再起動有無を確認します。')
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
			return callFOTA(enabled).then(function(result) {
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
