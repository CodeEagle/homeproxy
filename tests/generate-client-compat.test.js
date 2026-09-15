const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const test = require('node:test');

const source = fs.readFileSync(
	path.join(__dirname, '..', 'root/etc/homeproxy-ce/scripts/generate_client.uc'),
	'utf8'
);

function extractFunction(name) {
	const marker = `function ${name}(`;
	const start = source.indexOf(marker);
	assert.notEqual(start, -1, `${name} should be defined in the generator`);

	let braces = 0;
	let bodyStart = source.indexOf('{', start);
	let bodyEnd = -1;
	for (let i = bodyStart; i < source.length; i++) {
		if (source[i] === '{')
			braces++;
		else if (source[i] === '}' && --braces === 0) {
			bodyEnd = i + 1;
			break;
		}
	}
	assert.notEqual(bodyEnd, -1, `${name} should have a complete function body`);

	const context = {
		length: value => value.length,
		push: (array, value) => array.push(value)
	};
	return vm.runInNewContext(`(${source.slice(start, bodyEnd)})`, context);
}

test('modern sniff rules cover proxy inbounds and exclude DNS inbound', () => {
	const addSniffRules = extractFunction('add_modern_sniff_rules');
	const rules = addSniffRules([], [
		'dns-in',
		'mixed-in',
		'redirect-in',
		'tproxy-in',
		'tun-in'
	]);

	assert.deepEqual(JSON.parse(JSON.stringify(rules)), [
		{ inbound: 'mixed-in', action: 'sniff' },
		{ inbound: 'redirect-in', action: 'sniff' },
		{ inbound: 'tproxy-in', action: 'sniff' },
		{ inbound: 'tun-in', action: 'sniff' }
	]);
});

test('modern block-dns rule becomes NXDOMAIN while preserving matchers', () => {
	const normalizeDnsRule = extractFunction('normalize_dns_rule_for_core');
	const rule = {
		domain_suffix: ['blocked.example'],
		rule_set: ['cfg-block-rule'],
		outbound: 'any',
		server: 'block-dns',
		action: 'route',
		strategy: 'prefer_ipv4',
		disable_cache: true,
		rewrite_ttl: 60,
		client_subnet: '1.1.1.1',
		method: 'drop',
		no_drop: true
	};
	const legacyRule = structuredClone(rule);
	const modernRule = structuredClone(rule);

	assert.deepEqual(normalizeDnsRule(modernRule, false), {
		domain_suffix: ['blocked.example'],
		rule_set: ['cfg-block-rule'],
		outbound: 'any',
		action: 'predefined',
		rcode: 'NXDOMAIN'
	});
	assert.deepEqual(normalizeDnsRule(legacyRule, true), {
		domain_suffix: ['blocked.example'],
		rule_set: ['cfg-block-rule'],
		outbound: 'any',
		server: 'block-dns',
		action: 'route',
		strategy: 'prefer_ipv4',
		disable_cache: true,
		rewrite_ttl: 60,
		client_subnet: '1.1.1.1',
		method: 'drop',
		no_drop: true
	});
});

test('unsupported modern block-dns resolver explains the required migration', () => {
	const unsupported = extractFunction('unsupported_dns_resolver_message');

	assert.match(
		unsupported('block-dns', 'route.default_domain_resolver'),
		/1\.13\+.*block-dns.*predefined.*NXDOMAIN/i
	);
});

test('procd keeps deprecated outbound DNS rule compatibility enabled', () => {
	const init = fs.readFileSync(
		path.join(__dirname, '..', 'root/etc/init.d/homeproxy-ce'),
		'utf8'
	);

	assert.match(init, /export ENABLE_DEPRECATED_OUTBOUND_DNS_RULE_ITEM=true/);
	assert.match(init, /procd_append_param env ENABLE_DEPRECATED_OUTBOUND_DNS_RULE_ITEM=true/);
});
