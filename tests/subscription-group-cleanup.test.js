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
			return option === undefined ? target?.['.type'] : target?.[option];
		},
		get_all(config, section) {
			return state.find((entry) => entry['.name'] === section);
		},
		set(config, section, option, value) {
			if (Array.isArray(value) && value.length === 0)
				throw new Error('uci.set rejects empty lists');
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

function extractSubscriptionMatcher() {
	return extractUcodeFunctions(
		source,
		[
			'subscriptionNodeValueEqual',
			'sameSubscriptionNode',
			'subscriptionNodeChanged',
			'findSubscriptionNode',
			'subscriptionNodeSectionId',
			'subscriptionCacheAvailable'
		],
		{
			isEmpty: (value) => value === undefined || value === null || value === '' ||
				(typeof value === 'object' && value !== null && Object.keys(value).length === 0),
			type: (value) => Array.isArray(value) ? 'array' : typeof value,
			length: (value) => value.length,
			sprintf: (format, value) => String(value),
			md5hex: (value) => `hash-${value}`
		}
	);
}

function extractSubscriptionGroupSync() {
	return extractUcodeFunctions(
		source,
		[
			'subscriptionList',
			'subscriptionNodeMatchesFamily',
			'syncSubscriptionGroupMembers',
			'findEmptySubscriptionGroups'
		],
		{
			isEmpty: (value) => value === undefined || value === null || value === '',
			type: (value) => Array.isArray(value) ? 'array' : typeof value,
			length: (value) => value.length,
			log: () => {},
			validation: (kind, value) => kind === 'ip4addr'
				? /^\d+(?:\.\d+){3}$/.test(value)
				: kind === 'ip6addr' && value.includes(':')
		}
	);
}

test('removes deleted nodes from groups without deleting groups or inventing direct-out', () => {
	const uci = createUci([
		{
			'.name': 'config',
			'.type': 'config',
			main_urltest_nodes: ['n1', 'n2', 'dangling'],
			main_udp_urltest_nodes: ['n1', 'dangling']
		},
		{
			'.name': 'legacy-route-test',
			'.type': 'routing_node',
			node: 'urltest',
			urltest_nodes: ['n1', 'n2', 'dangling']
		},
		{
			'.name': 'legacy-route-empty',
			'.type': 'routing_node',
			node: 'urltest',
			urltest_nodes: ['n1', 'dangling']
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
	assert.equal(uci.section('empty').outbounds, undefined);
	assert.equal(uci.section('empty').default, undefined);
	assert.ok(uci.section('selector'));
	assert.ok(uci.section('empty'));
	assert.deepEqual(plain(result.changed_groups), ['selector', 'empty', 'default-only']);
	assert.deepEqual(plain(result.empty_groups), ['empty']);
	assert.match(logs.join('\n'), /empty.*Auto/);
	assert.equal(uci.calls.set.some((call) => call[3] === 'direct-out'), false);
	assert.deepEqual(plain(uci.section('config').main_urltest_nodes), ['n2']);
	assert.equal(uci.section('config').main_udp_urltest_nodes, undefined);
	assert.deepEqual(plain(uci.section('legacy-route-test').urltest_nodes), ['n2']);
	assert.equal(uci.section('legacy-route-empty').urltest_nodes, undefined);
	assert.deepEqual(plain(uci.calls.delete), [
		['homeproxy-ce', 'config', 'main_udp_urltest_nodes'],
		['homeproxy-ce', 'legacy-route-empty', 'urltest_nodes'],
		['homeproxy-ce', 'selector', 'default'],
		['homeproxy-ce', 'empty', 'outbounds'],
		['homeproxy-ce', 'empty', 'default'],
		['homeproxy-ce', 'default-only', 'default']
	]);
	assert.deepEqual(plain(uci.calls.set), [
		['homeproxy-ce', 'config', 'main_urltest_nodes', ['n2']],
		['homeproxy-ce', 'legacy-route-test', 'urltest_nodes', ['n2']],
		['homeproxy-ce', 'selector', 'outbounds', ['n2']]
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

test('matches a renamed subscription node by its connection fields, not its label', () => {
	const existing = {
		'.name': 'old-section',
		'.type': 'node',
		grouphash: 'subscription-a',
		label: 'Old name[203.0.113.10].0',
		type: 'vless',
		address: '203.0.113.10',
		port: 443,
		uuid: 'uuid-a',
		tls: '1',
		tls_sni: 'edge.example'
	};
	const incoming = {
		label: 'New name[203.0.113.10].1',
		type: 'vless',
		address: '203.0.113.10',
		port: '443',
		uuid: 'uuid-a',
		tls: '1',
		tls_sni: 'edge.example',
		grouphash: 'subscription-a'
	};
	const { findSubscriptionNode } = extractSubscriptionMatcher();

	const matched = findSubscriptionNode({
		'new-section': incoming,
		'incoming-config-hash': incoming
	}, existing);

	assert.equal(matched, incoming);
});

test('compares scalar and array subscription values with UCI string semantics', () => {
	const existing = {
		'.name': 'old-section',
		'.type': 'node',
		grouphash: 'subscription-a',
		label: 'Old name',
		type: 'vless',
		address: '203.0.113.10',
		port: '443',
		uuid: 'uuid-a',
		tls_alpn: ['h2', 'http/1.1']
	};
	const incoming = {
		label: 'New name',
		type: 'vless',
		address: '203.0.113.10',
		port: 443,
		uuid: 'uuid-a',
		tls_alpn: ['h2', 'http/1.1'],
		grouphash: 'subscription-a'
	};
	const { findSubscriptionNode } = extractSubscriptionMatcher();

	assert.equal(findSubscriptionNode({ 'incoming-config-hash': incoming }, existing), incoming);
});

test('allocates a distinct section ID when a new label hash is already retained', () => {
	const { subscriptionNodeSectionId } = extractSubscriptionMatcher();
	const usedIds = { 'hash-Same label': true };

	assert.equal(subscriptionNodeSectionId('Same label', usedIds), 'hash-Same label.1');
	assert.equal(subscriptionNodeSectionId('Same label', usedIds), 'hash-Same label.2');
	assert.equal(usedIds['hash-Same label'], true);
});

test('reports a label change so proxied updates can restart the service', () => {
	const { subscriptionNodeChanged } = extractSubscriptionMatcher();
	const existing = {
		'.name': 'node-a',
		'.type': 'node',
		grouphash: 'subscription-a',
		label: 'Old label',
		type: 'vless',
		address: '203.0.113.10',
		port: '443',
		uuid: 'uuid-a'
	};
	const renamed = { ...existing, label: 'New label' };
	const endpointChanged = { ...existing, address: '203.0.113.11' };

	assert.equal(subscriptionNodeChanged(existing, renamed), true);
	assert.equal(subscriptionNodeChanged(existing, endpointChanged), true);
	assert.equal(subscriptionNodeChanged(existing, existing), false);
});

test('does not match a newly added subscription node to an existing member', () => {
	const existing = {
		'.name': 'old-section',
		'.type': 'node',
		grouphash: 'subscription-a',
		label: 'Existing[203.0.113.10].0',
		type: 'vless',
		address: '203.0.113.10',
		port: '443',
		uuid: 'uuid-a'
	};
	const added = {
		label: 'Added[203.0.113.11].1',
		type: 'vless',
		address: '203.0.113.11',
		port: '443',
		uuid: 'uuid-b',
		grouphash: 'subscription-a'
	};
	const { findSubscriptionNode } = extractSubscriptionMatcher();

	assert.equal(findSubscriptionNode({ 'incoming-config-hash': added }, existing), null);
});

test('keeps a section ID when its label stays stable but the endpoint changes', () => {
	const existing = {
		'.name': 'old-section',
		'.type': 'node',
		grouphash: 'subscription-a',
		label: 'Existing[203.0.113.10].0',
		type: 'vless',
		address: '203.0.113.10',
		port: '443',
		uuid: 'uuid-a'
	};
	const changed = { ...existing, label: 'Existing[203.0.113.10].0', address: '203.0.113.12' };
	const { findSubscriptionNode } = extractSubscriptionMatcher();

	assert.equal(findSubscriptionNode({ 'old-section': changed }, existing), changed);
});

test('does not let two old sections claim the same incoming node', () => {
	const incoming = {
		label: 'Renamed[203.0.113.10].0',
		type: 'vless',
		address: '203.0.113.10',
		port: '443',
		uuid: 'uuid-a',
		grouphash: 'subscription-a'
	};
	const oldSection = {
		'.name': 'old-section',
		'.type': 'node',
		grouphash: 'subscription-a',
		label: 'Old name[203.0.113.10].0',
		type: 'vless',
		address: '203.0.113.10',
		port: '443',
		uuid: 'uuid-a'
	};
	const duplicateOldSection = { ...oldSection, '.name': 'duplicate-old-section' };
	const { findSubscriptionNode } = extractSubscriptionMatcher();
	const cache = {
		'incoming-config-hash': incoming,
		'incoming-name-hash': incoming
	};

	assert.equal(findSubscriptionNode(cache, oldSection), incoming);
	incoming.isExisting = true;
	assert.equal(findSubscriptionNode(cache, duplicateOldSection), null);
});

test('matches swapped subscription labels by connection identity', () => {
	const incomingA = {
		label: 'Beta[203.0.113.10].1',
		type: 'vless',
		address: '203.0.113.10',
		port: '443',
		uuid: 'uuid-a',
		grouphash: 'subscription-a'
	};
	const incomingB = {
		label: 'Alpha[203.0.113.11].0',
		type: 'vless',
		address: '203.0.113.11',
		port: '443',
		uuid: 'uuid-b',
		grouphash: 'subscription-a'
	};
	const oldA = {
		'.name': 'old-a',
		'.type': 'node',
		grouphash: 'subscription-a',
		label: 'Alpha[203.0.113.10].0',
		type: 'vless',
		address: '203.0.113.10',
		port: '443',
		uuid: 'uuid-a'
	};
	const oldB = {
		'.name': 'old-b',
		'.type': 'node',
		grouphash: 'subscription-a',
		label: 'Beta[203.0.113.11].1',
		type: 'vless',
		address: '203.0.113.11',
		port: '443',
		uuid: 'uuid-b'
	};
	const { findSubscriptionNode } = extractSubscriptionMatcher();
	const cache = { 'old-a': incomingB, 'old-b': incomingA };

	assert.equal(findSubscriptionNode(cache, oldA), incomingA);
	incomingA.isExisting = true;
	assert.equal(findSubscriptionNode(cache, oldB), incomingB);
});

test('syncs bound groups with new nodes while respecting their address family', () => {
	const uci = createUci([
		{
			'.name': 'auto-v4',
			'.type': 'node',
			type: 'urltest',
			subscription_sync: '1',
			subscription_family: 'ipv4',
			subscription_source: ['subscription-a'],
			outbounds: ['n4', 'n6'],
			default: 'n6'
		},
		{ '.name': 'n4', '.type': 'node', type: 'vless', address: '198.51.100.4', grouphash: 'subscription-a' },
		{ '.name': 'n6', '.type': 'node', type: 'vless', address: '2001:db8::6', grouphash: 'subscription-a' },
		{ '.name': 'new4', '.type': 'node', type: 'vless', address: '198.51.100.5', grouphash: 'subscription-a' },
		{
			'.name': 'manual',
			'.type': 'node',
			type: 'selector',
			outbounds: ['n4']
		}
	]);
	const { syncSubscriptionGroupMembers } = extractSubscriptionGroupSync();

	const result = syncSubscriptionGroupMembers(uci, 'homeproxy-ce', { 'subscription-a': true });

	assert.deepEqual(plain(uci.section('auto-v4').outbounds), ['n4', 'new4']);
	assert.equal(uci.section('auto-v4').default, undefined);
	assert.deepEqual(plain(uci.section('manual').outbounds), ['n4']);
	assert.deepEqual(plain(result.changed_groups), ['auto-v4']);
	assert.deepEqual(plain(result.empty_groups), []);
});

test('leaves bound groups unchanged when a source fetch has no usable nodes', () => {
	const uci = createUci([
		{
			'.name': 'auto-v4',
			'.type': 'node',
			type: 'urltest',
			subscription_sync: '1',
			subscription_family: 'ipv4',
			subscription_source: ['subscription-a'],
			outbounds: ['n4']
		},
		{ '.name': 'n4', '.type': 'node', type: 'vless', address: '198.51.100.4', grouphash: 'subscription-a' }
	]);
	const { syncSubscriptionGroupMembers } = extractSubscriptionGroupSync();

	const result = syncSubscriptionGroupMembers(uci, 'homeproxy-ce', {});

	assert.deepEqual(plain(uci.section('auto-v4').outbounds), ['n4']);
	assert.deepEqual(plain(result), { changed_groups: [], empty_groups: [] });
	assert.deepEqual(plain(uci.calls.set), []);
});

test('preserves nodes when a subscription source cache is missing or empty', () => {
	const { subscriptionCacheAvailable } = extractSubscriptionMatcher();

	assert.equal(subscriptionCacheAvailable(undefined), false);
	assert.equal(subscriptionCacheAvailable({}), false);
	assert.equal(subscriptionCacheAvailable({ 'config-hash': {} }), true);
});

test('flags only changed selector groups that became empty before commit', () => {
	const uci = createUci([
		{ '.name': 'changed-empty', '.type': 'node', type: 'selector' },
		{ '.name': 'changed-live', '.type': 'node', type: 'selector', outbounds: ['n1'] },
		{ '.name': 'unchanged-empty', '.type': 'node', type: 'urltest' },
		{ '.name': 'ordinary', '.type': 'node', type: 'vless' }
	]);
	const { findEmptySubscriptionGroups } = extractSubscriptionGroupSync();

	assert.deepEqual(
		plain(findEmptySubscriptionGroups(uci, 'homeproxy-ce', [
			'changed-empty', 'changed-live', 'ordinary', 'changed-empty'
		])),
		['changed-empty']
	);
});
