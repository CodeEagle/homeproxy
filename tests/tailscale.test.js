const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const test = require('node:test');

const generatorSource = fs.readFileSync(
	path.join(__dirname, '..', 'root/etc/homeproxy-ce/scripts/generate_client.uc'),
	'utf8'
);
const firewallTemplate = fs.readFileSync(
	path.join(__dirname, '..', 'root/etc/homeproxy-ce/scripts/firewall_post.ut'),
	'utf8'
);

function extractFunction(name, extra = {}) {
	const marker = `function ${name}(`;
	const start = generatorSource.indexOf(marker);
	assert.notEqual(start, -1, `${name} should be defined in the generator`);

	let braces = 0;
	const bodyStart = generatorSource.indexOf('{', start);
	let bodyEnd = -1;
	for (let i = bodyStart; i < generatorSource.length; i++) {
		if (generatorSource[i] === '{')
			braces++;
		else if (generatorSource[i] === '}' && --braces === 0) {
			bodyEnd = i + 1;
			break;
		}
	}
	assert.notEqual(bodyEnd, -1, `${name} should have a complete function body`);

	const context = {
		die: message => { throw new Error(message); },
		int: value => Number.parseInt(value, 10),
		length: value => value.length,
		match: (value, pattern) => value.match(pattern),
		push: (array, value) => array.push(value),
		validation: (datatype, value) => {
			if (datatype === 'ip4addr')
				return /^(?:25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)(?:\.(?:25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)){3}$/.test(value);
			if (datatype === 'port')
				return /^[0-9]+$/.test(value) && Number(value) <= 65535;
			return datatype === 'ip6addr' && /^[0-9A-Fa-f:.]+$/.test(value);
		},
		validate_tailscale_port: value => /^[0-9]+$/.test(value) && Number(value) >= 1 && Number(value) <= 65535,
		type: value => Array.isArray(value) ? 'array' : typeof value === 'object' ? 'object' : typeof value,
		...extra
	};
	return vm.runInNewContext(`(${generatorSource.slice(start, bodyEnd)})`, context);
}

test('disabled Tailscale returns no endpoint', () => {
	const generateEndpoint = extractFunction('generate_tailscale_endpoint');

	assert.equal(generateEndpoint({ enabled: '0' }, true), null);
});

test('Tailscale CIDR validation accepts the LAN prefix and rejects malformed IPv4', () => {
	const validateCidr = extractFunction('validate_tailscale_cidr');

	assert.equal(validateCidr('192.168.6.0/24'), true);
	assert.equal(validateCidr('192.168.6.0/33'), false);
	assert.equal(validateCidr('192.168.6/24'), false);
});

test('Tailscale listen port validation is strict and bounded', () => {
	const validatePort = extractFunction('validate_tailscale_port');

	assert.equal(validatePort('41641'), true);
	assert.equal(validatePort('1'), true);
	assert.equal(validatePort('65535'), true);
	assert.equal(validatePort('0'), false);
	assert.equal(validatePort('65536'), false);
	assert.equal(validatePort('41641x'), false);
});

test('enabled Tailscale endpoint uses persistent userspace settings', () => {
	const generateEndpoint = extractFunction('generate_tailscale_endpoint', {
		validate_tailscale_cidr: extractFunction('validate_tailscale_cidr'),
		validate_tailscale_port: extractFunction('validate_tailscale_port')
	});
	const endpoint = generateEndpoint({
		enabled: '1',
		hostname: 'immortalwrt-home',
		listen_port: '41641',
		advertise_routes: ['192.168.6.0/24']
	}, true, true);

	assert.deepEqual(JSON.parse(JSON.stringify(endpoint)), {
		type: 'tailscale',
		tag: 'tailscale-ep',
		listen_port: 41641,
		state_directory: '/etc/homeproxy-ce/tailscale',
		control_url: 'https://controlplane.tailscale.com',
		ephemeral: false,
		hostname: 'immortalwrt-home',
		accept_routes: false,
		advertise_routes: ['192.168.6.0/24'],
		advertise_exit_node: false,
		detour: 'direct-out'
	});
	assert.equal('auth_key' in endpoint, false, 'auth keys must not be persisted in UCI or JSON');
	assert.equal('system_interface' in endpoint, false, 'userspace mode must not request a system TUN');
});

test('legacy Tailscale endpoint keeps the old shape without listen_port', () => {
	const generateEndpoint = extractFunction('generate_tailscale_endpoint', {
		validate_tailscale_cidr: extractFunction('validate_tailscale_cidr'),
		validate_tailscale_port: extractFunction('validate_tailscale_port')
	});
	const endpoint = generateEndpoint({ enabled: '1' }, true, false);

	assert.equal('listen_port' in endpoint, false);
});

test('enabled Tailscale rejects a non numeric listen port', () => {
	const generateEndpoint = extractFunction('generate_tailscale_endpoint', {
		validate_tailscale_cidr: extractFunction('validate_tailscale_cidr'),
		validate_tailscale_port: extractFunction('validate_tailscale_port')
	});

	assert.throws(
		() => generateEndpoint({ enabled: '1', listen_port: '41641x' }, true, true),
		/invalid Tailscale listen_port.*41641x/i
	);
});

test('enabled Tailscale fails clearly when the core lacks with_tailscale', () => {
	const generateEndpoint = extractFunction('generate_tailscale_endpoint', {
		validate_tailscale_cidr: extractFunction('validate_tailscale_cidr'),
		validate_tailscale_port: extractFunction('validate_tailscale_port')
	});

	assert.throws(
		() => generateEndpoint({ enabled: '1' }, false),
		/Tailscale is enabled.*with_tailscale.*disable.*install/i
	);
});

test('invalid Tailscale CIDR fails before endpoint generation', () => {
	const generateEndpoint = extractFunction('generate_tailscale_endpoint', {
		validate_tailscale_cidr: extractFunction('validate_tailscale_cidr'),
		validate_tailscale_port: extractFunction('validate_tailscale_port')
	});

	assert.throws(
		() => generateEndpoint({ enabled: '1', advertise_routes: ['192.168.6.0/33'] }, true),
		/invalid Tailscale advertise_routes CIDR.*192\.168\.6\.0\/33/i
	);
});

test('Tailscale routes allow advertised LAN CIDRs and reject other ingress first', () => {
	const addRoutes = extractFunction('add_tailscale_routes');
	const rules = addRoutes([], ['192.168.6.0/24', 'fd00:6::/64']);

	assert.deepEqual(JSON.parse(JSON.stringify(rules)), [
		{
			inbound: 'tailscale-ep',
			ip_cidr: ['192.168.6.0/24', 'fd00:6::/64'],
			action: 'route',
			outbound: 'direct-out'
		},
		{
			inbound: 'tailscale-ep',
			action: 'reject'
		}
	]);
});

test('Tailscale route insertion runs before built in route rules', () => {
	const insertion = generatorSource.indexOf('add_tailscale_routes(config.route.rules');
	const builtInRules = generatorSource.indexOf('if (legacy_route_rule_format)', insertion);

	assert.ok(insertion >= 0, 'Tailscale route insertion should be present');
	assert.ok(builtInRules > insertion, 'Tailscale routes should be inserted first');
});

test('default UCI keeps Tailscale disabled with the LAN route available for opt in', () => {
	const config = fs.readFileSync(
		path.join(__dirname, '..', 'root/etc/config/homeproxy-ce'),
		'utf8'
	);
	const section = config.match(/config homeproxy 'tailscale'([\s\S]*?)(?:\nconfig |\n?$)/);

	assert.ok(section, 'Tailscale UCI section should be present');
	assert.match(section[1], /option enabled '0'/);
	assert.match(section[1], /option listen_port '41641'/);
	assert.match(section[1], /list advertise_routes '192\.168\.6\.0\/24'/);
});

test('firewall exempts only enabled Tailscale output before CE processing', () => {
	assert.match(firewallTemplate, /const tailscale_enabled = uci\.get\(cfgname, 'tailscale', 'enabled'\) \|\| '0'/);
	assert.match(firewallTemplate, /const client_config = json\(readfile\('\/var\/run\/homeproxy-ce\/sing-box-c\.json'\)/);

	const tproxyOutput = firewallTemplate.match(/chain homeproxy_ce_mangle_output \{([\s\S]*?)\n\}/);
	assert.ok(tproxyOutput, 'tproxy output chain should exist');
	assert.ok(
		tproxyOutput[1].indexOf('udp sport {{ tailscale_listen_port }} counter return') <
			tproxyOutput[1].indexOf('meta mark {{ self_mark }}'),
		'Tailscale source-port return must precede CE output marking'
	);

	const tunOutput = firewallTemplate.match(/chain mangle_output \{([\s\S]*?)\n\}/g)?.at(-1);
	assert.ok(tunOutput, 'tun output chain should exist');
	assert.match(tunOutput, /meta l4proto udp udp sport != \{\{ tailscale_listen_port \}\} jump homeproxy_ce_mangle_tun/);
	assert.match(tunOutput, /\{% if \(proxy_mode === 'tun'\): %\}[\s\S]*meta l4proto tcp jump homeproxy_ce_mangle_tun/);
	assert.ok(
		tunOutput.indexOf('meta l4proto udp udp sport != {{ tailscale_listen_port }} jump homeproxy_ce_mangle_tun') <
			tunOutput.indexOf('meta l4proto tcp jump homeproxy_ce_mangle_tun'),
		'Tailscale source-port exclusion must precede the tun output jump'
	);
	assert.match(firewallTemplate, /\{% if \(tailscale_listen_port\): %\}[\s\S]*?udp sport \{\{ tailscale_listen_port \}\} counter return/);
});

test('init persists Tailscale state and keeps the endpoint outside ujail', () => {
	const init = fs.readFileSync(
		path.join(__dirname, '..', 'root/etc/init.d/homeproxy-ce'),
		'utf8'
	);

	assert.match(init, /mkdir -p "\$TAILSCALE_STATE_DIR"/);
	assert.match(init, /chown root:root "\$TAILSCALE_STATE_DIR"/);
	assert.match(init, /chmod 700 "\$TAILSCALE_STATE_DIR"/);
	assert.match(init, /"type": "\(wireguard\|tun\|tailscale\)"/);
});

test('package upgrade retention includes the Tailscale state directory', () => {
	const makefile = fs.readFileSync(path.join(__dirname, '..', 'Makefile'), 'utf8');
	const buildScript = fs.readFileSync(path.join(__dirname, '..', '.github/build-ipk.sh'), 'utf8');

	assert.match(makefile, /\/etc\/homeproxy-ce\/tailscale\//);
	assert.match(buildScript, /\/etc\/homeproxy-ce\/tailscale\//);
});
