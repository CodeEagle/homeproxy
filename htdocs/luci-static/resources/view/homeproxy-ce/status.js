/*
 * SPDX-License-Identifier: GPL-2.0-only
 *
 * Copyright (C) 2022-2025 ImmortalWrt.org
 */

'use strict';
'require dom';
'require form';
'require fs';
'require poll';
'require rpc';
'require uci';
'require ui';
'require view';

/* Thanks to luci-app-aria2 */
const css = '				\
#log_textarea {				\
	padding: 10px;			\
	text-align: left;		\
}					\
#log_textarea pre {			\
	padding: .5rem;			\
	word-break: break-all;		\
	margin: 0;			\
}					\
.description {				\
	background-color: #33ccff;	\
}';

const hp_dir = '/var/run/homeproxy-ce';

const callServiceList = rpc.declare({
	object: 'service',
	method: 'list',
	params: ['name'],
	expect: { '': {} }
});

const callServiceAction = rpc.declare({
	object: 'luci.homeproxyce',
	method: 'service_action',
	params: ['action'],
	expect: { '': {} }
});

const callConfigExport = rpc.declare({
	object: 'luci.homeproxyce',
	method: 'config_export',
	expect: { '': {} }
});

const callConfigImport = rpc.declare({
	object: 'luci.homeproxyce',
	method: 'config_import',
	expect: { '': {} }
});

const callConfigImportFromHomeProxy = rpc.declare({
	object: 'luci.homeproxyce',
	method: 'config_import_from_homeproxy',
	expect: { '': {} }
});

function getServiceStatus() {
	return L.resolveDefault(callServiceList('homeproxy-ce'), {}).then((res) => {
		let isRunning = false;
		try {
			isRunning = res['homeproxy-ce']['instances']['sing-box-c']['running'] ||
				res['homeproxy-ce']['instances']['sing-box-s']['running'];
		} catch (e) { }
		return isRunning;
	});
}

function renderServiceStatus(isRunning) {
	let spanTemp = '<em><span style="color:%s"><strong>%s %s</strong></span></em>';

	return isRunning
		? spanTemp.format('green', _('HomeProxy CE'), _('RUNNING'))
		: spanTemp.format('red', _('HomeProxy CE'), _('NOT RUNNING'));
}

function renderServiceControl(o) {
	o.default = E('div', { 'style': 'cbi-value-field' }, [
		E('button', {
			'class': 'btn cbi-button cbi-button-apply',
			'click': ui.createHandlerFn(this, () => {
				return L.resolveDefault(callServiceAction('start'), {}).then(() => o.map.reset());
			})
		}, [ _('Start') ]),
		' ',
		E('button', {
			'class': 'btn cbi-button cbi-button-reset',
			'click': ui.createHandlerFn(this, () => {
				return L.resolveDefault(callServiceAction('stop'), {}).then(() => o.map.reset());
			})
		}, [ _('Stop') ])
	]);
}

function downloadBackup(filename, content) {
	const bytes = Uint8Array.from(atob(content), (c) => c.charCodeAt(0));
	const blob = new Blob([bytes], { type: 'application/gzip' });
	const url = URL.createObjectURL(blob);
	const link = E('a', { href: url, download: filename });
	document.body.appendChild(link);
	link.click();
	link.remove();
	setTimeout(() => URL.revokeObjectURL(url), 1000);
}

function renderConfigActions(o) {
	const fileInput = E('input', {
		type: 'file',
		accept: '.tar.gz,.tgz,application/gzip,application/x-gzip',
		style: 'display:none',
		change: ui.createHandlerFn(this, (ev) => {
			return ui.uploadFile('/tmp/homeproxy-ce-backup.tar.gz', ev.target).then(() => {
				return L.resolveDefault(callConfigImport(), {}).then((res) => {
					if (res.result === true)
						ui.addNotification(null, E('p', _('Successfully imported homeproxy-ce configuration.')));
					else
						ui.addNotification(null, E('p', _('Failed to import homeproxy-ce configuration: %s').format(res.error || _('Unknown error.'))));

					return o.map.reset();
				});
			}).catch((e) => ui.addNotification(null, E('p', e.message)));
		})
	});

	o.default = E('div', { 'style': 'cbi-value-field' }, [
		E('button', {
			'class': 'btn cbi-button cbi-button-action',
			'click': ui.createHandlerFn(this, () => {
				return L.resolveDefault(callConfigImportFromHomeProxy(), {}).then((res) => {
					if (res.result === true)
						ui.addNotification(null, E('p', _('Successfully imported configuration from HomeProxy.')));
					else
						ui.addNotification(null, E('p', _('Failed to import configuration from HomeProxy: %s').format(res.error || _('Unknown error.'))));

					return o.map.reset();
				});
			})
		}, [ _('Import from HomeProxy') ]),
		' ',
		E('button', {
			'class': 'btn cbi-button cbi-button-action',
			'click': ui.createHandlerFn(this, () => {
				return L.resolveDefault(callConfigExport(), {}).then((res) => {
					if (res.result === true && res.content)
						downloadBackup(res.filename, res.content);
					else
						ui.addNotification(null, E('p', _('Failed to export homeproxy-ce configuration.')));
				});
			})
		}, [ _('Export') ]),
		' ',
		E('button', {
			'class': 'btn cbi-button cbi-button-action',
			'click': ui.createHandlerFn(this, () => fileInput.click())
		}, [ _('Import') ]),
		fileInput
	]);
}

function getConnStat(o, site) {
	const callConnStat = rpc.declare({
		object: 'luci.homeproxyce',
		method: 'connection_check',
		params: ['site'],
		expect: { '': {} }
	});

	o.default = E('div', { 'style': 'cbi-value-field' }, [
		E('button', {
			'class': 'btn cbi-button cbi-button-action',
			'click': ui.createHandlerFn(this, () => {
				return L.resolveDefault(callConnStat(site), {}).then((ret) => {
                                        let ele = o.default.firstElementChild.nextElementSibling;
					if (ret.result) {
						ele.style.setProperty('color', 'green');
                                                ele.innerHTML = _('passed');
					} else {
						ele.style.setProperty('color', 'red');
                                                ele.innerHTML = _('failed');
					}
				});
			})
		}, [ _('Check') ]),
		' ',
		E('strong', { 'style': 'color:gray' }, _('unchecked')),
	]);
}

function getResVersion(o, type) {
	const callResVersion = rpc.declare({
		object: 'luci.homeproxyce',
		method: 'resources_get_version',
		params: ['type'],
		expect: { '': {} }
	});

	const callResUpdate = rpc.declare({
		object: 'luci.homeproxyce',
		method: 'resources_update',
		params: ['type'],
		expect: { '': {} }
	});

	return L.resolveDefault(callResVersion(type), {}).then((res) => {
		let spanTemp = E('div', { 'style': 'cbi-value-field' }, [
			E('button', {
				'class': 'btn cbi-button cbi-button-action',
				'click': ui.createHandlerFn(this, () => {
					return L.resolveDefault(callResUpdate(type), {}).then((res) => {
						switch (res.status) {
						case 0:
							o.description = _('Successfully updated.');
							break;
						case 1:
							o.description = _('Update failed.');
							break;
						case 2:
							o.description = _('Already in updating.');
							break;
						case 3:
							o.description = _('Already at the latest version.');
							break;
						default:
							o.description = _('Unknown error.');
							break;
						}

						return o.map.reset();
					});
				})
			}, [ _('Check update') ]),
			' ',
			E('strong', { 'style': (res.error ? 'color:red' : 'color:green') },
				[ res.error ? 'not found' : res.version ]
			),
		]);

		o.default = spanTemp;
	});
}

function getRuntimeLog(o, name, _option_index, section_id, _in_table) {
	const filename = o.option.split('_')[1];

	let section, log_level_el;
	switch (filename) {
	case 'homeproxy':
		section = null;
		break;
	case 'sing-box-c':
		section = 'config';
		break;
	case 'sing-box-s':
		section = 'server';
		break;
	}

	if (section) {
		const selected = uci.get('homeproxy-ce', section, 'log_level') || 'warn';
		const choices = {
			trace: _('Trace'),
			debug: _('Debug'),
			info: _('Info'),
			warn: _('Warn'),
			error: _('Error'),
			fatal: _('Fatal'),
			panic: _('Panic')
		};

		log_level_el = E('select', {
			'id': o.cbid(section_id),
			'class': 'cbi-input-select',
			'style': 'margin-left: 4px; width: 6em;',
			'change': ui.createHandlerFn(this, (ev) => {
				uci.set('homeproxy-ce', section, 'log_level', ev.target.value);
				return o.map.save(null, true).then(() => {
					ui.changes.apply(true);
				});
			})
		});

		Object.keys(choices).forEach((v) => {
			log_level_el.appendChild(E('option', {
				'value': v,
				'selected': (v === selected) ? '' : null
			}, [ choices[v] ]));
		});
	}

	const callLogClean = rpc.declare({
		object: 'luci.homeproxyce',
		method: 'log_clean',
		params: ['type'],
		expect: { '': {} }
	});

	const log_textarea = E('div', { 'id': 'log_textarea' },
		E('img', {
			'src': L.resource('icons/loading.svg'),
			'alt': _('Loading'),
			'style': 'vertical-align:middle'
		}, _('Collecting data...'))
	);

	let log;
	poll.add(L.bind(() => {
		return fs.read_direct(String.format('%s/%s.log', hp_dir, filename), 'text')
		.then((res) => {
			log = E('pre', { 'wrap': 'pre' }, [
				res.trim() || _('Log is empty.')
			]);

			dom.content(log_textarea, log);
		}).catch((err) => {
			if (err.toString().includes('NotFoundError'))
				log = E('pre', { 'wrap': 'pre' }, [
					_('Log file does not exist.')
				]);
			else
				log = E('pre', { 'wrap': 'pre' }, [
					_('Unknown error: %s').format(err)
				]);

			dom.content(log_textarea, log);
		});
	}));

	return E([
		E('style', [ css ]),
		E('div', {'class': 'cbi-map'}, [
			E('h3', {'name': 'content', 'style': 'align-items: center; display: flex;'}, [
				_('%s log').format(name),
				log_level_el || '',
				E('button', {
					'class': 'btn cbi-button cbi-button-action',
					'style': 'margin-left: 4px;',
					'click': ui.createHandlerFn(this, () => {
						return L.resolveDefault(callLogClean(filename), {});
					})
				}, [ _('Clean log') ])
			]),
			E('div', {'class': 'cbi-section'}, [
				log_textarea,
				E('div', {'style': 'text-align:right'},
					E('small', {}, _('Refresh every %s seconds.').format(L.env.pollinterval))
				)
			])
		])
	]);
}

return view.extend({
	render() {
		let m, s, o;

		m = new form.Map('homeproxy-ce');

		s = m.section(form.TypedSection);
		s.render = function() {
			poll.add(() => {
				return L.resolveDefault(getServiceStatus()).then((res) => {
					let view = document.getElementById('service_status');
					if (view)
						view.innerHTML = renderServiceStatus(res);
				});
			});

			return E('div', { class: 'cbi-section', id: 'status_bar' }, [
				E('p', { id: 'service_status' }, _('Collecting data...'))
			]);
		};

		s = m.section(form.NamedSection, 'config', 'homeproxy', _('Service control'));
		s.anonymous = true;

		o = s.option(form.DummyValue, '_service_control', _('Service actions'));
		o.cfgvalue = L.bind(renderServiceControl, this, o);

		o = s.option(form.DummyValue, '_config_actions', _('Configuration'));
		o.cfgvalue = L.bind(renderConfigActions, this, o);

		s = m.section(form.NamedSection, 'config', 'homeproxy', _('Connection check'));
		s.anonymous = true;

		o = s.option(form.DummyValue, '_check_baidu', _('BaiDu'));
		o.cfgvalue = L.bind(getConnStat, this, o, 'baidu');

		o = s.option(form.DummyValue, '_check_google', _('Google'));
		o.cfgvalue = L.bind(getConnStat, this, o, 'google');

		s = m.section(form.NamedSection, 'config', 'homeproxy', _('Resources management'));
		s.anonymous = true;

		o = s.option(form.DummyValue, '_china_ip4_version', _('China IPv4 list version'));
		o.cfgvalue = L.bind(getResVersion, this, o, 'china_ip4');
		o.rawhtml = true;

		o = s.option(form.DummyValue, '_china_ip6_version', _('China IPv6 list version'));
		o.cfgvalue = L.bind(getResVersion, this, o, 'china_ip6');
		o.rawhtml = true;

		o = s.option(form.DummyValue, '_china_list_version', _('China list version'));
		o.cfgvalue = L.bind(getResVersion, this, o, 'china_list');
		o.rawhtml = true;

		o = s.option(form.DummyValue, '_gfw_list_version', _('GFW list version'));
		o.cfgvalue = L.bind(getResVersion, this, o, 'gfw_list');
		o.rawhtml = true;

		o = s.option(form.Value, 'github_token', _('GitHub token'));
		o.password = true;
		o.renderWidget = function() {
			let node = form.Value.prototype.renderWidget.apply(this, arguments);

			(node.querySelector('.control-group') || node).appendChild(E('button', {
				'class': 'cbi-button cbi-button-apply',
				'title': _('Save'),
				'click': ui.createHandlerFn(this, () => {
					return this.map.save(null, true).then(() => {
						ui.changes.apply(true);
					});
				}, this.option)
			}, [ _('Save') ]));

			return node;
		}

		s = m.section(form.NamedSection, 'config', 'homeproxy');
		s.anonymous = true;

		o = s.option(form.DummyValue, '_homeproxy_logview');
		o.render = L.bind(getRuntimeLog, this, o, _('HomeProxy'));

		o = s.option(form.DummyValue, '_sing-box-c_logview');
		o.render = L.bind(getRuntimeLog, this, o, _('sing-box client'));

		o = s.option(form.DummyValue, '_sing-box-s_logview');
		o.render = L.bind(getRuntimeLog, this, o, _('sing-box server'));

		return m.render();
	},

	handleSaveApply: null,
	handleSave: null,
	handleReset: null
});
