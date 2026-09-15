const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const test = require('node:test');

const source = fs.readFileSync(
	path.join(__dirname, '..', 'root/etc/homeproxy-ce/scripts/generate_client.uc'),
	'utf8'
);

test('route rule actions are used for sing-box 1.11 and newer', () => {
	const match = source.match(
		/const\s+legacy_route_rule_format\s*=\s*version_lt\(features\.version,\s*(\d+),\s*(\d+)\);/
	);

	assert.ok(match, 'legacy_route_rule_format declaration should be present');
	assert.deepEqual(match.slice(1).map(Number), [1, 11]);
});

test('sing-box version parsing preserves the minor version', () => {
	const match = source.match(/const\s+matched\s*=\s*match\(version,\s*(\/.+\/)\);/);

	assert.ok(match, 'version_lt should parse the sing-box version');
	assert.equal(match[1], '/^[0-9.]+/');
});
