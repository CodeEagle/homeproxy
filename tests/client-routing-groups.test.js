'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const test = require('node:test');

const { loadLuCIModule } = require('./helpers/load-luci-module');

const hp = loadLuCIModule();
const nodes = [
	{ '.name': 'n1', label: 'Hong Kong', type: 'vless' },
	{ '.name': 'n2', label: 'Los Angeles', type: 'trojan' },
	{ '.name': 'g1', label: 'Auto', type: 'selector', outbounds: ['n1', 'n2'] },
	{ '.name': 'g2', label: 'Fallback', type: 'urltest', outbounds: ['n1', 'n2'] }
];

const routingNodes = [
	{ '.name': 'r1', label: 'Proxy upstream', enabled: '1', node: 'n1' },
	{ '.name': 'r2', label: 'Disabled upstream', enabled: '0', node: 'n2' },
	{ '.name': 'r3', label: 'Current upstream', enabled: '1', node: 'n2' }
];

function values(choices) {
	return Array.from(choices, (choice) => choice.value);
}

function plain(value) {
	return JSON.parse(JSON.stringify(value));
}

test('outboundNodeChoices combines direct, enabled routing nodes and selector/urltest nodes', () => {
	const choices = hp.outboundNodeChoices(nodes, routingNodes, 'r3', 'custom');

	assert.deepEqual(values(choices), ['direct-out', 'r1', 'g1', 'g2']);
	assert.deepEqual(plain(choices), [
		{ value: 'direct-out', label: 'Direct' },
		{ value: 'r1', label: 'Proxy upstream' },
		{ value: 'g1', label: 'Auto' },
		{ value: 'g2', label: 'Fallback' }
	]);
});

test('outboundNodeChoices omits ordinary nodes, disabled routing nodes and the current routing node', () => {
	const choices = hp.outboundNodeChoices(nodes, routingNodes, 'r1', 'custom');
	const choiceValues = values(choices);

	assert.equal(choiceValues.includes('n1'), false);
	assert.equal(choiceValues.includes('n2'), false);
	assert.equal(choiceValues.includes('r2'), false);
	assert.equal(choiceValues.includes('r1'), false);
	assert.equal(choiceValues.includes('g1'), true);
	assert.equal(choiceValues.includes('g2'), true);
});

test('outboundNodeChoices omits legacy routing nodes outside custom mode', () => {
	for (const routingMode of ['main', 'disabled', 'bypass_mainland_china']) {
		const choices = hp.outboundNodeChoices(nodes, routingNodes, 'r3', routingMode);
		assert.deepEqual(values(choices), ['direct-out', 'g1', 'g2'], routingMode);
	}
});

test('Clash API access validation permits loopback controllers without a secret', () => {
	for (const controller of ['127.0.0.1:9090', '[::1]:9090', 'localhost:9090'])
		assert.equal(hp.validateClashApiAccess(controller, ''), true, controller);
});

test('Clash API access validation requires a secret for wildcard and non-loopback controllers', () => {
	for (const controller of [
		'0.0.0.0:9090',
		'[::]:9090',
		'192.0.2.10:9090',
		'example.test:9090'
	]) {
		const error = hp.validateClashApiAccess(controller, '');
		assert.equal(typeof error, 'string', controller);
		assert.match(error, /secret/i, controller);
	}

	assert.equal(hp.validateClashApiAccess('0.0.0.0:9090', 'token'), true);
});

test('Clash controller and secret fields validate against both current form values', () => {
	const source = fs.readFileSync(
		path.join(__dirname, '..', 'htdocs/luci-static/resources/view/homeproxy-ce/client.js'),
		'utf8'
	);

	assert.equal((source.match(/so\.validate = validateClashApiOption;/g) || []).length, 2);
	assert.match(source, /formvalue\(section_id, 'external_controller'\)/);
	assert.match(source, /formvalue\(section_id, 'secret'\)/);
});

test('routing node bind interface remains visible when upstream is Direct', () => {
	const source = fs.readFileSync(
		path.join(__dirname, '..', 'htdocs/luci-static/resources/view/homeproxy-ce/client.js'),
		'utf8'
	);

	assert.match(source, /'outbound': \/\^\(\?:\|direct-out\)\$\//);
});

test('client outbound choices use the current routing mode from UCI', () => {
	const source = fs.readFileSync(
		path.join(__dirname, '..', 'htdocs/luci-static/resources/view/homeproxy-ce/client.js'),
		'utf8'
	);

	assert.match(source, /const routing_mode = uci\.get\(data\[0\], 'config', 'routing_mode'\)/);
});
