'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const test = require('node:test');

const { extractUcodeFunctions } = require('./helpers/extract-ucode-functions');

const source = fs.readFileSync(
	path.join(__dirname, '..', 'root/etc/homeproxy-ce/scripts/generate_client.uc'),
	'utf8'
);
const homeproxySource = fs.readFileSync(
	path.join(__dirname, '..', 'root/etc/homeproxy-ce/scripts/homeproxy.uc'),
	'utf8'
);

function plain(value) {
	return JSON.parse(JSON.stringify(value));
}

function removeBlankAttrs(value) {
	if (Array.isArray(value))
		return value.filter((entry) => entry !== null && entry !== '').map(removeBlankAttrs);

	if (value && typeof value === 'object')
		return Object.fromEntries(
			Object.entries(value)
				.filter(([, entry]) => entry !== null && entry !== '')
				.map(([key, entry]) => [key, removeBlankAttrs(entry)])
		);

	return value;
}

const helpers = extractUcodeFunctions(
	homeproxySource,
	['buildNodeReferenceIndex', 'resolveNodeReference', 'normalizeNodeGroup', 'planNodeDependencies'],
	{
		builtin_outbound_tags: {
			'direct-out': true,
			'block-out': true
		},
		length: (value) => value.length
	}
);

const context = {
	...helpers,
	length: (value) => value.length,
	isEmpty: (value) => !value || value === 'nil' ||
		(Array.isArray(value) || (value && typeof value === 'object')) && value.length === 0,
	type: (value) => {
		if (Array.isArray(value))
			return 'array';
		if (value && typeof value === 'object')
			return 'object';
		return typeof value;
	},
	push: (array, value) => array.push(value),
	map: (value, callback) => value.map(callback),
	join: (separator, values) => values.join(separator),
	strToBool: (value) => (value === '1' ? true : null),
	strToInt: (value) => (value === undefined || value === null || value === '' ? null : Number(value)),
	strToTime: (value) => (value === undefined || value === null || value === '' ? null : `${value}s`),
	removeBlankAttrs,
	die: (message) => {
		throw new Error(message);
	}
};

const { generate_outbound, collectPlannedNodes, outboundTag, formatNodeReferenceError } =
	extractUcodeFunctions(
		source,
		['generate_outbound', 'collectPlannedNodes', 'outboundTag', 'formatNodeReferenceError'],
		context
	);

const nodes = [
	{ '.name': 'n1', label: 'Hong Kong', type: 'vless', address: '198.51.100.1', port: '443' },
	{ '.name': 'n2', label: 'Los Angeles', type: 'trojan', address: '198.51.100.2', port: '443' },
	{
		'.name': 'g1',
		label: 'Auto',
		type: 'urltest',
		outbounds: ['n1', 'n2'],
		url: 'https://www.gstatic.com/generate_204',
		interval: '180',
		tolerance: '50',
		idle_timeout: '1800'
	},
	{
		'.name': 'g2',
		label: 'Manual',
		type: 'selector',
		outbounds: ['g1', 'n2'],
		default: 'n2',
		interrupt_exist_connections: '1'
	}
];

const referenceIndex = helpers.buildNodeReferenceIndex(nodes);

test('generates selector groups with only selector fields and stable outbound tags', () => {
	assert.deepEqual(
		plain(generate_outbound(nodes[3], referenceIndex)),
		{
			type: 'selector',
			tag: 'cfg-g2-out',
			outbounds: ['cfg-g1-out', 'cfg-n2-out'],
			default: 'cfg-n2-out',
			interrupt_exist_connections: true
		}
	);
	assert.deepEqual(
		plain(generate_outbound({ ...nodes[3], default: null }, referenceIndex)),
		{
			type: 'selector',
			tag: 'cfg-g2-out',
			outbounds: ['cfg-g1-out', 'cfg-n2-out'],
			interrupt_exist_connections: true
		}
	);
});

test('generates URLTest groups with URLTest fields and no proxy dial fields', () => {
	const outbound = generate_outbound(nodes[2], referenceIndex);

	assert.deepEqual(plain(outbound), {
		type: 'urltest',
		tag: 'cfg-g1-out',
		outbounds: ['cfg-n1-out', 'cfg-n2-out'],
		url: 'https://www.gstatic.com/generate_204',
		interval: '180s',
		tolerance: 50,
		idle_timeout: '1800s'
	});
	for (const field of ['routing_mark', 'server', 'server_port', 'tls', 'transport'])
		assert.equal(Object.hasOwn(outbound, field), false, field);
});

test('plans all transitive nodes in dependency order and keeps IDs stable across label changes', () => {
	assert.deepEqual(
		plain(collectPlannedNodes(nodes, ['g2']).map((node) => node['.name'])),
		['n1', 'n2', 'g1', 'g2']
	);

	const renamed = nodes.map((node) => ({ ...node }));
	renamed[0].label = '香港';
	const renamedIndex = helpers.buildNodeReferenceIndex(renamed);
	assert.deepEqual(plain(generate_outbound(renamed[3], renamedIndex).outbounds), [
		'cfg-g1-out',
		'cfg-n2-out'
	]);
	assert.equal(outboundTag('n1'), 'cfg-n1-out');
	assert.equal(outboundTag('direct-out'), 'direct-out');
});

test('rejects missing and cyclic references with diagnostic section, reference, and path', () => {
	assert.throws(
		() => generate_outbound({ ...nodes[2], outbounds: ['n1', 'gone'] }, referenceIndex),
		(error) =>
			error.message.includes('section=g1') &&
			error.message.includes('reference=gone') &&
			!error.message.includes('direct-out')
	);

	assert.throws(
		() => collectPlannedNodes(nodes, ['missing-node']),
		(error) =>
			error.message.includes('section') &&
			error.message.includes('missing-node') &&
			error.message.includes('path')
	);

	const cycle = [
		{ '.name': 'g1', label: 'One', type: 'selector', outbounds: ['g2'] },
		{ '.name': 'g2', label: 'Two', type: 'urltest', outbounds: ['g1'] }
	];
	assert.throws(
		() => collectPlannedNodes(cycle, ['g1']),
		(error) =>
			error.message.includes('section') &&
			error.message.includes('g1') &&
			error.message.includes('path') &&
			!error.message.includes('direct-out')
	);
});

test('formats structured reference diagnostics without losing the active path', () => {
	const message = formatNodeReferenceError({
		status: 'error',
		kind: 'cycle',
		reference: 'g1',
		path: ['g1', 'g2', 'g1'],
		section: 'g1'
	});

	assert.match(message, /section=.*g1/);
	assert.match(message, /reference=.*g1/);
	assert.match(message, /path=.*g1.*g2.*g1/);
});
