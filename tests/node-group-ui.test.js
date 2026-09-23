'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const test = require('node:test');

const { loadLuCIModule } = require('./helpers/load-luci-module');

const hp = loadLuCIModule();
const nodeViewSource = fs.readFileSync(
	path.join(__dirname, '..', 'htdocs/luci-static/resources/view/homeproxy-ce/node.js'),
	'utf8'
);
const nodes = [
	{ '.name': 'n1', label: '香港', type: 'vless' },
	{ '.name': 'n2', label: '洛杉矶', type: 'trojan' },
	{ '.name': 'g1', label: '自动', type: 'urltest', outbounds: ['n1', 'n2'] },
	{ '.name': 'g2', label: '手动', type: 'selector', outbounds: ['g1', 'n2'], default: 'n2' }
];

function plain(value) {
	return JSON.parse(JSON.stringify(value));
}

test('subscription refresh executes the CE updater allowed by the RPC ACL', () => {
	assert.match(nodeViewSource, /fs\.exec_direct\('\/etc\/homeproxy-ce\/scripts\/update_subscriptions\.uc'\)/);
	assert.doesNotMatch(nodeViewSource, /fs\.exec_direct\('\/etc\/homeproxy\/scripts\/update_subscriptions\.uc'\)/);
});

test('nodeGroupChoices uses section IDs as values and labels for display', () => {
	assert.deepEqual(plain(hp.nodeGroupChoices(nodes, 'g1')), [
		{ value: 'n1', label: '香港' },
		{ value: 'n2', label: '洛杉矶' },
		{ value: 'g2', label: '手动' }
	]);

	assert.equal(
		plain(hp.nodeGroupChoices(nodes, 'g1')).some((choice) => choice.value === 'g1'),
		false
	);
});

test('findNodeGroupReferences returns groups that directly reference a node', () => {
	assert.deepEqual(
		plain(hp.findNodeGroupReferences(nodes, 'n1')).map((node) => ({ id: node['.name'], label: node.label })),
		[{ id: 'g1', label: '自动' }]
	);
});

test('findNodeGroupReferences resolves a unique legacy label without guessing ambiguous labels', () => {
	const legacyNodes = [
		{ '.name': 'n1', label: '香港', type: 'vless' },
		{ '.name': 'g1', label: '旧组', type: 'selector', outbounds: ['香港'] }
	];
	assert.deepEqual(
		plain(hp.findNodeGroupReferences(legacyNodes, 'n1')).map((node) => node['.name']),
		['g1']
	);

	const ambiguousNodes = [
		...legacyNodes,
		{ '.name': 'n2', label: '香港', type: 'trojan' }
	];
	assert.deepEqual(hp.findNodeGroupReferences(ambiguousNodes, 'n1'), []);
});

test('findNodeGroupReferencesForTargets deduplicates groups by group ID', () => {
	const groupedNodes = [
		{ '.name': 'n1', label: '一', type: 'vless' },
		{ '.name': 'n2', label: '二', type: 'trojan' },
		{ '.name': 'g1', label: '共享组', type: 'selector', outbounds: ['n1', 'n2'] }
	];
	assert.deepEqual(
		plain(hp.findNodeGroupReferencesForTargets(groupedNodes, ['n1', 'n2'])).map((entry) => ({
			targetId: entry.targetId,
			groupId: entry.group['.name']
		})),
		[{ targetId: 'n1', groupId: 'g1' }]
	);
});

test('validateNodeGroup accepts a non-empty group with a member default', () => {
	assert.equal(hp.validateNodeGroup(nodes, nodes[3]), true);
});

test('validateNodeGroup rejects empty groups', () => {
	const result = hp.validateNodeGroup(nodes, {
		'.name': 'empty', label: '空组', type: 'selector', outbounds: []
	});

	assert.match(result, /空组 \(empty\)/);
});

test('validateNodeGroup rejects self references', () => {
	const result = hp.validateNodeGroup(nodes, {
		'.name': 'self', label: '自引用', type: 'selector', outbounds: ['self']
	});

	assert.match(result, /自引用 \(self\)/);
});

test('validateNodeGroup rejects indirect cycles', () => {
	const cyclicNodes = [
		...nodes,
		{ '.name': 'g3', label: '循环甲', type: 'selector', outbounds: ['g4'] },
		{ '.name': 'g4', label: '循环乙', type: 'urltest', outbounds: ['g3'] }
	];
	const result = hp.validateNodeGroup(cyclicNodes, cyclicNodes[4]);

	assert.match(result, /循环甲 \(g3\)/);
	assert.match(result, /循环乙 \(g4\)/);
	assert.match(result, /g3.*g4.*g3/);
});

test('validateNodeGroup rejects missing and ambiguous references', () => {
	const missing = hp.validateNodeGroup(nodes, {
		'.name': 'missing', label: '悬空', type: 'selector', outbounds: ['gone']
	});
	assert.match(missing, /悬空 \(missing\)/);
	assert.match(missing, /gone/);

	const ambiguousNodes = [
		...nodes,
		{ '.name': 'n3', label: '香港', type: 'shadowsocks' }
	];
	const ambiguous = hp.validateNodeGroup(ambiguousNodes, {
		'.name': 'ambiguous', label: '重名', type: 'selector', outbounds: ['香港']
	});
	assert.match(ambiguous, /重名 \(ambiguous\)/);
	assert.match(ambiguous, /香港/);
});

test('validateNodeGroup rejects defaults outside the member list', () => {
	const result = hp.validateNodeGroup(nodes, {
		'.name': 'bad-default', label: '错误默认', type: 'selector',
		outbounds: ['n1'], default: 'n2'
	});

	assert.match(result, /错误默认 \(bad-default\)/);
	assert.match(result, /n2/);
});
