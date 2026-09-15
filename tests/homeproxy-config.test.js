const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const test = require('node:test');

const config = fs.readFileSync(
	path.join(__dirname, '..', 'root/etc/config/homeproxy-ce'),
	'utf8'
);

function readRoutingOption(option) {
	const routingSection = config.match(/config homeproxy 'routing'([\s\S]*?)(?:\nconfig |\n?$)/);

	assert.ok(routingSection, 'routing section should be present');

	const optionMatch = routingSection[1].match(
		new RegExp("\\n\\s*option\\s+" + option + "\\s+'([^']*)'")
	);

	assert.ok(optionMatch, `${option} should be set in routing section`);
	return optionMatch[1];
}

test('default custom routing outbound does not force direct connections', () => {
	assert.equal(readRoutingOption('default_outbound'), 'nil');
});
