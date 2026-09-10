// SPDX-License-Identifier: MIT
// Copyright (c) 2026 syado
//
// Safe AP/Bridge mode for SoftBank Air 6. Wi-Fi settings are deliberately not
// edited here; this page owns only L3, DHCP/RA, fallback, and cellular routing.

'use strict';
'require view';
'require rpc';
'require ui';
'require dom';
'require tools.sbair as sbair';

var callStatus = rpc.declare({ object: 'sbair', method: 'netmode_status' });
var callGetConfig = rpc.declare({ object: 'sbair', method: 'netmode_get_config' });
var callApply = rpc.declare({
	object: 'sbair', method: 'netmode_apply',
	params: [ 'mode', 'proto', 'ipaddr', 'netmask', 'gateway', 'dns',
		'fallback_enabled', 'fallback_ip', 'fallback_netmask', 'fallback_timeout',
		'dhcp_start_ip', 'dhcp_end_ip', 'dhcp_leasetime' ]
});
var callConfirm = rpc.declare({ object: 'sbair', method: 'netmode_confirm' });
var callRollback = rpc.declare({ object: 'sbair', method: 'netmode_rollback' });
var callUnmanage = rpc.declare({ object: 'sbair', method: 'netmode_unmanage' });
var callRepair = rpc.declare({ object: 'sbair', method: 'netmode_repair' });

var modeLabel = { unmanaged: 'デフォルト（無制御） / 未管理', ap: 'AP / Bridge' };
var pollTimer;

function flagEnabled(value) {
	return value === true || value === 1 || value === '1';
}

function effectiveMode(status) {
	var managed = status && (status.managed === true || status.managed === 1 || status.managed === '1');
	if (managed && ((status && status.mode) === 'ap' || (status && status.configured_mode) === 'ap'))
		return 'ap';
	return 'unmanaged';
}

function displayModeLabel(mode) {
	// `sim` remains an internal legacy/recovery value, but is no longer a
	// selectable connection mode in this page.
	return mode === 'sim' ? modeLabel.unmanaged : (modeLabel[mode] || mode);
}

function badge(text, color) {
	var colors = {
		green: '#5cb85c', yellow: '#e6a23c', red: '#d9534f', gray: '#777'
	};
	return E('span', {
		'class': 'ifacebadge',
		'style': 'margin-left:.5em;background:' + (colors[color] || colors.gray) + ';color:#fff'
	}, text);
}

function healthBadge(data) {
	var health = data.health || (data.healthy ? 'ok' : 'warn');
	if (health === 'unmanaged') return badge('未管理', 'gray');
	return badge(health === 'ok' ? '正常' : (health === 'danger' ? '危険' : '要確認'),
		health === 'ok' ? 'green' : (health === 'danger' ? 'red' : 'yellow'));
}

function onOff(value, onText, offText) {
	if (value === true || value === 1 || value === '1') return badge(onText || 'ON', 'green');
	if (value === false || value === 0 || value === '0') return badge(offText || 'OFF', 'gray');
	return badge('非対象 / 不明', 'gray');
}

function observed(value) {
	if (value === true || value === 1 || value === '1') return badge('ON', 'gray');
	if (value === false || value === 0 || value === '0') return badge('OFF', 'gray');
	return badge('不明', 'gray');
}

function expectedOff(value) {
	return (value === false || value === 0 || value === '0')
		? badge('正常', 'green') : badge('要確認', 'red');
}

function valueOrDash(value) {
	return value === undefined || value === null || value === '' ? '-' : String(value);
}

function rawConfigValue(config, draft, key) {
	return draft[key] !== undefined ? draft[key] : (config[key] || '');
}

function staticResolution(config, draft) {
	var oem = config.oem || {};
	var ready = flagEnabled(config.oem_baseline_ready) || flagEnabled(oem.ready);
	var result = { oem: oem, fields: {} };
	[ 'ipaddr', 'netmask', 'gateway', 'dns' ].forEach(function(key) {
		var raw = rawConfigValue(config, draft, key);
		var inherited = ready ? (oem[key] || '') : '';
		var effective = raw || inherited;
		result.fields[key] = {
			raw: raw,
			oem: oem[key] || '',
			effective: effective,
			source: raw ? '明示指定' : (effective ? '純正設定を継承' : '未解決（純正設定なし）')
		};
	});
	return result;
}

function staticPreviewText(config, draft) {
	var resolution = staticResolution(config, draft);
	return [ '適用予定の固定IP設定',
		'固定IP: ' + valueOrDash(resolution.fields.ipaddr.effective) + '（' + resolution.fields.ipaddr.source + '）',
		'ネットマスク: ' + valueOrDash(resolution.fields.netmask.effective) + '（' + resolution.fields.netmask.source + '）',
		'Gateway: ' + valueOrDash(resolution.fields.gateway.effective) + '（' + resolution.fields.gateway.source + '）',
		'DNS: ' + valueOrDash(resolution.fields.dns.effective) + '（' + resolution.fields.dns.source + '）'
	].join('\n');
}

function staticPreviewSection(config, draft, proto) {
	if (proto !== 'static') return '';
	var resolution = staticResolution(config, draft);
	var rows = [
		sbair.row('固定IP', valueOrDash(resolution.fields.ipaddr.effective), resolution.fields.ipaddr.source),
		sbair.row('ネットマスク', valueOrDash(resolution.fields.netmask.effective), resolution.fields.netmask.source),
		sbair.row('Gateway', valueOrDash(resolution.fields.gateway.effective), resolution.fields.gateway.source),
		sbair.row('DNS', valueOrDash(resolution.fields.dns.effective), resolution.fields.dns.source)
	];
	return E('div', { 'class': 'sbair-netmode-static-preview', 'style': 'margin-top:1em;font-size:.9em;opacity:.9' }, [
		E('h4', {}, '固定IPの適用プレビュー'),
		E('p', {}, '空欄は純正設定を継承します。純正設定が取得できない必須項目は適用時に拒否されます。'),
		E('p', { 'style': 'margin:.4em 0' }, '純正設定: 固定IP ' + valueOrDash(resolution.fields.ipaddr.oem) + ' / ネットマスク ' + valueOrDash(resolution.fields.netmask.oem) + ' / Gateway ' + valueOrDash(resolution.fields.gateway.oem) + ' / DNS ' + valueOrDash(resolution.fields.dns.oem)),
		sbair.table(rows)
	]);
}

function statusSection(status) {
	var management = status.management || {};
	var dhcp = status.dhcp_server || {};
	var cellular = status.cellular || {};
	var managed = status.managed === true || status.managed === 1 || status.managed === '1';
	var ap = managed && status.mode === 'ap';
	var modeText = managed
		? (status.mode === 'ap' ? modeLabel.ap : modeLabel.unmanaged)
		: '未管理（既存設定）';
	var rows = [
		sbair.row('動作モード', modeText, healthBadge(status)),
		sbair.row('管理IP', valueOrDash(management.address), onOff(management.fallback_active, 'Fallback', 'DHCP / 固定')),
		sbair.row('管理IP方式', valueOrDash(management.proto)),
		sbair.row('Gateway', valueOrDash(management.gateway)),
		sbair.row('DNS', valueOrDash(management.dns)),
		sbair.row('LAN DHCPサーバー', dhcp.uci_ignore ? '無効' : '有効', managed ? (ap ? expectedOff(dhcp.configured) : onOff(dhcp.configured, '正常', '要確認')) : observed(dhcp.configured)),
		sbair.row('デフォルトルート', cellular.default_route ? 'Cellular' : valueOrDash(management.gateway), managed ? (ap ? expectedOff(cellular.default_route) : onOff(cellular.default_route, 'Cellular', 'なし')) : observed(cellular.default_route)),
	];

	if (management.fallback_conflict)
		rows.push(sbair.row('Fallback', valueOrDash(status.management.fallback_ip), badge('競合 / 未付与', 'yellow')));
	if (status.repair)
		rows.push(sbair.row('最終補正 / 回数', valueOrDash(status.repair.last) + ' / ' + valueOrDash(status.repair.count)));
	return sbair.section('現在の状態', [ sbair.table(rows) ]);
}

function warningSection(warnings) {
	if (!warnings || !warnings.length) return '';
	return E('div', { 'class': 'cbi-section sbair-section' }, [
		E('h3', {}, '警告'),
		E('ul', {}, warnings.map(function(w) { return E('li', {}, w); }))
	]);
}

function inputRow(label, input, help) {
	return E('tr', { 'class': 'tr' }, [
		E('td', { 'class': 'td left', 'width': '35%' }, label),
		E('td', { 'class': 'td left' }, [ input, help ? E('p', { 'style': 'opacity:.7;margin:.3em 0 0' }, help) : '' ])
	]);
}

function textInput(value, disabled, onChange) {
	return E('input', {
		'class': 'cbi-input-text', 'type': 'text', 'value': valueOrDash(value) === '-' ? '' : valueOrDash(value),
		'disabled': disabled ? '' : null,
		'change': function(ev) { onChange(ev.target.value); }
	});
}

function unmanagedConfigSection(config) {
	var range = config.dhcp_start_ip && config.dhcp_end_ip
		? config.dhcp_start_ip + ' ～ ' + config.dhcp_end_ip
		: '既存設定からは算出できません';
	return sbair.section('既存設定（未管理）', [ sbair.table([
		sbair.row('管理状態', '未管理（既存設定を維持）'),
		sbair.row('現在のDHCP範囲（観測）', range),
		sbair.row('DHCPリース時間（観測）', valueOrDash(config.dhcp_leasetime)),
		sbair.row('SIM適用先LAN', valueOrDash(config.sim_network) + ' / ' + valueOrDash(config.sim_netmask))
	]) , E('p', { 'class': 'alert-message notice' },
		'sbairはネットワーク、DHCP、Wi-Fiを自動補正しません。変更する場合はAP / Bridgeを選び、明示的に適用してください。') ]);
}

function configSection(config, draft, selectedMode, onChange) {
	if (selectedMode === 'unmanaged') return unmanagedConfigSection(config);
	var apDhcpEnabled = flagEnabled(config.ap_dhcp_enabled);
	var proto = draft.proto !== undefined ? draft.proto : (config.proto || (apDhcpEnabled ? 'dhcp' : 'static'));
	if (!apDhcpEnabled) proto = 'static';
	var fallbackEnabled = draft.fallback_enabled !== undefined ? draft.fallback_enabled : !!config.fallback_enabled;
	var staticDisabled = proto !== 'static';
	var fallbackDisabled = proto !== 'dhcp';
	var staticIp = rawConfigValue(config, draft, 'ipaddr');
	var staticNetmask = rawConfigValue(config, draft, 'netmask');
	var radio = function(value, label) {
		return E('label', { 'style': 'display:block;margin:.35em 0' }, [
			E('input', {
				'type': 'radio', 'name': 'sbair-management-proto', 'value': value,
				'checked': proto === value ? '' : null,
				'change': function() { onChange('proto', value); }
			}), ' ' + label
		]);
	};
	var fallback = E('label', {}, [
		E('input', {
			'type': 'checkbox', 'checked': fallbackEnabled ? '' : null,
			'disabled': fallbackDisabled ? '' : null,
			'change': function(ev) { onChange('fallback_enabled', ev.target.checked); }
		}), ' DHCP取得不能時にFallbackを使用する'
	]);
	var rows = [
		inputRow('管理IP方式', E('div', {}, apDhcpEnabled
			? [ radio('dhcp', '上流ルーターから自動取得 (DHCP)'), radio('static', '固定IP') ]
			: [ radio('static', '固定IP（DHCPクライアントは安全フラグで無効化中）') ])),
		inputRow('固定IP', textInput(staticIp, staticDisabled,
			function(v) { onChange('ipaddr', v); }), '空欄なら純正設定の固定IPを継承します。'),
		inputRow('ネットマスク', textInput(staticNetmask, staticDisabled,
			function(v) { onChange('netmask', v); }), '空欄なら純正設定のネットマスクを継承します。'),
		inputRow('Gateway', textInput(draft.gateway !== undefined ? draft.gateway : config.gateway, staticDisabled,
			function(v) { onChange('gateway', v); }), '空欄なら純正設定を継承します。純正側に設定がなければ設定しません。'),
		inputRow('DNS', textInput(draft.dns !== undefined ? draft.dns : config.dns, staticDisabled,
			function(v) { onChange('dns', v); }), '空欄なら純正設定を継承します。純正側に設定がなければ設定しません。')
	];
	if (apDhcpEnabled) rows.push(
		inputRow('Fallback', fallback, 'DHCP失敗時だけ付与。ARP probeで競合を確認します'),
		inputRow('Fallback IP', textInput(draft.fallback_ip !== undefined ? draft.fallback_ip : config.fallback_ip, fallbackDisabled,
			function(v) { onChange('fallback_ip', v); })),
		inputRow('Fallback Netmask', textInput(draft.fallback_netmask !== undefined ? draft.fallback_netmask : config.fallback_netmask, fallbackDisabled,
			function(v) { onChange('fallback_netmask', v); })),
		inputRow('待機時間', E('input', {
			'class': 'cbi-input-text', 'type': 'number', 'min': '5', 'max': '3600',
			'value': valueOrDash(draft.fallback_timeout !== undefined ? draft.fallback_timeout : config.fallback_timeout),
			'disabled': fallbackDisabled ? '' : null,
			'change': function(ev) { onChange('fallback_timeout', parseInt(ev.target.value, 10) || 0); }
		}), '秒')
	);
	rows.push(
		inputRow('DHCP / IPv6', 'APモードではAir 6のDHCP・RA・DHCPv6・NDPを停止します。上流から来るIPv6は遮断しません。'),
		inputRow('Cellular WAN', 'APモードではルーティングに使用しません。モデム自体は停止しません。')
	);
	return sbair.section('AP / Bridge設定', [
		E('div', { 'class': 'alert-message warning' }, [
			E('strong', {}, '⚠ DHCPクライアント設定は非常に高いリスクがあります'),
			E('p', {}, 'ここで扱うのは、Air 6自身が上流ルーターから管理IPを取得するDHCPクライアント設定です。切り替えや適用に失敗すると、全てのネットワーク接続が失われ、ソフトブリックしてUART復旧が必要になるおそれがあります。'),
			E('p', {}, 'UARTなどの復旧手段を確保できない場合は、DHCPを選択・適用しないでください。Safe Applyの自動ロールバック機能も、あらゆる設定失敗からの復旧を保証するものではありません。')
		]),
		!apDhcpEnabled ? E('p', { 'class': 'alert-message notice' },
			'APモードのDHCPクライアントは安全フラグで無効化されています。固定IPでのみ適用します。') : '',
		sbair.table(rows),
		staticPreviewSection(config, draft, proto)
	]);
}

function modeSection(status, config, draft, selectedMode, detailsOpen, setMode, onChange, setDetailsOpen) {
	var managed = status.managed === true || status.managed === 1 || status.managed === '1';
	var pending = !!status.pending;
	var modeControls = [
		managed && selectedMode !== 'unmanaged'
			? E('p', {}, '切替はネットワークを再構成します。AP / Bridgeでは設定した管理IPへ切り替わります。')
			: E('div', { 'class': 'alert-message notice' }, [
				E('strong', {}, '未管理（既存設定）'),
				E('p', {}, managed
					? '選択して適用すると、現在のネットワーク設定を残したままsbairの管理だけを解除します。'
					: '現在のネットワーク設定を維持しています。AP / Bridgeを明示的に適用するまで変更しません。')
			]),
		E('label', { 'style': 'display:block;margin:.4em 0' }, [
			E('input', { 'type': 'radio', 'name': 'sbair-mode', 'value': 'unmanaged',
				'checked': selectedMode === 'unmanaged' ? '' : null, 'disabled': pending ? '' : null,
				'change': function() { setMode('unmanaged'); } }), ' デフォルト（無制御） — 現在の設定をそのまま使用'
		]),
		E('label', { 'style': 'display:block;margin:.4em 0' }, [
			E('input', { 'type': 'radio', 'name': 'sbair-mode', 'value': 'ap', 'checked': selectedMode === 'ap' ? '' : null,
				'disabled': pending ? '' : null,
				'change': function() { setMode('ap'); } }), ' AP / Bridge — br-lanを上流ネットワークへ接続'
		])
	];
	return sbair.section('接続モード設定（非推奨）', [
		sbair.softBrickWarning('netmode'),
		E('details', { 'class': 'sbair-netmode-advanced', 'open': detailsOpen ? '' : null,
			'toggle': function(ev) { setDetailsOpen(ev.target.open); } }, [
			E('summary', {}, '非推奨設定を表示（現在: ' + displayModeLabel(selectedMode) + '）'),
			E('div', {}, modeControls),
			configSection(config, draft, selectedMode, onChange)
		])
	]);
}

function pendingSection(pending, onConfirm, onRollback) {
	if (!pending) return '';
	return E('div', { 'class': 'cbi-section sbair-section' }, [
		E('h3', {}, '確認待ちのネットワーク変更'),
		E('p', {}, displayModeLabel(pending.mode) + ' を適用しました。実機側で正常性を確認できなかったため、残り ' + valueOrDash(pending.remaining) + ' 秒以内に手動で確定してください。'),
		E('button', { 'class': 'cbi-button cbi-button-positive', 'click': onConfirm }, 'この設定を確定'),
		' ',
		E('button', { 'class': 'cbi-button cbi-button-negative', 'click': onRollback }, 'ロールバック')
	]);
}

function page(data, draft, selectedMode, detailsOpen, handlers) {
	var status = data.status || {};
	var config = data.config || {};
	var managed = status.managed === true || status.managed === 1 || status.managed === '1';
	var pending = !!status.pending;
	if (status.error || config.error)
		return sbair.errorBox([ status.error || config.error ]);
	return [
		statusSection(status),
		warningSection(status.warnings),
		pendingSection(status.pending, handlers.confirm, handlers.rollback),
		modeSection(status, config, draft, selectedMode, detailsOpen, handlers.setMode, handlers.change, handlers.setDetailsOpen),
		E('div', { 'style': 'margin-bottom:1em' }, [
				E('button', { 'class': 'cbi-button cbi-button-action', 'click': handlers.apply,
					'disabled': (pending || (selectedMode === 'unmanaged' && !managed)) ? '' : null },
				selectedMode === 'unmanaged' && managed ? '管理を解除' : '変更を適用'), ' ',
			E('button', { 'class': 'cbi-button cbi-button-neutral', 'click': handlers.repair,
				'disabled': pending || !managed || selectedMode === 'unmanaged' ? '' : null }, '状態を補正'), ' ',
			E('button', { 'class': 'cbi-button cbi-button-neutral', 'click': handlers.reload }, '再読み込み')
		]),
		E('p', { 'style': 'opacity:.7' }, 'Wi-Fi設定はこの画面から変更しません。Vendor alias 172.16.255.254 (network.lan1) も保持します。')
	];
}

return view.extend({
	load: function() {
		return Promise.all([ callStatus(), callGetConfig() ]).then(function(values) {
			return { status: values[0], config: values[1] };
		}).catch(function(err) {
			return { status: { error: String(err) }, config: {} };
		});
	},

	render: function(data) {
		var self = this;
		self.data = data;
		self.draft = {};
		self.selectedMode = effectiveMode(data.status || {});
		self.detailsOpen = false;
		var container = E('div', {});

		function redraw() {
			dom.content(container, page(self.data, self.draft, self.selectedMode, self.detailsOpen, {
				setMode: function(mode) { self.selectedMode = mode; redraw(); },
				change: function(key, value) { self.draft[key] = value; redraw(); },
				setDetailsOpen: function(open) { self.detailsOpen = open; },
				reload: reload,
				repair: repair,
				apply: apply,
				confirm: confirmChange,
				rollback: rollbackChange
			}));
			if (self.data.status && self.data.status.pending && !pollTimer)
				pollTimer = setTimeout(function() { pollTimer = null; reload(); }, 2000);
		}

		function reload() {
			return Promise.all([ callStatus(), callGetConfig() ]).then(function(values) {
				self.data = { status: values[0], config: values[1] };
				self.draft = {};
				if (self.data.status.pending)
					self.selectedMode = self.data.status.pending.mode || self.selectedMode;
				else
					self.selectedMode = effectiveMode(self.data.status);
				redraw();
			}).catch(function(err) {
				ui.addNotification(null, E('p', {}, String(err)), 'warning');
			});
		}

		function apply() {
			var c = self.data.config || {};
			var d = self.draft;
			var status = self.data.status || {};
			var managed = status.managed === true || status.managed === 1 || status.managed === '1';
			if (self.selectedMode === 'unmanaged') {
				if (!managed) return;
				if (!confirm('現在のネットワーク設定を残したまま、sbairの管理だけを解除します。\n\nこの切替でも管理経路を失い、ソフトブリックして復旧にUARTが必要になるおそれがあります。続行しますか?'))
					return;
				callUnmanage().then(function(res) {
					if (res && res.error) throw new Error(res.error);
					ui.addNotification(null, E('p', {}, 'sbairの管理を解除しました。ネットワーク設定は変更していません。'), 'info');
					return reload();
				}).catch(function(err) { ui.addNotification(null, E('p', {}, String(err)), 'danger'); });
				return;
			}
			var apDhcpEnabled = flagEnabled(c.ap_dhcp_enabled);
			var proto = d.proto !== undefined ? d.proto : (c.proto || (apDhcpEnabled ? 'dhcp' : 'static'));
			var ipaddr = rawConfigValue(c, d, 'ipaddr');
			var netmask = rawConfigValue(c, d, 'netmask');
			var gateway = d.gateway !== undefined ? d.gateway : (c.gateway || '');
			var dns = d.dns !== undefined ? d.dns : (c.dns || '');
			if (self.selectedMode === 'ap' && !apDhcpEnabled) proto = 'static';
			var confirmation = (modeLabel[self.selectedMode] || self.selectedMode) + ' に切り替えます。\n\n' +
				'ソフトブリックして復旧にUARTが必要になるおそれがあります。\n' +
				'管理IPが変わり、120秒以内に確定しない場合は自動ロールバックしますが、復旧を保証するものではありません。';
			if (proto === 'static') confirmation += '\n\n' + staticPreviewText(c, d);
			if (!confirm(confirmation + '\n\n続行しますか?'))
				return;
			callApply(
				self.selectedMode,
				proto,
				ipaddr,
				netmask,
				gateway,
				dns,
				d.fallback_enabled !== undefined ? d.fallback_enabled : !!c.fallback_enabled,
				d.fallback_ip !== undefined ? d.fallback_ip : (c.fallback_ip || ''),
				d.fallback_netmask !== undefined ? d.fallback_netmask : (c.fallback_netmask || '255.255.255.0'),
				d.fallback_timeout !== undefined ? d.fallback_timeout : (c.fallback_timeout || 15),
				'',
				'',
				''
			).then(function(res) {
				if (res && res.error) throw new Error(res.error);
				ui.addNotification(null, E('p', {}, '適用を開始しました。実機の状態を確認し、問題がなければ自動確定します。'), 'info');
				return reload();
			}).catch(function(err) {
				ui.addNotification(null, E('p', {}, String(err)), 'danger');
			});
		}

		function confirmChange() {
			callConfirm().then(function(res) {
				if (res && res.error) throw new Error(res.error);
				ui.addNotification(null, E('p', {}, '設定を確定しました。'), 'info');
				return reload();
			}).catch(function(err) { ui.addNotification(null, E('p', {}, String(err)), 'danger'); });
		}

		function rollbackChange() {
			if (!confirm('保留中の変更を取り消して以前の設定へ戻しますか?')) return;
			callRollback().then(function(res) {
				if (res && res.error) throw new Error(res.error);
				return reload();
			}).catch(function(err) { ui.addNotification(null, E('p', {}, String(err)), 'danger'); });
		}

		function repair() {
			callRepair().then(function(res) {
				if (res && res.error) throw new Error(res.error);
				ui.addNotification(null, E('p', {}, 'DHCP / 経路状態を確認・補正しました。'), 'info');
				return reload();
			}).catch(function(err) { ui.addNotification(null, E('p', {}, String(err)), 'danger'); });
		}

		redraw();
		return E('div', { 'class': 'cbi-map' }, [ container ]);
	},

	handleSave: null,
	handleSaveApply: null,
	handleReset: null
});
