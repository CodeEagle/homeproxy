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

function loadWget(responses) {
	const commands = [];
	const context = {
		executeCommand(command) {
			commands.push(command);
			return responses.shift() || {};
		},
		match(value, pattern) {
			return value.match(pattern);
		},
		shellQuote(value) {
			return `'${value}'`;
		},
		trim(value) {
			return typeof value === 'string' ? value.trim() : '';
		},
		type(value) {
			if (value === null)
				return 'null';
			if (Array.isArray(value))
				return 'array';
			if (typeof value === 'object')
				return 'object';
			return typeof value;
		}
	};

	return {
		...extractUcodeFunctions(source, ['wGET'], context),
		commands
	};
}

test('wGET uses the proxy result without an unnecessary direct read', () => {
	const { wGET, commands } = loadWget([
		{ exitcode: 0, stdout: 'node-list', stderr: '' }
	]);

	assert.equal(wGET('https://example.invalid/rx1', '', '1'), 'node-list');
	assert.equal(commands.length, 1);
	assert.match(commands[0], /--proxy http:\/\/127\.0\.0\.1:5330/);
	assert.doesNotMatch(commands[0], /--noproxy/);
});

test('wGET falls back to one direct IPv4 read after a transient proxy reset', () => {
	const { wGET, commands } = loadWget([
		{
			exitcode: 56,
			stdout: '',
			stderr: 'curl: (56) Recv failure: Connection reset by peer'
		},
		{ exitcode: 0, stdout: '  node-list  \n', stderr: '' }
	]);

	assert.equal(wGET('https://example.invalid/rx2', 'test-agent', '1'), 'node-list');
	assert.equal(commands.length, 2);
	assert.match(commands[0], /\/usr\/bin\/curl/);
	assert.match(commands[0], /--max-time 20/);
	assert.match(commands[1], /--max-time 10/);
	assert.match(commands[1], /--ipv4 --noproxy '\*'/);
	assert.ok(commands.every((command) => !command.includes('/usr/bin/wget')));
});

test('wGET sends a persistent proxy TLS failure directly without a second proxy loop', () => {
	const { wGET, commands } = loadWget([
		{
			exitcode: 35,
			stdout: '',
			stderr: 'curl: (35) OpenSSL SSL_connect: Connection reset by peer'
		},
		{ exitcode: 0, stdout: 'node-list', stderr: '' }
	]);

	assert.equal(wGET('https://example.invalid/rx2', '', '1'), 'node-list');
	assert.equal(commands.length, 2);
	assert.match(commands[1], /--ipv4 --noproxy '\*'/);
	assert.doesNotMatch(commands[1], /--proxy http:\/\/127\.0\.0\.1:5330/);
});

test('wGET retries a transient HTTP 503 directly but does not retry a permanent 404', () => {
	const transient = loadWget([
		{
			exitcode: 22,
			stdout: '',
			stderr: 'curl: (22) The requested URL returned error: 503'
		},
		{ exitcode: 0, stdout: 'node-list', stderr: '' }
	]);
	assert.equal(transient.wGET('https://example.invalid/rx2', '', '1'), 'node-list');
	assert.equal(transient.commands.length, 2);
	assert.match(transient.commands[1], /--ipv4 --noproxy '\*'/);

	const permanent = loadWget([
		{
			exitcode: 22,
			stdout: '',
			stderr: 'curl: (22) The requested URL returned error: 404'
		}
	]);
	assert.equal(permanent.wGET('https://example.invalid/rx2', '', '1'), null);
	assert.equal(permanent.commands.length, 1);
	assert.ok(permanent.commands.every((command) => !command.includes('/usr/bin/wget')));
});

test('wGET stops after the bounded proxy and direct reads when both fail', () => {
	const { wGET, commands } = loadWget([
		{
			exitcode: 56,
			stdout: '',
			stderr: 'curl: (56) Recv failure: Connection reset by peer'
		},
		{
			exitcode: 56,
			stdout: '',
			stderr: 'curl: (56) Recv failure: Connection reset by peer'
		}
	]);

	assert.equal(wGET('https://example.invalid/rx2', '', '1'), null);
	assert.equal(commands.length, 2);
});

test('wGET never accepts partial output from a failed read', () => {
	const { wGET, commands } = loadWget([
		{
			exitcode: 56,
			stdout: 'partial-node-list',
			stderr: 'curl: (56) Recv failure: Connection reset by peer'
		},
		{ exitcode: 7, stdout: 'also-partial', stderr: 'curl: (7) Failed to connect' }
	]);

	assert.equal(wGET('https://example.invalid/rx2', '', '1'), null);
	assert.equal(commands.length, 2);
});
