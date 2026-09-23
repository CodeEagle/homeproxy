'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const test = require('node:test');

const { extractUcodeFunctions } = require('./helpers/extract-ucode-functions');

const source = fs.readFileSync(
	path.join(__dirname, '..', 'root/etc/homeproxy-ce/scripts/homeproxy.uc'),
	'utf8'
);

const ucodeContext = {
	builtin_outbound_tags: {
		'direct-out': true,
		'block-out': true
	},
	length: (value) => value.length
};

function plain(value) {
	return JSON.parse(JSON.stringify(value));
}

test('extractUcodeFunctions evaluates a complete nested function body', () => {
	const fixture = `
		export function nested(value) {
			const result = { outer: { answer: 7 } };
			if (value) {
				return result.outer.answer;
			}
			return -result.outer.answer;
		}
	`;
	const { nested } = extractUcodeFunctions(fixture, ['nested']);

	assert.equal(nested(true), 7);
	assert.equal(nested(false), -7);
});

const {
	buildNodeReferenceIndex,
	resolveNodeReference,
	normalizeNodeGroup,
	planNodeDependencies
} = extractUcodeFunctions(
	source,
	['buildNodeReferenceIndex', 'resolveNodeReference', 'normalizeNodeGroup', 'planNodeDependencies'],
	ucodeContext
);

const nodes = [
	{ '.name': 'n1', label: 'Hong Kong', type: 'vless' },
	{ '.name': 'n2', label: 'Los Angeles', type: 'trojan' },
	{ '.name': 'g1', label: 'Auto', type: 'urltest', outbounds: ['n1', 'n2'] },
	{ '.name': 'g2', label: 'Manual', type: 'selector', outbounds: ['g1', 'n2'], default: 'n2' }
];

test('resolves section IDs, unique labels, and built-in outbound tags', () => {
	const index = buildNodeReferenceIndex(nodes);

	assert.deepEqual(plain(index.by_label), {
		'Hong Kong': ['n1'],
		'Los Angeles': ['n2'],
		Auto: ['g1'],
		Manual: ['g2']
	});
	assert.deepEqual(plain(resolveNodeReference(index, 'n1')), {
		status: 'ok',
		id: 'n1',
		tag: 'cfg-n1-out'
	});
	assert.deepEqual(plain(resolveNodeReference(index, 'Hong Kong')), {
		status: 'ok',
		id: 'n1',
		tag: 'cfg-n1-out'
	});
	assert.deepEqual(plain(resolveNodeReference(index, 'direct-out')), {
		status: 'ok',
		id: 'direct-out',
		tag: 'direct-out'
	});
	assert.deepEqual(plain(resolveNodeReference(index, 'block-out')), {
		status: 'ok',
		id: 'block-out',
		tag: 'block-out'
	});
});

test('reports duplicate labels as ambiguous and unknown references as missing', () => {
	const duplicateIndex = buildNodeReferenceIndex([
		...nodes,
		{ '.name': 'n3', label: 'Hong Kong', type: 'shadowsocks' }
	]);

	assert.deepEqual(plain(resolveNodeReference(duplicateIndex, 'Hong Kong')), {
		status: 'ambiguous',
		reference: 'Hong Kong',
		matches: ['n1', 'n3']
	});
	assert.deepEqual(plain(resolveNodeReference(buildNodeReferenceIndex(nodes), 'missing-node')), {
		status: 'missing',
		reference: 'missing-node'
	});
});

test('normalizes group members and its default while preserving first occurrence order', () => {
	const index = buildNodeReferenceIndex(nodes);
	const normalized = normalizeNodeGroup(
		{ ...nodes[3], outbounds: ['n2', 'Hong Kong', 'n2'], default: 'n2' },
		index
	);

	assert.deepEqual(plain(normalized), {
		status: 'ok',
		outbounds: ['n2', 'n1'],
		default: 'n2'
	});
});

test('reports a dangling group member as missing', () => {
	const index = buildNodeReferenceIndex(nodes);

	assert.deepEqual(
		plain(normalizeNodeGroup({ ...nodes[2], outbounds: ['n1', 'gone'] }, index)),
		{ status: 'missing', reference: 'gone' }
	);
});

test('plans dependencies with members before their containing groups', () => {
	const index = buildNodeReferenceIndex(nodes);

	assert.deepEqual(plain(planNodeDependencies(index, ['g2'])), {
		status: 'ok',
		order: ['n1', 'n2', 'g1', 'g2']
	});
	assert.deepEqual(plain(planNodeDependencies(index, ['direct-out'])), {
		status: 'ok',
		order: []
	});
});

test('keeps built-in outbound tags in groups without planning them as nodes', () => {
	const builtInGroup = {
		'.name': 'builtins',
		label: 'Built-ins',
		type: 'selector',
		outbounds: ['direct-out', 'n1', 'block-out']
	};
	const index = buildNodeReferenceIndex([...nodes, builtInGroup]);

	assert.deepEqual(plain(normalizeNodeGroup(builtInGroup, index)), {
		status: 'ok',
		outbounds: ['direct-out', 'n1', 'block-out'],
		default: null
	});
	assert.deepEqual(plain(planNodeDependencies(index, ['builtins'])), {
		status: 'ok',
		order: ['n1', 'builtins']
	});
});

test('returns a path when groups form a dependency cycle', () => {
	const cycleNodes = [
		{ '.name': 'g1', label: 'One', type: 'urltest', outbounds: ['g2'] },
		{ '.name': 'g2', label: 'Two', type: 'selector', outbounds: ['g1'] }
	];

	assert.deepEqual(plain(planNodeDependencies(buildNodeReferenceIndex(cycleNodes), ['g1'])), {
		status: 'error',
		kind: 'cycle',
		reference: 'g1',
		path: ['g1', 'g2', 'g1']
	});
});

test('reports an empty group', () => {
	const index = buildNodeReferenceIndex(nodes);

	assert.deepEqual(
		plain(normalizeNodeGroup({ '.name': 'empty', label: 'Empty', type: 'selector' }, index)),
		{ status: 'error', kind: 'empty-group', reference: 'empty' }
	);
});

test('reports a default that is not one of the group members', () => {
	const index = buildNodeReferenceIndex(nodes);

	assert.deepEqual(
		plain(normalizeNodeGroup({ ...nodes[2], default: 'g2' }, index)),
		{ status: 'error', kind: 'invalid-default', reference: 'g2' }
	);
});

test('reports planner errors with only the active dependency path', () => {
	const index = buildNodeReferenceIndex([
		...nodes,
		{ '.name': 'g3', label: 'Broken', type: 'urltest', outbounds: ['gone'] }
	]);

	assert.deepEqual(plain(planNodeDependencies(index, ['g2', 'gone'])), {
		status: 'error',
		kind: 'missing',
		reference: 'gone',
		path: []
	});
	assert.deepEqual(plain(planNodeDependencies(index, ['g3'])), {
		status: 'error',
		kind: 'missing',
		reference: 'gone',
		path: ['g3']
	});
});
