// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Floop3

// USB Host inventory is intentionally read-only. Driver installation/removal is
// shown only as a disabled capability until a kernel-matched app bundle exists.

'use strict';
'require view';
'require rpc';
'require ui';
'require dom';
'require tools.sbair as sbair';

var callStatus = rpc.declare({ object: 'sbair', method: 'usb_status' });
var callNICStatus = rpc.declare({ object: 'sbair', method: 'usb_nic_status' });
var callNICEnable = rpc.declare({ object: 'sbair', method: 'usb_nic_enable', params: [ 'ack' ] });
var callNICDisable = rpc.declare({ object: 'sbair', method: 'usb_nic_disable' });

function valueOrDash(value) {
	return value === undefined || value === null || value === '' ? '-' : String(value);
}

function speed(value) {
	value = valueOrDash(value);
	return value === '-' || value === 'unknown' ? value : value + ' Mbps';
}

function list(value) {
	return value && value.length ? value.join(', ') : '-';
}

function interfaceRows(interfaces) {
	var rows = [ E('tr', { 'class': 'tr table-titles' }, [
		E('th', { 'class': 'th' }, 'interface'),
		E('th', { 'class': 'th' }, 'class / subclass / protocol'),
		E('th', { 'class': 'th' }, 'driver'),
		E('th', { 'class': 'th' }, 'netdev'),
		E('th', { 'class': 'th' }, 'block device'),
		E('th', { 'class': 'th' }, 'modalias')
	]) ];
	(interfaces || []).forEach(function(iface) {
		rows.push(E('tr', { 'class': 'tr' }, [
			E('td', { 'class': 'td left' }, valueOrDash(iface.name)),
			E('td', { 'class': 'td left' }, [
				valueOrDash(iface.class), ' / ', valueOrDash(iface.subclass), ' / ', valueOrDash(iface.protocol)
			]),
			E('td', { 'class': 'td left' }, valueOrDash(iface.driver)),
			E('td', { 'class': 'td left' }, list(iface.netdevs)),
			E('td', { 'class': 'td left' }, list(iface.block_devices)),
			E('td', { 'class': 'td left' }, valueOrDash(iface.modalias))
		]));
	});
	return rows;
}

function driverSection(device) {
	var plan = device.driver_management || {};
	var disabledReason = valueOrDash(plan.reason);
	return sbair.section('USB Hostドライバ管理（読み取り専用）', [ sbair.table([
		sbair.row('判定対象', plan.device_class_allowed ? '既知のUSB Host Ethernet候補' : '対象外 / 未確定'),
		sbair.row('Provenance', valueOrDash(plan.provenance)),
		sbair.row('期待ドライバ', valueOrDash(plan.expected_driver)),
		sbair.row('bundle', plan.bundle_available ? 'あり' : 'なし'),
		sbair.row('理由', disabledReason),
		E('tr', { 'class': 'tr' }, [
			E('td', { 'class': 'td left' }, '操作'),
			E('td', { 'class': 'td left' }, [
				E('button', { 'class': 'cbi-button cbi-button-neutral', 'disabled': '' }, 'インストール'), ' ',
				E('button', { 'class': 'cbi-button cbi-button-neutral', 'disabled': '' }, '削除'),
				E('p', { 'style': 'opacity:.7;margin:.3em 0 0' }, 'USB Host側のアプリ管理bundleのみ操作対象。現在はbundle未提供のため無効です。')
			])
		]) ])
	]);
}

function deviceSection(device) {
	return sbair.section(valueOrDash(device.name) + ' — ' + valueOrDash(device.kind), [
		sbair.table([
			sbair.row('VID:PID', valueOrDash(device.vid_pid)),
			sbair.row('メーカー / 製品', valueOrDash(device.manufacturer) + ' / ' + valueOrDash(device.product)),
			sbair.row('USB speed', speed(device.bus_speed)),
			sbair.row('bcdUSB / device class', valueOrDash(device.bcd_usb) + ' / ' + valueOrDash(device.device_class)),
			sbair.row('parent / sysfs', valueOrDash(device.parent) + ' / ' + valueOrDash(device.sysfs_path)),
			sbair.row('driver', valueOrDash(device.driver)),
			sbair.row('network candidate', device.network_candidate ? 'yes' : 'no')
		]),
		device.interfaces && device.interfaces.length
			? sbair.table(interfaceRows(device.interfaces))
			: E('p', {}, 'USB interfaceは未検出'),
		driverSection(device)
	]);
}

function nicValue(value) {
	return value === undefined || value === null || value === '' ? '-' : String(value);
}

function nicState(nic) {
	return nic && nic.state ? nic.state : 'unknown';
}

function nicDisplay(kind, state) {
	var labels = {
		bundle: { missing: '未導入', installed: '導入済み / 無効', 'invalid-hash': '導入済みだが検証失敗' },
		profile: { missing: '未設定', invalid: '不正', valid: '有効' },
		runtime: { disabled: '導入済み / 無効', active: '有効', 'preflight-ng': 'Preflight NG', 'rollback-required': 'Rollback required' },
		preflight: { ok: 'Preflight OK', ng: 'Preflight NG' }
	};
	return labels[kind] && labels[kind][state] ? labels[kind][state] : nicValue(state);
}

function usbNICSection(nic, reload) {
	nic = nic || {};
	var driver = nic.driver || {};
	var udc = nic.udc || {};
	var profile = nic.profile || {};
	var runtime = nic.runtime || {};
	var usb0 = nic.usb0 || {};
	var preflight = nic.preflight || {};
	var bundleState = nicState(nic.bundle);
	var profileState = nicState(profile);
	var preflightState = nicState(preflight);
	var runtimeState = nicState(runtime);
	var bundleReason = nic.bundle && nic.bundle.reason && nic.bundle.reason !== 'ok'
		? ' (' + nic.bundle.reason + ')' : '';
	var acknowledgements = [ false, false, false ];
	var enableButton;

	var warning = E('div', { 'style': 'border:2px solid #d9534f;padding:.8em;margin-bottom:1em' }, [
		E('strong', {}, '⚠ 実験的・高リスク機能'),
		E('p', { 'style': 'margin:.5em 0 0' },
			'USB UDC / ConfigFSの所有状態を変更し、Air6をUSB CDC-NCM gadgetとして動作させます。' +
			'USB側を管理経路として仮定せず、別のLANまたはWi-Fi管理経路とUART等の復旧手段を確保してください。'),
		E('p', { 'style': 'margin:.5em 0 0' },
			'USBホスト機器を切断してから操作してください。LAN/WAN、br-lan、DHCP、Wi-Fi、firewallは自動変更せず、' +
			'起動時の自動有効化も行いません。')
	]);

	var rows = [
		sbair.row('Bundle', nicDisplay('bundle', bundleState) + bundleReason),
		sbair.row('Support level', nicValue(nic.support_level || driver.support_level)),
		sbair.row('Kernel', nicValue(nic.kernel || driver.kernel)),
		sbair.row('Architecture', nicValue(nic.architecture || driver.architecture)),
		sbair.row('Driver SHA256', nicValue(nic.driver_sha256 || driver.sha256)),
		sbair.row('Driver vermagic', nicValue(nic.driver_vermagic || driver.vermagic)),
		sbair.row('License', nicValue(nic.license || driver.license)),
		sbair.row('Upstream revision', nicValue(nic.upstream_revision || driver.upstream_revision)),
		sbair.row('UDC', nicValue(udc.name)),
		sbair.row('UDC state / speed', nicValue(udc.state) + ' / ' + nicValue(udc.current_speed)),
		sbair.row('UDC binding', nicValue(udc.bound_gadget)),
		sbair.row('Loaded USB modules', nicValue(nic.loaded_usb_modules)),
		sbair.row('Activation profile', nicDisplay('profile', profileState) + ' (' + nicValue(profile.path) + ')'),
		sbair.row('Runtime', nicDisplay('runtime', runtimeState)),
		sbair.row('usb0', nicValue(usb0.state) + ' / carrier: ' + nicValue(usb0.carrier)),
		sbair.row('Management path', nicValue(nic.management_path)),
		sbair.row('Preflight', nicDisplay('preflight', preflightState) + (preflight.reason ? ' (' + preflight.reason + ')' : ''))
	];

	var reason = '';
	if (bundleState !== 'installed')
		reason = '固定SHA256/vermagicを満たすbundleが導入されていません。';
	else if (profileState !== 'valid')
		reason = 'レビュー済みactivation profileが無いか不正です' + (profile.reason ? ' (' + profile.reason + ')' : '') + '。値を推測して有効化することはできません。';
	else if (preflightState !== 'ok')
		reason = 'read-only preflightが未完了または失敗しています: ' + nicValue(preflight.reason);
	else
		reason = 'Enable前に、下の3項目をすべて確認してください。';

	var checks = [
		'USB UDC / ConfigFSを変更する実験的機能であることを理解しました',
		'LANまたはWi-Fiの独立した管理経路を確保しています',
		'USBホストを切断し、物理的な復旧手段を確保しています'
	].map(function(label, index) {
		return E('label', { 'style': 'display:block;margin:.4em 0' }, [
			E('input', { 'type': 'checkbox', 'class': 'cbi-input-checkbox', 'change': function(ev) {
				acknowledgements[index] = !!ev.target.checked;
				if (enableButton)
					enableButton.disabled = !canEnable();
			} }),
			' ', label
		]);
	});

	function canEnable() {
		return bundleState === 'installed' && profileState === 'valid' && preflightState === 'ok' &&
			acknowledgements[0] && acknowledgements[1] && acknowledgements[2];
	}

	enableButton = E('button', {
		'class': 'cbi-button cbi-button-action',
		'disabled': canEnable() ? null : '',
		'click': function() {
			if (!canEnable() || !confirm('USB UDC / ConfigFSを変更します。独立した管理経路を確保していますか？'))
				return;
			return callNICEnable(true).then(function(res) {
				if (res && res.error)
					ui.addNotification(null, E('p', {}, String(res.error)), 'error');
				return reload ? reload() : res;
			}).catch(function(err) {
				ui.addNotification(null, E('p', {}, String(err)), 'error');
			});
		}
	}, 'Enable（明示的に有効化）');

	var disableButton = E('button', {
		'class': 'cbi-button cbi-button-warning',
		'disabled': runtimeState === 'active' ? null : '',
		'click': function() {
			if (!confirm('USB Gadgetを無効化し、専用ConfigFS topologyを削除しますか？'))
				return;
			return callNICDisable().then(function(res) {
				if (res && res.error)
					ui.addNotification(null, E('p', {}, String(res.error)), 'error');
				return reload ? reload() : res;
			}).catch(function(err) {
				ui.addNotification(null, E('p', {}, String(err)), 'error');
			});
		}
	}, 'Disable（限定rollback）');

	return sbair.section('USB Gadget（CDC-NCM NIC）', [
		warning,
		sbair.table(rows),
		E('p', { 'style': 'opacity:.8' }, reason),
		E('div', { 'style': 'margin:.8em 0' }, checks),
		E('div', {}, [ enableButton, ' ', disableButton ]),
		E('p', { 'style': 'font-size:90%;opacity:.75' },
			'候補v1はupstreamのlive-validated binaryですが、source/binary対応はB2 provenance扱いで新規用途には非推奨です。')
	]);
}

function safeNICStatus() {
	return callNICStatus().then(function(res) {
		if (res && res.error)
			return { result: 'ok', bundle: { state: 'missing' }, preflight: { state: 'ng', reason: 'helper-unavailable' } };
		return res;
	}).catch(function() {
		return { result: 'ok', bundle: { state: 'missing' }, preflight: { state: 'ng', reason: 'rpc-unavailable' } };
	});
}

function render(data, reload) {
	data = data || {};
	var inventory = data.inventory || data;
	var nic = data.usb_nic || {};
	if (inventory.error)
		return [ sbair.errorBox([ inventory.error ]) ];

	var devices = inventory.usb_devices || [];
	var controllers = inventory.usb_controllers || [];
	var controllerRows = [ E('tr', { 'class': 'tr table-titles' }, [
		E('th', { 'class': 'th' }, 'USB bus / root hub'),
		E('th', { 'class': 'th' }, 'driver'),
		E('th', { 'class': 'th' }, 'reported speed')
	]) ];
	controllers.forEach(function(controller) {
		controllerRows.push(E('tr', { 'class': 'tr' }, [
			E('td', { 'class': 'td left' }, valueOrDash(controller.name)),
			E('td', { 'class': 'td left' }, valueOrDash(controller.driver)),
			E('td', { 'class': 'td left' }, speed(controller.bus_speed))
		]));
	});

	var body = [ E('p', { 'style': 'opacity:.8' },
		'USB Host（Air 6に接続された機器）として、hub、storage、serial、vendor-specific、unknownを含む全USB device/interfaceを表示します。' +
		'USB Host Ethernetのドライバ導入とbridge/WAN/LAN割り当ては別機能であり、この画面から変更しません。USB Gadget機能は下の別セクションで扱います。') ];
	body.push(controllers.length
		? sbair.section('USB Host buses / root hubs', [ sbair.table(controllerRows) ])
		: E('p', {}, 'USB busは未検出'));
	if (devices.length)
		body = body.concat(devices.map(deviceSection));
	else
		body.push(E('p', {}, 'USB deviceは未検出'));
	body.push(usbNICSection(nic, reload));
	return body;
}

return view.extend({
	load: function() {
		return Promise.all([
			callStatus().catch(function(err) { return { error: String(err) }; }),
			safeNICStatus()
		]).then(function(values) {
			return { inventory: values[0], usb_nic: values[1] };
		});
	},

	render: function(data) {
		var self = this;
		self.data = data;
		var container;
		var reload = function() {
			return Promise.all([
				callStatus(),
				safeNICStatus()
			]).then(function(values) {
				self.data = { inventory: values[0], usb_nic: values[1] };
				dom.content(container, render(self.data, reload));
			}).catch(function(err) {
				ui.addNotification(null, E('p', {}, String(err)), 'warning');
			});
		};
		container = E('div', {}, render(data, reload));
		return E('div', { 'class': 'cbi-map' }, [
			E('div', { 'style': 'margin-bottom:1em' }, [
				E('button', { 'class': 'cbi-button cbi-button-neutral', 'click': ui.createHandlerFn(this, reload) }, '再読み込み')
			]),
			container
		]);
	},

	handleSave: null,
	handleSaveApply: null,
	handleReset: null
});
