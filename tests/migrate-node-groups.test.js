'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const test = require('node:test');

const { extractUcodeFunctions } = require('./helpers/extract-ucode-functions');

const source = fs.readFileSync(
	path.join(__dirname, '..', 'root/etc/homeproxy-ce/scripts/migrate_config.uc'),
	'utf8'
);
const homeproxySource = fs.readFileSync(
	path.join(__dirname, '..', 'root/etc/homeproxy-ce/scripts/homeproxy.uc'),
	'utf8'
);

const helpers = extractUcodeFunctions(
	homeproxySource,
	['buildNodeReferenceIndex', 'resolveNodeReference'],
	{
		length: (value) => value.length,
		builtin_outbound_tags: { 'direct-out': true, 'block-out': true }
	}
);

function plain(value) {
	return JSON.parse(JSON.stringify(value));
}

function createUci(nodes) {
	const sections = nodes.map((node) => ({
		...node,
		outbounds: node.outbounds ? [...node.outbounds] : node.outbounds
	}));
	const calls = { set: [], delete: [] };

	return {
		calls,
		foreach(config, type, callback) {
			for (const section of sections) {
				if (section['.type'] === type || (!section['.type'] && type === 'node'))
					callback(section);
			}
		},
		get(config, section, option) {
			const value = sections.find((entry) => entry['.name'] === section);
			return option === undefined ? value : value?.[option];
		},
		set(config, section, option, value) {
			const target = sections.find((entry) => entry['.name'] === section);
			calls.set.push([config, section, option, value]);
			target[option] = Array.isArray(value) ? [...value] : value;
		},
		delete(config, section, option) {
			calls.delete.push([config, section, option]);
			const target = sections.find((entry) => entry['.name'] === section);
			if (option === undefined)
				sections.splice(sections.indexOf(target), 1);
			else
				delete target[option];
		},
		section(name) {
			return sections.find((entry) => entry['.name'] === name);
		}
	};
}

function fixture() {
	return [
		{ '.name': 'n1', label: 'Hong Kong', type: 'vless' },
		{ '.name': 'n2', label: 'Los Angeles', type: 'trojan' },
		{
			'.name': 'selector',
			label: 'Manual',
			type: 'selector',
			outbounds: ['Hong Kong', 'n2', 'direct-out'],
			default: 'Los Angeles'
		},
		{ '.name': 'n3', label: 'Same', type: 'shadowsocks' },
		{ '.name': 'n4', label: 'Same', type: 'trojan' },
		{ '.name': 'duplicate', label: 'Duplicate', type: 'selector', outbounds: ['Same'] },
		{ '.name': 'missing', label: 'Missing', type: 'urltest', outbounds: ['Not configured'] }
	];
}

test('migrates unique labels to section IDs and remains idempotent', () => {
	const uci = createUci(fixture());
	const warnings = [];
	const { migrateNodeGroupReferences } = extractUcodeFunctions(
		source,
		['migrateNodeGroupReferences'],
		{
			...helpers,
			length: (value) => value.length,
			warn: (...args) => warnings.push(args.join(' '))
		}
	);

	const result = migrateNodeGroupReferences(uci, 'homeproxy-ce');
	assert.deepEqual(plain(uci.section('selector').outbounds), ['n1', 'n2', 'direct-out']);
	assert.equal(uci.section('selector').default, 'n2');
	assert.equal(uci.calls.set.length, 2);
	assert.deepEqual(plain(result.changed_groups), ['selector']);

	const firstDiagnostics = plain(result.diagnostics);
	assert.deepEqual(firstDiagnostics, [
		{ section: 'duplicate', reference: 'Same', status: 'ambiguous', matches: ['n3', 'n4'] },
		{ section: 'missing', reference: 'Not configured', status: 'missing' }
	]);
	assert.match(warnings.join('\n'), /duplicate.*Same/);
	assert.match(warnings.join('\n'), /missing.*Not configured/);

	uci.calls.set.length = 0;
	const secondResult = migrateNodeGroupReferences(uci, 'homeproxy-ce');
	assert.equal(uci.calls.set.length, 0);
	assert.deepEqual(plain(secondResult.changed_groups), []);
	assert.deepEqual(plain(secondResult.diagnostics), firstDiagnostics);
});

test('keeps already normalized IDs and built-in outbound tags unchanged', () => {
	const uci = createUci([
		{ '.name': 'n1', label: 'Hong Kong', type: 'vless' },
		{
			'.name': 'selector',
			label: 'Manual',
			type: 'selector',
			outbounds: ['n1', 'direct-out'],
			default: 'n1'
		}
	]);
	const { migrateNodeGroupReferences } = extractUcodeFunctions(
		source,
		['migrateNodeGroupReferences'],
		{ ...helpers, length: (value) => value.length, warn: () => {} }
	);

	const result = migrateNodeGroupReferences(uci, 'homeproxy-ce');
	assert.deepEqual(plain(uci.section('selector').outbounds), ['n1', 'direct-out']);
	assert.equal(uci.section('selector').default, 'n1');
	assert.equal(uci.calls.set.length, 0);
	assert.deepEqual(plain(result.changed_groups), []);
});
