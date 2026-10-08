/*
 * SPDX-License-Identifier: GPL-2.0-only
 *
 * Copyright (C) 2023 ImmortalWrt.org
 */

import { mkstemp } from 'fs';
import { urldecode_params } from 'luci.http';

/* Global variables start */
export const HP_DIR = '/etc/homeproxy-ce';
export const RUN_DIR = '/var/run/homeproxy-ce';
/* Global variables end */

/* Utilities start */
/* Kanged from luci-app-commands */
export function shellQuote(s) {
	return `'${replace(s, "'", "'\\''")}'`;
};

export function isBinary(str) {
	for (let off = 0, byte = ord(str); off < length(str); byte = ord(str, ++off))
		if (byte <= 8 || (byte >= 14 && byte <= 31))
			return true;

	return false;
};

export function executeCommand(...args) {
	let outfd = mkstemp();
	let errfd = mkstemp();

	const exitcode = system(`${join(' ', args)} >&${outfd.fileno()} 2>&${errfd.fileno()}`);

	outfd.seek(0);
	errfd.seek(0);

	const stdout = outfd.read(1024 * 512) ?? '';
	const stderr = errfd.read(1024 * 512) ?? '';

	outfd.close();
	errfd.close();

	const binary = isBinary(stdout);

	return {
		command: join(' ', args),
		stdout: binary ? null : stdout,
		stderr,
		exitcode,
		binary
	};
};

export function getTime(epoch) {
	const local_time = localtime(epoch);
	return replace(replace(sprintf(
		'%d-%2d-%2d@%2d:%2d:%2d',
		local_time.year,
		local_time.mon,
		local_time.mday,
		local_time.hour,
		local_time.min,
		local_time.sec
	), ' ', '0'), '@', ' ');

};

export function wGET(url, ua, via_proxy) {
	if (!url || type(url) !== 'string')
		return null;

	if (!ua)
		ua = 'Wget/1.21 (HomeProxy, like v2rayN)';

	/*
	 * When the service stays up for an update, use its mixed HTTP inbound
	 * explicitly.  The redirect inbound is on 5331 and cannot be used as an
	 * HTTP CONNECT proxy; relying on transparent interception also makes
	 * source fetches depend on the current firewall state.  Keep the original
	 * wget path as a fallback for installations without curl and for updates
	 * that intentionally stop the service first.
	 */
	let output;
	if (via_proxy === '1') {
		/*
		 * A subscription read is safe to retry, but the retry must not turn a
		 * refresh into an unbounded wait.  Try the configured inbound once for
		 * 20 seconds, then make one direct IPv4 read for 10 seconds.  This keeps
		 * the existing 30-second aggregate budget and avoids retry loops while
		 * still recovering when the proxy's TLS path is the failing hop.
		 */
		output = executeCommand(`/usr/bin/curl --silent --show-error --location --fail --connect-timeout 10 --max-time 20 --proxy http://127.0.0.1:5330 --user-agent ${shellQuote(ua)} --output - ${shellQuote(url)}`) || {};
		if (output.exitcode === 0)
			return trim(output.stdout || '');

		/* Keep the original fallback for systems without curl. */
		if (output.exitcode === 127)
			output = null;
		else {
			const stderr = output.stderr || '';
			const retryable_network = output.exitcode === 6 || output.exitcode === 7 ||
				output.exitcode === 18 || output.exitcode === 28 || output.exitcode === 35 ||
				output.exitcode === 52 || output.exitcode === 55 || output.exitcode === 56 ||
				match(stderr, /connection reset|reset by peer|recv failure|empty reply|transfer closed|timed out/i) != null;
			const retryable_http = output.exitcode === 22 &&
				match(stderr, /error: (408|429|500|502|503|504)([^0-9]|$)/) != null;

			if (retryable_network || retryable_http)
				output = executeCommand(`/usr/bin/curl --silent --show-error --location --fail --ipv4 --noproxy '*' --connect-timeout 5 --max-time 10 --user-agent ${shellQuote(ua)} --output - ${shellQuote(url)}`) || {};
			else
				return null;
		}

		if (output && output.exitcode !== 127) {
			if (output.exitcode === 0)
				return trim(output.stdout || '');
			return null;
		}
	}

	output = executeCommand(`/usr/bin/wget -qO- --user-agent ${shellQuote(ua)} --timeout=10 ${shellQuote(url)}`) || {};
	return output.stdout ? trim(output.stdout) : null;
};
/* Utilities end */

/* String helper start */
export function isEmpty(res) {
	return !res || res === 'nil' || (type(res) in ['array', 'object'] && length(res) === 0);
};

export function strToBool(str) {
	return (str === '1') || null;
};

export function strToInt(str) {
	return !isEmpty(str) ? (int(str) || null) : null;
};

export function strToTime(str) {
	return !isEmpty(str) ? (str + 's') : null;
};

export function removeBlankAttrs(res) {
	let content;

	if (type(res) === 'object') {
		content = {};
		map(keys(res), (k) => {
			if (type(res[k]) in ['array', 'object'])
				content[k] = removeBlankAttrs(res[k]);
			else if (res[k] !== null && res[k] !== '')
				content[k] = res[k];
		});
	} else if (type(res) === 'array') {
		content = [];
		map(res, (k, i) => {
			if (type(k) in ['array', 'object'])
				push(content, removeBlankAttrs(k));
			else if (k !== null && k !== '')
				push(content, k);
		});
	} else
		return res;

	return content;
};

export function validateHostname(hostname) {
	return (match(hostname, /^[a-zA-Z0-9_]+$/) != null ||
		(match(hostname, /^[a-zA-Z0-9_][a-zA-Z0-9_%-.]*[a-zA-Z0-9]$/) &&
			match(hostname, /[^0-9.]/)));
};

export function validation(datatype, data) {
	if (!datatype || !data)
		return null;

	const ret = system(`/sbin/validate_data ${shellQuote(datatype)} ${shellQuote(data)} 2>/dev/null`);
	return (ret === 0);
};
/* String helper end */

/* String parser start */
export function decodeBase64Str(str) {
	if (isEmpty(str))
		return null;

	str = trim(str);
	str = replace(str, '_', '/');
	str = replace(str, '-', '+');

	const padding = length(str) % 4;
	if (padding)
		str = str + substr('====', padding);

	return b64dec(str);
};

export function parseURL(url) {
	if (type(url) !== 'string')
		return null;

	const services = {
		http: '80',
		https: '443'
	};

	const objurl = {};

	objurl.href = url;

	url = replace(url, /#(.+)$/, (_, val) => {
		objurl.hash = val;
		return '';
	});

	url = replace(url, /^(\w[A-Za-z0-9\+\-\.]+):/, (_, val) => {
		objurl.protocol = val;
		return '';
	});

	url = replace(url, /\?(.+)/, (_, val) => {
		objurl.search = val;
		objurl.searchParams = urldecode_params(val);
		return '';
	});

	url = replace(url, /^\/\/([^\/]+)/, (_, val) => {
		val = replace(val, /^([^@]+)@/, (_, val) => {
			objurl.userinfo = val;
			return '';
		});

		val = replace(val, /:(\d+)$/, (_, val) => {
			objurl.port = val;
			return '';
		});

		if (validation('ip4addr', val) ||
		    validation('ip6addr', replace(val, /\[|\]/g, '')) ||
		    validation('hostname', val))
			objurl.hostname = val;

		return '';
	});

	objurl.pathname = url || '/';

	if (!objurl.protocol || !objurl.hostname)
		return null;

	if (objurl.userinfo) {
		objurl.userinfo = replace(objurl.userinfo, /:(.+)$/, (_, val) => {
			objurl.password = val;
			return '';
		});

		if (match(objurl.userinfo, /^([A-Za-z0-9\+\-\_\.]|%[A-Za-z0-9]{2})+$/)) {
			objurl.username = objurl.userinfo;
			delete objurl.userinfo;
		} else {
			delete objurl.userinfo;
			delete objurl.password;
		}
	};

	if (!objurl.port)
		objurl.port = services[objurl.protocol];

	objurl.host = objurl.hostname + (objurl.port ? `:${objurl.port}` : '');
	objurl.origin = `${objurl.protocol}://${objurl.host}`;

	return objurl;
};
/* String parser end */

/* Outbound group graph helpers start */
const builtin_outbound_tags = {
	'direct-out': true,
	'block-out': true
};

export function allocateUniqueOutboundTag(used_tags, label, id) {
	const base = label || id;
	let tag = base;
	let suffix = 2;

	if (used_tags[tag])
		tag = `${base} [${id}]`;

	while (used_tags[tag]) {
		tag = `${base} [${id}-${suffix}]`;
		suffix++;
	}

	used_tags[tag] = true;
	return tag;
};

export function buildNodeReferenceIndex(nodes) {
	let index = {
		by_id: {},
		by_label: {},
		tag_by_id: {},
		used_tags: {
			'direct-out': true,
			'block-out': true,
			'main-out': true,
			'main-udp-out': true,
			'dns-out': true,
			'GLOBAL': true,
			'DIRECT': true,
			'REJECT': true
		}
	};

	for (let i = 0; i < length(nodes || []); i++) {
		const node = nodes[i];
		const id = node['.name'];

		index.by_id[id] = node;
		if (node.label) {
			if (!index.by_label[node.label])
				index.by_label[node.label] = [];

			const matches = index.by_label[node.label];
			matches[length(matches)] = id;
		}
	}

	for (let i = 0; i < length(nodes || []); i++) {
		const node = nodes[i];
		const id = node['.name'];
		let label = node.label || id;

		if (node.label && length(index.by_label[node.label] || []) > 1)
			label = `${label} [${id}]`;

		index.tag_by_id[id] = allocateUniqueOutboundTag(index.used_tags, label, id);
	}

	return index;
};

export function resolveNodeReference(node_index, reference) {
	if (builtin_outbound_tags[reference])
		return {
			status: 'ok',
			id: reference,
			tag: reference
		};

	if (node_index.by_id[reference])
		return {
			status: 'ok',
			id: reference,
			tag: node_index.tag_by_id[reference]
		};

	const matches = node_index.by_label[reference] || [];
	if (length(matches) === 1)
		return {
			status: 'ok',
			id: matches[0],
			tag: node_index.tag_by_id[matches[0]]
		};

	return length(matches) > 1
		? {
			status: 'ambiguous',
			reference,
			matches
		}
		: {
			status: 'missing',
			reference
		};
};

export function normalizeNodeGroup(group, node_index) {
	let outbounds = [];
	const references = group.outbounds || [];

	for (let i = 0; i < length(references); i++) {
		const reference = references[i];
		const resolved = resolveNodeReference(node_index, reference);
		if (resolved.status !== 'ok')
			return resolved;

		if (resolved.id === group['.name'])
			return {
				status: 'error',
				kind: 'self-reference',
				reference
			};

		let duplicate = false;
		for (let j = 0; j < length(outbounds); j++) {
			if (outbounds[j] === resolved.id) {
				duplicate = true;
				break;
			}
		}
		if (!duplicate)
			outbounds[length(outbounds)] = resolved.id;
	}

	if (!length(outbounds))
		return {
			status: 'error',
			kind: 'empty-group',
			reference: group['.name']
		};

	let default_id = null;
	if (group.default) {
		const resolved_default = resolveNodeReference(node_index, group.default);
		if (resolved_default.status !== 'ok')
			return resolved_default;

		default_id = resolved_default.id;
		let default_member = false;
		for (let i = 0; i < length(outbounds); i++) {
			if (outbounds[i] === default_id) {
				default_member = true;
				break;
			}
		}
		if (!default_member)
			return {
				status: 'error',
				kind: 'invalid-default',
				reference: group.default
			};
	}

	return {
		status: 'ok',
		outbounds,
		default: default_id
	};
};

export function planNodeDependencies(node_index, roots) {
	let visiting = {};
	let visited = {};
	let path = [];
	let path_length = 0;
	let order = [];

	function copyActivePath() {
		let trace = [];
		for (let i = 0; i < path_length; i++)
			trace[length(trace)] = path[i];
		return trace;
	}

	function asError(result) {
		return {
			status: 'error',
			kind: result.status === 'error' ? result.kind : result.status,
			reference: result.reference,
			path: copyActivePath()
		};
	}

	function copyPathFrom(id) {
		let start = 0;
		for (let i = 0; i < path_length; i++) {
			if (path[i] === id) {
				start = i;
				break;
			}
		}

		let cycle = [];
		for (let i = start; i < path_length; i++)
			cycle[length(cycle)] = path[i];
		cycle[length(cycle)] = id;
		return cycle;
	}

	function visit(reference) {
		const resolved = resolveNodeReference(node_index, reference);
		if (resolved.status !== 'ok')
			return asError(resolved);

		const id = resolved.id;
		if (builtin_outbound_tags[id])
			return null;

		if (visiting[id])
			return {
				status: 'error',
				kind: 'cycle',
				reference: id,
				path: copyPathFrom(id)
			};

		if (visited[id])
			return null;

		const node = node_index.by_id[id];
		if (node.type === 'selector' || node.type === 'urltest') {
			visiting[id] = true;
			path[path_length] = id;
			path_length++;

			const normalized = normalizeNodeGroup(node, node_index);
			if (normalized.status !== 'ok')
				return asError(normalized);

			for (let i = 0; i < length(normalized.outbounds); i++) {
				const error = visit(normalized.outbounds[i]);
				if (error)
					return error;
			}

			visiting[id] = false;
			visited[id] = true;
			path_length--;
			path[path_length] = null;
			order[length(order)] = id;
			return null;
		}

		visited[id] = true;
		order[length(order)] = id;
		return null;
	}

	for (let i = 0; i < length(roots || []); i++) {
		const error = visit(roots[i]);
		if (error)
			return error;
	}

	return {
		status: 'ok',
		order
	};
};
/* Outbound group graph helpers end */
