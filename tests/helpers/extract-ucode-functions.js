'use strict';

const vm = require('node:vm');

function escapeRegExp(value) {
	return value.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
}

function findFunctionStart(source, name) {
	const pattern = new RegExp(
		`(?:^|\\n)[\\t ]*(?:export\\s+)?function\\s+${escapeRegExp(name)}\\s*\\(`,
		'm'
	);
	const match = pattern.exec(source);
	if (!match)
		throw new Error(`Cannot find function ${name}`);

	const functionOffset = match[0].search(/(?:export\s+)?function/);
	return match.index + functionOffset;
}

function findFunctionEnd(source, openBrace) {
	let depth = 0;
	let quote = null;
	let escaped = false;
	let lineComment = false;
	let blockComment = false;

	for (let offset = openBrace; offset < source.length; offset++) {
		const character = source[offset];
		const next = source[offset + 1];

		if (lineComment) {
			if (character === '\n')
				lineComment = false;
			continue;
		}

		if (blockComment) {
			if (character === '*' && next === '/') {
				blockComment = false;
				offset++;
			}
			continue;
		}

		if (quote) {
			if (escaped) {
				escaped = false;
			} else if (character === '\\') {
				escaped = true;
			} else if (character === quote) {
				quote = null;
			}
			continue;
		}

		if (character === '/' && next === '/') {
			lineComment = true;
			offset++;
			continue;
		}
		if (character === '/' && next === '*') {
			blockComment = true;
			offset++;
			continue;
		}
		if (character === "'" || character === '"' || character === '`') {
			quote = character;
			continue;
		}

		if (character === '{') {
			depth++;
		} else if (character === '}') {
			depth--;
			if (depth === 0)
				return offset;
		}
	}

	throw new Error('Unbalanced function braces');
}

function extractFunctionSource(source, name) {
	const start = findFunctionStart(source, name);
	const openBrace = source.indexOf('{', start);
	if (openBrace < 0)
		throw new Error(`Function ${name} has no body`);

	const end = findFunctionEnd(source, openBrace);
	return source.slice(start, end + 1);
}

function extractUcodeFunctions(source, names, context = {}) {
	const bodies = names.map((name) => extractFunctionSource(source, name).replace(/^export\s+/, ''));
	return vm.runInNewContext(
		`(() => { ${bodies.join('\n')} return { ${names.join(', ')} }; })()`,
		context
	);
}

module.exports = { extractFunctionSource, extractUcodeFunctions };
