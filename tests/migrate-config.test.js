const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const test = require('node:test');

const source = fs.readFileSync(
	path.join(__dirname, '..', 'root/etc/homeproxy-ce/scripts/migrate_config.uc'),
	'utf8'
);

function dnsRuleMigrationBlock() {
	const start = source.indexOf("uci.foreach(uciconfig, ucidnsrule");
	const end = source.indexOf('/* nodes options */', start);
	assert.notEqual(start, -1, 'DNS rule migration loop should be present');
	assert.notEqual(end, -1, 'DNS rule migration loop should have an end marker');
	return source.slice(start, end);
}

test('migration preserves outbound DNS rule conditions for generator compatibility', () => {
	const block = dnsRuleMigrationBlock();

	assert.match(block, /Preserve legacy outbound DNS rule matchers/);
	assert.doesNotMatch(
		block,
		/uci\.delete\(uciconfig, cfg\['\.name'\]\)/,
		'outbound DNS rules must not be deleted during migration'
	);
	assert.doesNotMatch(
		block,
		/default_outbound_dns/,
		'migration must not replace conditional rules with a broad default resolver'
	);
});
