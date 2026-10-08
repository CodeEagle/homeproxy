'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const test = require('node:test');

const wrapperPath = path.join(
	__dirname,
	'..',
	'root/etc/homeproxy-ce/scripts/refresh_from_autopilot.sh'
);
const shellTestPath = path.join(__dirname, 'refresh_from_autopilot.test.sh');

test('forced-command wrapper shell behavior passes its isolated integration test', () => {
	const result = spawnSync('/bin/sh', [shellTestPath], {
		encoding: 'utf8'
	});

	assert.equal(result.status, 0, `${result.stdout}\n${result.stderr}`);
	assert.match(result.stdout, /PASS: refresh_from_autopilot shell behavior/);
});

test('wrapper keeps the forced-command and success gates explicit', () => {
	const source = fs.readFileSync(wrapperPath, 'utf8');

	assert.match(source, /SSH_ORIGINAL_COMMAND/);
	assert.match(source, /= check/);
	assert.match(source, /!= refresh/);
	assert.match(source, /Successfully updated subscriptions/);
	assert.match(source, /ENABLE_DEPRECATED_OUTBOUND_DNS_RULE_ITEM=true/);
	assert.match(source, /sing-box-c\.json/);
	assert.match(source, /TIMEOUT_SECONDS=75/);
	assert.match(source, /FLOCK=\/usr\/bin\/flock/);
	assert.match(source, /exec 9>\"\$LOCK_FILE\"/);
	assert.match(source, /exec 9>&-/);
	assert.match(source, /autopilot-refresh\.lock/);
	assert.match(source, /status.*updated/);
	assert.match(source, /status.*busy/);
	assert.match(source, /status.*failed/);

	assert.doesNotMatch(source, /echo\s+\$SSH_ORIGINAL_COMMAND/);
	assert.doesNotMatch(source, /eval\s/);
});
