'use strict';

const assert = require('node:assert/strict');
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
	const choices = hp.outboundNodeChoices(nodes, routingNodes, 'r3');

	assert.deepEqual(values(choices), ['direct-out', 'r1', 'g1', 'g2']);
	assert.deepEqual(plain(choices), [
		{ value: 'direct-out', label: 'Direct' },
		{ value: 'r1', label: 'Proxy upstream' },
		{ value: 'g1', label: 'Auto' },
		{ value: 'g2', label: 'Fallback' }
	]);
});

test('outboundNodeChoices omits ordinary nodes, disabled routing nodes and the current routing node', () => {
	const choices = hp.outboundNodeChoices(nodes, routingNodes, 'r1');
	const choiceValues = values(choices);

	assert.equal(choiceValues.includes('n1'), false);
	assert.equal(choiceValues.includes('n2'), false);
	assert.equal(choiceValues.includes('r2'), false);
	assert.equal(choiceValues.includes('r1'), false);
	assert.equal(choiceValues.includes('g1'), true);
	assert.equal(choiceValues.includes('g2'), true);
});
