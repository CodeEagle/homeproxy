'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const test = require('node:test');

const { extractUcodeFunctions } = require('./helpers/extract-ucode-functions');

const source = fs.readFileSync(
	path.join(__dirname, '..', 'root/etc/homeproxy-ce/scripts/update_subscriptions.uc'),
	'utf8'
);

function plain(value) {
	return JSON.parse(JSON.stringify(value));
}

function createUci(sections) {
	const state = sections.map((section) => ({
		...section,
		outbounds: section.outbounds ? [...section.outbounds] : section.outbounds,
		main_urltest_nodes: section.main_urltest_nodes ? [...section.main_urltest_nodes] : undefined,
		main_udp_urltest_nodes: section.main_udp_urltest_nodes
			? [...section.main_udp_urltest_nodes]
			: undefined
	}));
	const calls = { set: [], delete: [] };

	return {
		calls,
		foreach(config, type, callback) {
			for (const section of state) {
				if (section['.type'] === type)
					callback(section);
			}
		},
		get(config, section, option) {
			const target = state.find((entry) => entry['.name'] === section);
			return option === undefined ? target : target?.[option];
		},
		set(config, section, option, value) {
			const target = state.find((entry) => entry['.name'] === section);
			calls.set.push([config, section, option, value]);
			target[option] = Array.isArray(value) ? [...value] : value;
		},
		delete(config, section, option) {
			const target = state.find((entry) => entry['.name'] === section);
			calls.delete.push([config, section, option]);
			delete target[option];
		},
		section(name) {
			return state.find((entry) => entry['.name'] === name);
		}
	};
}

test('removes deleted nodes from groups without deleting groups or inventing direct-out', () => {
	const uci = createUci([
		{
			'.name': 'config',
			'.type': 'config',
			main_urltest_nodes: ['n1', 'n2'],
			main_udp_urltest_nodes: ['n1']
		},
		{
			'.name': 'legacy-route-test',
			'.type': 'routing_node',
			node: 'urltest',
			urltest_nodes: ['n1', 'n2']
		},
		{ '.name': 'n1', '.type': 'node', type: 'vless', label: 'Hong Kong' },
		{ '.name': 'n2', '.type': 'node', type: 'trojan', label: 'Los Angeles' },
		{
			'.name': 'selector',
			'.type': 'node',
			type: 'selector',
			label: 'Manual',
			outbounds: ['n1', 'n2'],
			default: 'n1'
		},
		{
			'.name': 'empty',
			'.type': 'node',
			type: 'urltest',
			label: 'Auto',
			outbounds: ['n1'],
			default: 'n1'
		},
		{
			'.name': 'default-only',
			'.type': 'node',
			type: 'selector',
			label: 'Default only',
			outbounds: ['n2'],
			default: 'n1'
		}
	]);
	const logs = [];
	const { cleanRemovedNodeReferences } = extractUcodeFunctions(
		source,
		['cleanRemovedNodeReferences'],
		{ length: (value) => value.length, log: (...args) => logs.push(args.join(' ')) }
	);

	const result = cleanRemovedNodeReferences(uci, 'homeproxy-ce', ['n1']);

	assert.deepEqual(plain(uci.section('selector').outbounds), ['n2']);
	assert.equal(uci.section('selector').default, undefined);
	assert.deepEqual(plain(uci.section('empty').outbounds), []);
	assert.equal(uci.section('empty').default, undefined);
	assert.ok(uci.section('selector'));
	assert.ok(uci.section('empty'));
	assert.deepEqual(plain(result.changed_groups), ['selector', 'empty', 'default-only']);
	assert.deepEqual(plain(result.empty_groups), ['empty']);
	assert.match(logs.join('\n'), /empty.*Auto/);
	assert.equal(uci.calls.set.some((call) => call[3] === 'direct-out'), false);
	assert.deepEqual(plain(uci.section('config').main_urltest_nodes), ['n2']);
	assert.deepEqual(plain(uci.section('config').main_udp_urltest_nodes), []);
	assert.deepEqual(plain(uci.section('legacy-route-test').urltest_nodes), ['n2']);
	assert.deepEqual(plain(uci.calls.delete), [
		['homeproxy-ce', 'selector', 'default'],
		['homeproxy-ce', 'empty', 'default'],
		['homeproxy-ce', 'default-only', 'default']
	]);
	assert.deepEqual(plain(uci.calls.set), [
		['homeproxy-ce', 'config', 'main_urltest_nodes', ['n2']],
		['homeproxy-ce', 'config', 'main_udp_urltest_nodes', []],
		['homeproxy-ce', 'legacy-route-test', 'urltest_nodes', ['n2']],
		['homeproxy-ce', 'selector', 'outbounds', ['n2']],
		['homeproxy-ce', 'empty', 'outbounds', []]
	]);
});

test('leaves ordinary nodes and groups without removed members untouched', () => {
	const uci = createUci([
		{ '.name': 'n1', '.type': 'node', type: 'vless', label: 'Hong Kong' },
		{ '.name': 'n2', '.type': 'node', type: 'trojan', label: 'Los Angeles' },
		{
			'.name': 'selector',
			'.type': 'node',
			type: 'selector',
			label: 'Manual',
			outbounds: ['n2'],
			default: 'n2'
		}
	]);
	const { cleanRemovedNodeReferences } = extractUcodeFunctions(
		source,
		['cleanRemovedNodeReferences'],
		{ length: (value) => value.length, log: () => {} }
	);

	const result = cleanRemovedNodeReferences(uci, 'homeproxy-ce', ['gone']);

	assert.deepEqual(plain(uci.section('selector').outbounds), ['n2']);
	assert.equal(uci.section('selector').default, 'n2');
	assert.deepEqual(plain(result), { changed_groups: [], empty_groups: [] });
	assert.deepEqual(plain(uci.calls.set), []);
	assert.deepEqual(plain(uci.calls.delete), []);
	assert.deepEqual(plain(uci.section('n1')), {
		'.name': 'n1', '.type': 'node', type: 'vless', label: 'Hong Kong'
	});
});
