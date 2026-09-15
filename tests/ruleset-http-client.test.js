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
	const bodyStart = source.indexOf('{', start);
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

	return vm.runInNewContext(`(${source.slice(start, bodyEnd)})`);
}

test('modern remote rule-sets use an HTTP client detour instead of deprecated download_detour', () => {
	const normalizeDownload = extractFunction('normalize_rule_set_download');
	const ruleSet = {
		type: 'remote',
		download_detour: 'main-out'
	};

	assert.deepEqual(JSON.parse(JSON.stringify(normalizeDownload(ruleSet, 'main-out', true))), {
		type: 'remote',
		http_client: { detour: 'main-out' }
	});
});

test('legacy remote rule-sets retain download_detour for sing-box before 1.14', () => {
	const normalizeDownload = extractFunction('normalize_rule_set_download');
	const ruleSet = {
		type: 'remote',
		download_detour: 'main-out'
	};

	assert.deepEqual(normalizeDownload(ruleSet, 'main-out', false), {
		type: 'remote',
		download_detour: 'main-out'
	});
});

test('non-remote rule-sets do not receive remote download fields', () => {
	const normalizeDownload = extractFunction('normalize_rule_set_download');
	const ruleSet = {
		type: 'local',
		download_detour: 'main-out',
		http_client: { detour: 'main-out' }
	};

	assert.deepEqual(JSON.parse(JSON.stringify(normalizeDownload(ruleSet, 'main-out', true))), {
		type: 'local'
	});
});
