#!/usr/bin/ucode
/*
 * SPDX-License-Identifier: GPL-2.0-only
 *
 * Copyright (C) 2023-2025 ImmortalWrt.org
 */

'use strict';

import { readfile, writefile } from 'fs';
import { isnan } from 'math';
import { connect } from 'ubus';
import { cursor } from 'uci';

import {
	isEmpty, parseURL, strToBool, strToInt, strToTime,
	removeBlankAttrs, validation, buildNodeReferenceIndex, resolveNodeReference,
	normalizeNodeGroup, planNodeDependencies, HP_DIR, RUN_DIR
} from 'homeproxy';

const ubus = connect();
const features = ubus.call('luci.homeproxyce', 'singbox_get_features', {}) || {};

function version_lt(version, major, minor) {
	if (isEmpty(version))
		return false;

	const matched = match(version, /^[0-9.]+/);
	const parts = split(matched ? matched[0] : '', '.');
	const cur_major = int(parts[0] || '0');
	const cur_minor = int(parts[1] || '0');

	if (cur_major !== int(major))
		return cur_major < int(major);

	return cur_minor < int(minor);
}

const legacy_dns_server_format = version_lt(features.version, 1, 13);
const legacy_dns_resolver_field = version_lt(features.version, 1, 13);
const legacy_route_rule_format = version_lt(features.version, 1, 11);
const legacy_inbound_sniff_fields = version_lt(features.version, 1, 13);
const legacy_rule_set_download_detour = version_lt(features.version, 1, 14);
const legacy_tailscale_listen_port = version_lt(features.version, 1, 14);

/* UCI config start */
const uci = cursor();

const uciconfig = 'homeproxy-ce';
uci.load(uciconfig);

const uciinfra = 'infra',
      ucimain = 'config',
      uciexp = 'experimental',
      ucicontrol = 'control';

const ucidnssetting = 'dns',
      ucidnsserver = 'dns_server',
      ucidnsrule = 'dns_rule';

const uciroutingsetting = 'routing',
      uciroutingnode = 'routing_node',
      uciroutingrule = 'routing_rule';

const ucinode = 'node';
const uciruleset = 'ruleset';

const routing_mode = uci.get(uciconfig, ucimain, 'routing_mode') || 'bypass_mainland_china';

let wan_dns = ubus.call('network.interface', 'status', {'interface': 'wan'})?.['dns-server']?.[0];
if (!wan_dns)
	wan_dns = (routing_mode in ['proxy_mainland_china', 'global']) ? '8.8.8.8' : '223.5.5.5';

const dns_port = uci.get(uciconfig, uciinfra, 'dns_port') || '5333';

const ntp_server = uci.get(uciconfig, uciinfra, 'ntp_server') || 'time.apple.com';

const ipv6_support = uci.get(uciconfig, ucimain, 'ipv6_support') || '0';

let main_node, main_udp_node, dedicated_udp_node, default_outbound, default_outbound_dns,
    domain_strategy, sniff_override, dns_server, china_dns_server, dns_default_strategy,
    dns_default_server, dns_disable_cache, dns_disable_cache_expire, dns_independent_cache,
    dns_client_subnet, cache_file_store_rdrc, cache_file_rdrc_timeout, direct_domain_list,
    proxy_domain_list;

const enable_clash_api = uci.get(uciconfig, uciexp, 'enable_clash_api'),
      external_controller = uci.get(uciconfig, uciexp, 'external_controller'),
      external_ui = uci.get(uciconfig, uciexp, 'external_ui'),
      external_ui_download_url = uci.get(uciconfig, uciexp, 'external_ui_download_url'),
      external_ui_download_detour = uci.get(uciconfig, uciexp, 'external_ui_download_detour'),
      secret = uci.get(uciconfig, uciexp, 'secret'),
      default_mode = uci.get(uciconfig, uciexp, 'default_mode');

if (routing_mode !== 'custom') {
	main_node = uci.get(uciconfig, ucimain, 'main_node') || 'nil';
	main_udp_node = uci.get(uciconfig, ucimain, 'main_udp_node') || 'nil';
	dedicated_udp_node = !isEmpty(main_udp_node) && !(main_udp_node in ['same', main_node]);

	dns_server = uci.get(uciconfig, ucimain, 'dns_server');
	if (isEmpty(dns_server) || dns_server === 'wan')
		dns_server = wan_dns;

	if (routing_mode === 'bypass_mainland_china') {
		china_dns_server = uci.get(uciconfig, ucimain, 'china_dns_server');
		if (isEmpty(china_dns_server) || type(china_dns_server) !== 'string' || china_dns_server === 'wan')
			china_dns_server = wan_dns;
	}
	dns_default_strategy = (ipv6_support !== '1') ? 'ipv4_only' : null;

	direct_domain_list = trim(readfile(HP_DIR + '/resources/direct_list.txt'));
	if (direct_domain_list)
		direct_domain_list = split(direct_domain_list, /[\r\n]/);

	proxy_domain_list = trim(readfile(HP_DIR + '/resources/proxy_list.txt'));
	if (proxy_domain_list)
		proxy_domain_list = split(proxy_domain_list, /[\r\n]/);

	sniff_override = uci.get(uciconfig, uciinfra, 'sniff_override') || '1';
} else {
	/* DNS settings */
	dns_default_strategy = uci.get(uciconfig, ucidnssetting, 'default_strategy');
	dns_default_server = uci.get(uciconfig, ucidnssetting, 'default_server');
	dns_disable_cache = uci.get(uciconfig, ucidnssetting, 'disable_cache');
	dns_disable_cache_expire = uci.get(uciconfig, ucidnssetting, 'disable_cache_expire');
	dns_independent_cache = uci.get(uciconfig, ucidnssetting, 'independent_cache');
	dns_client_subnet = uci.get(uciconfig, ucidnssetting, 'client_subnet');
	cache_file_store_rdrc = uci.get(uciconfig, ucidnssetting, 'cache_file_store_rdrc'),
	cache_file_rdrc_timeout = uci.get(uciconfig, ucidnssetting, 'cache_file_rdrc_timeout');

	/* Routing settings */
	default_outbound = uci.get(uciconfig, uciroutingsetting, 'default_outbound') || 'nil';
	default_outbound_dns = uci.get(uciconfig, uciroutingsetting, 'default_outbound_dns') || 'default-dns';
	domain_strategy = uci.get(uciconfig, uciroutingsetting, 'domain_strategy');
	sniff_override = uci.get(uciconfig, uciroutingsetting, 'sniff_override');
}

const proxy_mode = uci.get(uciconfig, ucimain, 'proxy_mode') || 'redirect_tproxy',
      default_interface = uci.get(uciconfig, ucicontrol, 'bind_interface');

const mixed_port = uci.get(uciconfig, uciinfra, 'mixed_port') || '5330';

let self_mark, redirect_port, tproxy_port, tun_name,
    tun_addr4, tun_addr6, tun_mtu, tcpip_stack,
    endpoint_independent_nat, udp_timeout;

if (routing_mode === 'custom')
	udp_timeout = uci.get(uciconfig, uciroutingsetting, 'udp_timeout');
else
	udp_timeout = uci.get(uciconfig, 'infra', 'udp_timeout');

if (match(proxy_mode, /redirect/)) {
	self_mark = uci.get(uciconfig, 'infra', 'self_mark') || '100';
	redirect_port = uci.get(uciconfig, 'infra', 'redirect_port') || '5331';
}
if (match(proxy_mode, /tproxy/))
	if (main_udp_node !== 'nil' || routing_mode === 'custom')
		tproxy_port = uci.get(uciconfig, 'infra', 'tproxy_port') || '5332';
if (match(proxy_mode, /tun/)) {
	tun_name = uci.get(uciconfig, uciinfra, 'tun_name') || 'singtun0';
	tun_addr4 = uci.get(uciconfig, uciinfra, 'tun_addr4') || '172.19.0.1/30';
	tun_addr6 = uci.get(uciconfig, uciinfra, 'tun_addr6') || 'fdfe:dcba:9876::1/126';
	tun_mtu = uci.get(uciconfig, uciinfra, 'tun_mtu') || '9000';
	tcpip_stack = 'system';
	if (routing_mode === 'custom') {
		tcpip_stack = uci.get(uciconfig, uciroutingsetting, 'tcpip_stack') || 'system';
		endpoint_independent_nat = uci.get(uciconfig, uciroutingsetting, 'endpoint_independent_nat');
	}
}

const log_level = uci.get(uciconfig, ucimain, 'log_level') || 'warn';
/* UCI config end */

/* Config helper start */
function parse_port(strport) {
	if (type(strport) !== 'array' || isEmpty(strport))
		return null;

	let ports = [];
	for (let i in strport)
		push(ports, int(i));

	return ports;

}

function parse_dnsserver(server_addr, default_protocol) {
	if (isEmpty(server_addr))
		return null;

	if (!match(server_addr, /:\/\//))
		server_addr = (default_protocol || 'udp') + '://' + (validation('ip6addr', server_addr) ? `[${server_addr}]` : server_addr);
	server_addr = parseURL(server_addr);

	if (legacy_dns_server_format)
		return {
			address: sprintf(
				'%s://%s%s%s',
				server_addr.protocol,
				server_addr.hostname,
				server_addr.port ? `:${server_addr.port}` : '',
				(server_addr.pathname && server_addr.pathname !== '/') ? server_addr.pathname : ''
			)
		};

	return {
		type: server_addr.protocol,
		server: server_addr.hostname,
		server_port: strToInt(server_addr.port),
		path: (server_addr.pathname !== '/') ? server_addr.pathname : null,
	}
}

function apply_dns_resolver(server, resolver, strategy) {
	if (!resolver && !strategy)
		return server;

	if (legacy_dns_server_format || legacy_dns_resolver_field) {
		server.address_resolver = resolver;
		server.address_strategy = strategy;
	} else {
		server.domain_resolver = {
			server: resolver,
			strategy: strategy
		};
	}

	return server;
}

function parse_dnsquery(strquery) {
	if (type(strquery) !== 'array' || isEmpty(strquery))
		return null;

	let querys = [];
	for (let i in strquery)
		isnan(int(i)) ? push(querys, i) : push(querys, int(i));

	return querys;

}

function add_modern_sniff_rules(rules, inbound_tags) {
	for (let i = 0; i < length(inbound_tags); i++) {
		if (inbound_tags[i] === 'dns-in')
			continue;

		push(rules, {
			inbound: inbound_tags[i],
			action: 'sniff'
		});
	}

	return rules;
}

function validate_tailscale_cidr(route) {
	if (type(route) !== 'string')
		return false;

	const matched = match(route, /^([^/]+)\/([0-9]+)$/);
	if (!matched)
		return false;

	const prefix = int(matched[2]);
	if (match(matched[1], /:/))
		return prefix <= 128 && validation('ip6addr', matched[1]);

	return prefix <= 32 && validation('ip4addr', matched[1]);
}

function validate_tailscale_port(port) {
	if (type(port) !== 'string' || !match(port, /^[0-9]+$/))
		return false;

	const number = int(port);
	return number >= 1 && number <= 65535 && validation('port', port);
}

function generate_tailscale_endpoint(cfg, supported, modern) {
	if (!cfg || cfg.enabled !== '1')
		return null;

	if (!supported)
		die('Tailscale is enabled but this sing-box build lacks with_tailscale support; ' +
			'disable homeproxy-ce.tailscale.enabled or install a compatible build');

	const listen_port = cfg.listen_port || '41641';
	if (!validate_tailscale_port(listen_port))
		die('invalid Tailscale listen_port: ' + listen_port);

	let advertise_routes = cfg.advertise_routes || [];
	if (type(advertise_routes) !== 'array')
		advertise_routes = [advertise_routes];
	for (let i = 0; i < length(advertise_routes); i++) {
		const route = advertise_routes[i];
		if (!validate_tailscale_cidr(route))
			die('invalid Tailscale advertise_routes CIDR: ' + route);
	}

	const endpoint = {
		type: 'tailscale',
		tag: 'tailscale-ep',
		state_directory: '/etc/homeproxy-ce/tailscale',
		control_url: 'https://controlplane.tailscale.com',
		ephemeral: false,
		hostname: cfg.hostname || null,
		accept_routes: false,
		advertise_routes: advertise_routes,
		advertise_exit_node: false,
		detour: 'direct-out'
	};

	if (modern)
		endpoint.listen_port = int(listen_port);

	return endpoint;
}

function add_tailscale_routes(rules, advertise_routes) {
	if (type(advertise_routes) === 'array' && length(advertise_routes))
		push(rules, {
			inbound: 'tailscale-ep',
			ip_cidr: advertise_routes,
			action: 'route',
			outbound: 'direct-out'
		});

	push(rules, {
		inbound: 'tailscale-ep',
		action: 'reject'
	});

	return rules;
}

function normalize_dns_rule_for_core(rule, legacy) {
	if (!legacy && rule.server === 'block-dns') {
		delete rule.server;
		/*
		 * These fields belong to route/route-options or reject actions and
		 * are not accepted by the predefined action in current sing-box.
		 */
		delete rule.strategy;
		delete rule.disable_cache;
		delete rule.disable_optimistic_cache;
		delete rule.rewrite_ttl;
		delete rule.timeout;
		delete rule.client_subnet;
		delete rule.remove_client_subnet;
		delete rule.method;
		delete rule.no_drop;
		rule.action = 'predefined';
		rule.rcode = 'NXDOMAIN';
	}

	return rule;
}

function normalize_rule_set_download(rule_set, detour, modern) {
	if (!rule_set)
		return rule_set;

	if (modern && rule_set.type !== 'remote') {
		delete rule_set.download_detour;
		delete rule_set.http_client;
		return rule_set;
	}

	if (modern) {
		delete rule_set.download_detour;
		if (detour)
			rule_set.http_client = { detour: detour };
		else
			delete rule_set.http_client;
	} else {
		delete rule_set.http_client;
		if (detour)
			rule_set.download_detour = detour;
		else
			delete rule_set.download_detour;
	}

	return rule_set;
}

function unsupported_dns_resolver_message(resolver, context) {
	return 'sing-box 1.13+ cannot represent DNS resolver "' + resolver + '" in ' +
		(context || 'this field') + ': block-dns was removed; use a DNS rule action ' +
		'with predefined and rcode NXDOMAIN';
}

const tailscale_cfg = uci.get_all(uciconfig, 'tailscale') || {};
const tailscale_endpoint = generate_tailscale_endpoint(
	tailscale_cfg,
	features.with_tailscale,
	!legacy_tailscale_listen_port
);

function outboundTag(reference) {
	if (!reference || reference === 'nil')
		return null;

	if (reference === 'direct-out' || reference === 'block-out')
		return reference;

	return 'cfg-' + reference + '-out';
}

function formatNodeReferenceError(result) {
	const section = result.section || ((result.path && length(result.path)) ? result.path[0] : result.reference) || 'unknown';
	const reference = result.reference || 'unknown';
	const kind = result.kind || result.status || 'invalid';
	let path = '[]';
	if (result.path && length(result.path)) {
		path = '';
		for (let i = 0; i < length(result.path); i++)
			path += (i ? ' -> ' : '') + result.path[i];
	}

	return `invalid outbound reference: section=${section} kind=${kind} reference=${reference} path=${path}`;
}

function collectPlannedNodes(nodes, roots) {
	const reference_index = buildNodeReferenceIndex(nodes || []);
	const planned = planNodeDependencies(reference_index, roots || []);
	if (planned.status !== 'ok') {
		planned.section = (planned.path && length(planned.path))
			? planned.path[0]
			: planned.reference;
		die(formatNodeReferenceError(planned));
	}

	let result = [];
	for (let i = 0; i < length(planned.order); i++)
		push(result, reference_index.by_id[planned.order[i]]);

	return result;
}

function generate_endpoint(node) {
	if (type(node) !== 'object' || isEmpty(node))
		return null;

	const endpoint = {
		type: node.type,
		tag: 'cfg-' + node['.name'] + '-out',
		address: node.wireguard_local_address,
		mtu: strToInt(node.wireguard_mtu),
		private_key: node.wireguard_private_key,
		peers: (node.type === 'wireguard') ? [
			{
				address: node.address,
				port: strToInt(node.port),
				allowed_ips: [
					'0.0.0.0/0',
					'::/0'
				],
				persistent_keepalive_interval: strToInt(node.wireguard_persistent_keepalive_interval),
				public_key: node.wireguard_peer_public_key,
				pre_shared_key: node.wireguard_pre_shared_key,
				reserved: parse_port(node.wireguard_reserved),
			}
		] : null,
		system: (node.type === 'wireguard') ? false : null,
		tcp_fast_open: strToBool(node.tcp_fast_open),
		tcp_multi_path: strToBool(node.tcp_multi_path),
		udp_fragment: strToBool(node.udp_fragment)
	};

	return endpoint;
}

function generate_outbound(node, reference_index) {
	if (type(node) !== 'object' || isEmpty(node))
		return null;

	if (node.type === 'selector' || node.type === 'urltest') {
		const normalized = normalizeNodeGroup(node, reference_index);
		if (normalized.status !== 'ok') {
			normalized.section = node['.name'];
			if (!normalized.path)
				normalized.path = [node['.name']];
			die(formatNodeReferenceError(normalized));
		}

		return removeBlankAttrs({
			type: node.type,
			tag: 'cfg-' + node['.name'] + '-out',
			outbounds: map(normalized.outbounds, (id) => outboundTag(id)),
			default: node.type === 'selector' ? outboundTag(normalized.default) : null,
			url: node.type === 'urltest' ? node.url : null,
			interval: node.type === 'urltest' ? strToTime(node.interval) : null,
			tolerance: node.type === 'urltest' ? strToInt(node.tolerance) : null,
			idle_timeout: node.type === 'urltest' ? strToTime(node.idle_timeout) : null,
			interrupt_exist_connections: strToBool(node.interrupt_exist_connections)
		});
	}

	const outbound = {
		type: node.type,
		tag: 'cfg-' + node['.name'] + '-out',
		routing_mark: (node.type !== 'urltest' && node.type !== 'selector') ? strToInt(self_mark) : null,

		server: node.address,
		server_port: strToInt(node.port),
		/* Hysteria(2) */
		server_ports: node.hysteria_hopping_port,

		username: (node.type !== 'ssh') ? node.username : null,
		user: (node.type === 'ssh') ? node.username : null,
		password: node.password,

		/* URLTest / Selector */
		outbounds: node.outbounds,
		url: node.url,
		interval: node.interval,
		tolerance: strToInt(node.tolerance),
		idle_timeout: node.idle_timeout,
		default: node.default,
		interrupt_exist_connections: strToBool(node.interrupt_exist_connections),

		/* Direct */
		override_address: node.override_address,
		override_port: strToInt(node.override_port),
		proxy_protocol: strToInt(node.proxy_protocol),
		/* AnyTLS */
		idle_session_check_interval: strToTime(node.anytls_idle_session_check_interval),
		idle_session_timeout: strToTime(node.anytls_idle_session_timeout),
		min_idle_session: strToInt(node.anytls_min_idle_session),
		/* Hysteria (2) */
		hop_interval: strToTime(node.hysteria_hop_interval),
		up_mbps: strToInt(node.hysteria_up_mbps),
		down_mbps: strToInt(node.hysteria_down_mbps),
		obfs: node.hysteria_obfs_type ? {
			type: node.hysteria_obfs_type,
			password: node.hysteria_obfs_password
		} : node.hysteria_obfs_password,
		auth: (node.hysteria_auth_type === 'base64') ? node.hysteria_auth_payload : null,
		auth_str: (node.hysteria_auth_type === 'string') ? node.hysteria_auth_payload : null,
		recv_window_conn: strToInt(node.hysteria_recv_window_conn),
		recv_window: strToInt(node.hysteria_revc_window),
		disable_mtu_discovery: strToBool(node.hysteria_disable_mtu_discovery),
		/* Shadowsocks */
		method: node.shadowsocks_encrypt_method,
		plugin: node.shadowsocks_plugin,
		plugin_opts: node.shadowsocks_plugin_opts,
		/* ShadowTLS / Socks */
		version: (node.type === 'shadowtls') ? strToInt(node.shadowtls_version) : ((node.type === 'socks') ? node.socks_version : null),
		/* SSH */
		client_version: node.ssh_client_version,
		host_key: node.ssh_host_key,
		host_key_algorithms: node.ssh_host_key_algo,
		private_key: node.ssh_priv_key,
		private_key_passphrase: node.ssh_priv_key_pp,
		/* Tuic */
		uuid: node.uuid,
		congestion_control: node.tuic_congestion_control,
		udp_relay_mode: node.tuic_udp_relay_mode,
		udp_over_stream: strToBool(node.tuic_udp_over_stream),
		zero_rtt_handshake: strToBool(node.tuic_enable_zero_rtt),
		heartbeat: strToTime(node.tuic_heartbeat),
		/* VLESS / VMess */
		flow: node.vless_flow,
		alter_id: strToInt(node.vmess_alterid),
		security: node.vmess_encrypt,
		global_padding: strToBool(node.vmess_global_padding),
		authenticated_length: strToBool(node.vmess_authenticated_length),
		packet_encoding: node.packet_encoding,

		multiplex: (node.multiplex === '1') ? {
			enabled: true,
			protocol: node.multiplex_protocol,
			max_connections: strToInt(node.multiplex_max_connections),
			min_streams: strToInt(node.multiplex_min_streams),
			max_streams: strToInt(node.multiplex_max_streams),
			padding: strToBool(node.multiplex_padding),
			brutal: (node.multiplex_brutal === '1') ? {
				enabled: true,
				up_mbps: strToInt(node.multiplex_brutal_up),
				down_mbps: strToInt(node.multiplex_brutal_down)
			} : null
		} : null,
		tls: (node.tls === '1') ? {
			enabled: true,
			server_name: node.tls_sni,
			insecure: strToBool(node.tls_insecure),
			alpn: node.tls_alpn,
			min_version: node.tls_min_version,
			max_version: node.tls_max_version,
			cipher_suites: node.tls_cipher_suites,
			certificate_path: node.tls_cert_path,
			ech: (node.tls_ech === '1') ? {
				enabled: true,
				config: node.tls_ech_config,
				config_path: node.tls_ech_config_path
			} : null,
			utls: !isEmpty(node.tls_utls) ? {
				enabled: true,
				fingerprint: node.tls_utls
			} : null,
			reality: (node.tls_reality === '1') ? {
				enabled: true,
				public_key: node.tls_reality_public_key,
				short_id: node.tls_reality_short_id
			} : null
		} : null,
		transport: !isEmpty(node.transport) ? {
			type: node.transport,
			host: node.http_host || node.httpupgrade_host,
			path: node.http_path || node.ws_path,
			headers: node.ws_host ? {
				Host: node.ws_host
			} : null,
			method: node.http_method,
			max_early_data: strToInt(node.websocket_early_data),
			early_data_header_name: node.websocket_early_data_header,
			service_name: node.grpc_servicename,
			idle_timeout: strToTime(node.http_idle_timeout),
			ping_timeout: strToTime(node.http_ping_timeout),
			permit_without_stream: strToBool(node.grpc_permit_without_stream)
		} : null,
		udp_over_tcp: (node.udp_over_tcp === '1') ? {
			enabled: true,
			version: strToInt(node.udp_over_tcp_version)
		} : null,
		tcp_fast_open: strToBool(node.tcp_fast_open),
		tcp_multi_path: strToBool(node.tcp_multi_path),
		udp_fragment: strToBool(node.udp_fragment)
	};

	return outbound;
}

function get_outbound(cfg) {
	if (isEmpty(cfg))
		return null;

	if (type(cfg) === 'array') {
		if ('any-out' in cfg)
			return 'any';

		let outbounds = [];
		for (let i = 0; i < length(cfg); i++)
			push(outbounds, get_outbound(cfg[i]));
		return outbounds;
	} else {
		switch (cfg) {
		case 'block-out':
		case 'direct-out':
		case 'main-out':
		case 'main-udp-out':
			return cfg;
		}

		const routing_node = routing_node_sections[cfg];
		if (routing_node) {
			if (routing_node.node === 'urltest')
				return 'cfg-' + cfg + '-out';

			const resolved_routing_node = resolveNodeReference(node_reference_index, routing_node.node);
			if (resolved_routing_node.status !== 'ok') {
				resolved_routing_node.section = cfg;
				die(formatNodeReferenceError(resolved_routing_node));
			}
			return resolved_routing_node.tag;
		}

		const resolved_node = resolveNodeReference(node_reference_index, cfg);
		if (resolved_node.status !== 'ok') {
			resolved_node.section = cfg;
			die(formatNodeReferenceError(resolved_node));
		}
		return resolved_node.tag;
	}
}

function get_resolver(cfg, context) {
	if (isEmpty(cfg))
		return null;

	switch (cfg) {
	case 'default-dns':
	case 'system-dns':
	case 'block-dns':
		if (cfg === 'block-dns' && !legacy_dns_server_format)
			die(unsupported_dns_resolver_message(cfg, context));
		return cfg;
	default:
		const dns_server = uci.get_all(uciconfig, cfg) || {};
		if (dns_server['.type'] === ucidnsserver)
			return 'cfg-' + (dns_server.label || cfg) + '-dns';

		let label_tag = null;
		uci.foreach(uciconfig, ucidnsserver, (server) => {
			if (server.label === cfg)
				label_tag = 'cfg-' + cfg + '-dns';
		});

		return label_tag || 'cfg-' + cfg + '-dns';
	}
}

function get_ruleset(cfg) {
	if (isEmpty(cfg))
		return null;

	let rules = [];
	for (let i in cfg)
		push(rules, isEmpty(i) ? null : 'cfg-' + i + '-rule');
	return rules;
}

function has_outbound(outbound_tags, tag) {
	return !!(tag && outbound_tags[tag]);
}

function normalize_outbound(outbound_tags, tag, fallback) {
	if (fallback === null || fallback === '')
		fallback = 'direct-out';

	if (type(tag) === 'array')
		return filter_outbounds(outbound_tags, tag, fallback);

	if (has_outbound(outbound_tags, tag))
		return tag;

	return has_outbound(outbound_tags, fallback) ? fallback : null;
}

function normalize_optional_outbound(outbound_tags, tag) {
	if (isEmpty(tag))
		return null;

	if (type(tag) === 'array') {
		let filtered = [];
		for (let item in tag)
			if (has_outbound(outbound_tags, item) && !~index(filtered, item))
				push(filtered, item);
		return isEmpty(filtered) ? null : filtered;
	}

	return has_outbound(outbound_tags, tag) ? tag : null;
}

function filter_outbounds(outbound_tags, tags, fallback) {
	if (fallback === null || fallback === '')
		fallback = 'direct-out';

	if (type(tags) !== 'array')
		return normalize_outbound(outbound_tags, tags, fallback);

	let filtered = [];
	for (let tag in tags)
		if (has_outbound(outbound_tags, tag) && !~index(filtered, tag))
			push(filtered, tag);

	if (isEmpty(filtered) && has_outbound(outbound_tags, fallback))
		push(filtered, fallback);

	return isEmpty(filtered) ? null : filtered;
}
/* Config helper end */

const config = {};

let node_sections = [],
	routing_node_sections = {},
	node_reference_index;

uci.foreach(uciconfig, ucinode, (cfg) => {
	push(node_sections, cfg);
});

uci.foreach(uciconfig, uciroutingnode, (cfg) => {
	routing_node_sections[cfg['.name']] = cfg;
});

node_reference_index = buildNodeReferenceIndex(node_sections);

function addNodeDependencyRoot(roots, reference, seen, section) {
	if (isEmpty(reference))
		return;

	if (type(reference) === 'array') {
		for (let i = 0; i < length(reference); i++)
			addNodeDependencyRoot(roots, reference[i], seen, section);
		return;
	}

	if (reference === 'direct-out' || reference === 'block-out' ||
		reference === 'main-out' || reference === 'main-udp-out')
		return;

	const routing_node = routing_node_sections[reference];
	if (routing_node) {
		const routing_key = 'routing:' + reference;
		if (seen[routing_key])
			return;
		seen[routing_key] = true;

		if (routing_node.node === 'urltest') {
			addNodeDependencyRoot(roots, routing_node.urltest_nodes, seen, section);
		} else {
			addNodeDependencyRoot(roots, routing_node.node, seen, reference);
		}
		addNodeDependencyRoot(roots, routing_node.outbound, seen, reference);
		return;
	}

	const node_key = 'node:' + reference;
	if (!seen[node_key]) {
		seen[node_key] = true;
		push(roots, reference);
	}
}

/* Log */
config.log = {
	disabled: false,
	level: log_level,
	output: RUN_DIR + '/sing-box-c.log',
	timestamp: true
};

/* NTP */
if (!isEmpty(ntp_server))
	config.ntp = {
		enabled: true,
		server: ntp_server,
		detour: 'direct-out',
		domain_resolver: 'default-dns',
	};

/* DNS start */
/* Default settings */
const wan_dns_server = parse_dnsserver(wan_dns);

config.dns = {
	servers: [
		legacy_dns_server_format ? {
			tag: 'default-dns',
			address: wan_dns_server ? wan_dns_server.address : null,
			detour: self_mark ? 'direct-out' : null
		} : {
			tag: 'default-dns',
			type: 'udp',
			server: wan_dns,
			detour: self_mark ? 'direct-out' : null
		},
		legacy_dns_server_format ? {
			tag: 'system-dns',
			address: 'local',
			detour: self_mark ? 'direct-out' : null
		} : {
			tag: 'system-dns',
			type: 'local',
			detour: self_mark ? 'direct-out' : null
		}
	],
	rules: [],
	strategy: dns_default_strategy,
	disable_cache: strToBool(dns_disable_cache),
	disable_expire: strToBool(dns_disable_cache_expire),
	independent_cache: strToBool(dns_independent_cache),
	client_subnet: dns_client_subnet
};

if (legacy_dns_server_format)
	push(config.dns.servers, {
		tag: 'block-dns',
		address: 'rcode://name_error'
	});

if (!isEmpty(main_node)) {
	/* Main DNS */
	push(config.dns.servers, {
		tag: 'main-dns',
		detour: 'main-out',
		...parse_dnsserver(dns_server, 'tcp')
	});
	apply_dns_resolver(
		config.dns.servers[length(config.dns.servers)-1],
		'default-dns',
		(ipv6_support !== '1') ? 'ipv4_only' : null
	);
	config.dns.final = 'main-dns';

	if (length(direct_domain_list))
		push(config.dns.rules, {
			rule_set: 'direct-domain',
			action: 'route',
			server: (routing_mode === 'bypass_mainland_china') ? 'china-dns' : 'default-dns'
		});

	/* Filter out SVCB/HTTPS queries for "exquisite" Apple devices */
	if (routing_mode === 'gfwlist' || length(proxy_domain_list))
		push(config.dns.rules, {
			rule_set: (routing_mode !== 'gfwlist') ? 'proxy-domain' : null,
			query_type: [64, 65],
			action: 'reject'
		});

	if (routing_mode === 'bypass_mainland_china') {
			push(config.dns.servers, {
				tag: 'china-dns',
				detour: self_mark ? 'direct-out' : null,
				...parse_dnsserver(china_dns_server)
			});
			apply_dns_resolver(
				config.dns.servers[length(config.dns.servers)-1],
				'default-dns',
				'prefer_ipv6'
			);

		if (length(proxy_domain_list))
			push(config.dns.rules, {
				rule_set: 'proxy-domain',
				action: 'route',
				server: 'main-dns'
			});

		push(config.dns.rules, {
			rule_set: 'geosite-cn',
			action: 'route',
			server: 'china-dns',
			strategy: 'prefer_ipv6'
		});
		push(config.dns.rules, {
			type: 'logical',
			mode: 'and',
			rules: [
				{
					rule_set: 'geosite-noncn',
					invert: true
				},
				{
					rule_set: 'geoip-cn'
				}
			],
			action: 'route',
			server: 'china-dns',
			strategy: 'prefer_ipv6'
		});
	}
} else if (!isEmpty(default_outbound)) {
	/* DNS servers */
	uci.foreach(uciconfig, ucidnsserver, (cfg) => {
		if (cfg.enabled !== '1')
			return;

		let outbound = get_outbound(cfg.outbound);
		if (outbound === 'direct-out' && isEmpty(self_mark))
			outbound = null;

			let server = {
				tag: 'cfg-' + (cfg.label || cfg['.name']) + '-dns',
				headers: cfg.headers,
				tls: cfg.tls_sni ? {
					enabled: true,
					server_name: cfg.tls_sni
				} : null,
				detour: outbound
			};

			if (cfg.address) {
				server = {
					...server,
					...(parse_dnsserver(cfg.address, cfg.type || 'udp') || {})
				};
			} else if (legacy_dns_server_format) {
				server.address = sprintf(
					'%s://%s%s%s',
					cfg.type || 'udp',
					cfg.server,
					cfg.server_port ? `:${cfg.server_port}` : '',
					(cfg.path && cfg.path !== '/') ? cfg.path : ''
				);
			} else {
				server.type = cfg.type;
				server.server = cfg.server;
				server.server_port = strToInt(cfg.server_port);
				server.path = cfg.path;
			}

			apply_dns_resolver(
				server,
				(cfg.address_resolver || cfg.address_strategy) ? get_resolver(cfg.address_resolver || dns_default_server, 'DNS server resolver') : null,
				cfg.address_strategy
			);

			push(config.dns.servers, server);
		});

	/* DNS rules */
	uci.foreach(uciconfig, ucidnsrule, (cfg) => {
		if (cfg.enabled !== '1')
			return;

		let dns_rule = {
			ip_version: strToInt(cfg.ip_version),
			query_type: parse_dnsquery(cfg.query_type),
			network: cfg.network,
			protocol: cfg.protocol,
			domain: cfg.domain,
			domain_suffix: cfg.domain_suffix,
			domain_keyword: cfg.domain_keyword,
			domain_regex: cfg.domain_regex,
			port: parse_port(cfg.port),
			port_range: cfg.port_range,
			source_ip_cidr: cfg.source_ip_cidr,
			source_ip_is_private: strToBool(cfg.source_ip_is_private),
			ip_cidr: cfg.ip_cidr,
			ip_is_private: strToBool(cfg.ip_is_private),
			source_port: parse_port(cfg.source_port),
			source_port_range: cfg.source_port_range,
			process_name: cfg.process_name,
			process_path: cfg.process_path,
			process_path_regex: cfg.process_path_regex,
			user: cfg.user,
			clash_mode: cfg.clash_mode,
			rule_set: get_ruleset(cfg.rule_set),
			rule_set_ip_cidr_match_source: strToBool(cfg.rule_set_ip_cidr_match_source),
			rule_set_ip_cidr_accept_empty: strToBool(cfg.rule_set_ip_cidr_accept_empty),
			invert: strToBool(cfg.invert),
			outbound: get_outbound(cfg.outbound),
			action: cfg.action,
			server: (cfg.server === 'block-dns') ? 'block-dns' : get_resolver(cfg.server, 'DNS rule server'),
			strategy: cfg.domain_strategy,
			disable_cache: strToBool(cfg.dns_disable_cache),
			rewrite_ttl: strToInt(cfg.rewrite_ttl),
			client_subnet: cfg.client_subnet,
			method: cfg.reject_method,
			no_drop: strToBool(cfg.reject_no_drop),
			rcode: cfg.predefined_rcode,
			answer: cfg.predefined_answer,
			ns: cfg.predefined_ns,
			extra: cfg.predefined_extra
		};

		push(config.dns.rules, normalize_dns_rule_for_core(dns_rule, legacy_dns_server_format));
	});

	if (isEmpty(config.dns.rules))
		config.dns.rules = null;

	config.dns.final = get_resolver(dns_default_server, 'DNS final resolver');
}
/* DNS end */

/* Inbound start */
config.inbounds = [];

push(config.inbounds, {
	type: 'direct',
	tag: 'dns-in',
	listen: '::',
	listen_port: int(dns_port)
});

push(config.inbounds, {
	type: 'mixed',
	tag: 'mixed-in',
	listen: '::',
	listen_port: int(mixed_port),
	udp_timeout: strToTime(udp_timeout),
	sniff: legacy_inbound_sniff_fields ? true : null,
	sniff_override_destination: legacy_inbound_sniff_fields ? strToBool(sniff_override) : null,
	set_system_proxy: false
});

if (match(proxy_mode, /redirect/))
	push(config.inbounds, {
		type: 'redirect',
		tag: 'redirect-in',

		listen: '::',
		listen_port: int(redirect_port),
		sniff: legacy_inbound_sniff_fields ? true : null,
		sniff_override_destination: legacy_inbound_sniff_fields ? strToBool(sniff_override) : null
	});
if (match(proxy_mode, /tproxy/))
	push(config.inbounds, {
		type: 'tproxy',
		tag: 'tproxy-in',

		listen: '::',
		listen_port: int(tproxy_port),
		network: 'udp',
		udp_timeout: strToTime(udp_timeout),
		sniff: legacy_inbound_sniff_fields ? true : null,
		sniff_override_destination: legacy_inbound_sniff_fields ? strToBool(sniff_override) : null
	});
if (match(proxy_mode, /tun/))
	push(config.inbounds, {
		type: 'tun',
		tag: 'tun-in',

		interface_name: tun_name,
		address: (ipv6_support === '1') ? [tun_addr4, tun_addr6] : [tun_addr4],
		mtu: strToInt(tun_mtu),
		auto_route: false,
		endpoint_independent_nat: strToBool(endpoint_independent_nat),
		udp_timeout: strToTime(udp_timeout),
		stack: tcpip_stack,
		sniff: legacy_inbound_sniff_fields ? true : null,
		sniff_override_destination: legacy_inbound_sniff_fields ? strToBool(sniff_override) : null
	});
/* Inbound end */

let sniff_inbound_tags = [];
if (!legacy_inbound_sniff_fields)
	for (let inbound in config.inbounds)
		if (inbound.tag !== 'dns-in')
			push(sniff_inbound_tags, inbound.tag);

/* Outbound start */
config.endpoints = [];

if (tailscale_endpoint)
	push(config.endpoints, tailscale_endpoint);

/* Default outbounds */
config.outbounds = [
	{
		type: 'direct',
		tag: 'direct-out',
		routing_mark: strToInt(self_mark)
	},
	{
		type: 'block',
		tag: 'block-out'
	}
];
if (legacy_route_rule_format)
	push(config.outbounds, {
		type: 'dns',
		tag: 'dns-out'
	});

/* Main outbounds */
let planned_roots = [],
	planned_seen = {};

if (!isEmpty(main_node)) {
	if (main_node === 'urltest')
		addNodeDependencyRoot(
			planned_roots,
			uci.get(uciconfig, ucimain, 'main_urltest_nodes') || [],
			planned_seen,
			ucimain
		);
	else
		addNodeDependencyRoot(planned_roots, main_node, planned_seen, ucimain);

	if (main_udp_node === 'urltest')
		addNodeDependencyRoot(
			planned_roots,
			uci.get(uciconfig, ucimain, 'main_udp_urltest_nodes') || [],
			planned_seen,
			ucimain
		);
	else if (dedicated_udp_node)
		addNodeDependencyRoot(planned_roots, main_udp_node, planned_seen, ucimain);
} else if (!isEmpty(default_outbound)) {
	addNodeDependencyRoot(planned_roots, default_outbound, planned_seen, uciroutingsetting);

	uci.foreach(uciconfig, uciroutingnode, (cfg) => {
		if (cfg.enabled !== '1')
			return;
		addNodeDependencyRoot(planned_roots, cfg['.name'], planned_seen, cfg['.name']);
	});

	uci.foreach(uciconfig, ucidnsserver, (cfg) => {
		if (cfg.enabled === '1')
			addNodeDependencyRoot(planned_roots, cfg.outbound, planned_seen, cfg['.name']);
	});
	uci.foreach(uciconfig, ucidnsrule, (cfg) => {
		if (cfg.enabled === '1')
			addNodeDependencyRoot(planned_roots, cfg.outbound, planned_seen, cfg['.name']);
	});
	uci.foreach(uciconfig, uciroutingrule, (cfg) => {
		if (cfg.enabled === '1')
			addNodeDependencyRoot(planned_roots, cfg.outbound, planned_seen, cfg['.name']);
	});
	uci.foreach(uciconfig, uciruleset, (cfg) => {
		if (cfg.enabled === '1')
			addNodeDependencyRoot(planned_roots, cfg.outbound, planned_seen, cfg['.name']);
	});
}

const planned_nodes = collectPlannedNodes(node_sections, planned_roots);
let generated_outbounds = {},
	generated_endpoints = {};

for (let i = 0; i < length(planned_nodes); i++) {
	const node = planned_nodes[i];
	const node_id = node['.name'];
	if (node.type === 'wireguard') {
		const endpoint = generate_endpoint(node);
		generated_endpoints[node_id] = endpoint;
		push(config.endpoints, endpoint);
	} else {
		const outbound = generate_outbound(node, node_reference_index);
		generated_outbounds[node_id] = outbound;
		push(config.outbounds, outbound);
	}
}

function tagGeneratedNode(node_id, tag) {
	if (generated_endpoints[node_id])
		generated_endpoints[node_id].tag = tag;
	else if (generated_outbounds[node_id])
		generated_outbounds[node_id].tag = tag;
}

function configuredOutboundTag(reference, section) {
	const tag = get_outbound(reference);
	if (isEmpty(tag)) {
		const result = { status: 'missing', reference, section };
		die(formatNodeReferenceError(result));
	}
	return tag;
}

if (!isEmpty(main_node)) {
	if (main_node === 'urltest') {
		const main_urltest_nodes = uci.get(uciconfig, ucimain, 'main_urltest_nodes') || [];
		const main_urltest_interval = uci.get(uciconfig, ucimain, 'main_urltest_interval');
		const main_urltest_tolerance = uci.get(uciconfig, ucimain, 'main_urltest_tolerance');

		push(config.outbounds, {
			type: 'urltest',
			tag: 'main-out',
			outbounds: map(main_urltest_nodes, (k) => configuredOutboundTag(k, ucimain)),
			interval: strToTime(main_urltest_interval),
			tolerance: strToInt(main_urltest_tolerance),
			idle_timeout: (strToInt(main_urltest_interval) > 1800) ? `${main_urltest_interval * 2}s` : null,
		});
	} else {
		const main_node_result = resolveNodeReference(node_reference_index, main_node);
		if (main_node_result.status !== 'ok') {
			main_node_result.section = ucimain;
			die(formatNodeReferenceError(main_node_result));
		}
		tagGeneratedNode(main_node_result.id, 'main-out');
	}

	if (main_udp_node === 'urltest') {
		const main_udp_urltest_nodes = uci.get(uciconfig, ucimain, 'main_udp_urltest_nodes') || [];
		const main_udp_urltest_interval = uci.get(uciconfig, ucimain, 'main_udp_urltest_interval');
		const main_udp_urltest_tolerance = uci.get(uciconfig, ucimain, 'main_udp_urltest_tolerance');

		push(config.outbounds, {
			type: 'urltest',
			tag: 'main-udp-out',
			outbounds: map(main_udp_urltest_nodes, (k) => configuredOutboundTag(k, ucimain)),
			interval: strToTime(main_udp_urltest_interval),
			tolerance: strToInt(main_udp_urltest_tolerance),
			idle_timeout: (strToInt(main_udp_urltest_interval) > 1800) ? `${main_udp_urltest_interval * 2}s` : null,
		});
	} else if (dedicated_udp_node) {
		const main_udp_node_result = resolveNodeReference(node_reference_index, main_udp_node);
		if (main_udp_node_result.status !== 'ok') {
			main_udp_node_result.section = ucimain;
			die(formatNodeReferenceError(main_udp_node_result));
		}
		tagGeneratedNode(main_udp_node_result.id, 'main-udp-out');
	}
} else if (!isEmpty(default_outbound)) {
	uci.foreach(uciconfig, uciroutingnode, (cfg) => {
		if (cfg.enabled !== '1')
			return;

		if (cfg.node === 'urltest') {
			push(config.outbounds, removeBlankAttrs({
				type: 'urltest',
				tag: 'cfg-' + cfg['.name'] + '-out',
				outbounds: map(cfg.urltest_nodes || [], (k) => configuredOutboundTag(k, cfg['.name'])),
				url: cfg.urltest_url,
				interval: strToTime(cfg.urltest_interval),
				tolerance: strToInt(cfg.urltest_tolerance),
				idle_timeout: strToTime(cfg.urltest_idle_timeout),
				interrupt_exist_connections: strToBool(cfg.urltest_interrupt_exist_connections)
			}));
			return;
		}

		const node_result = resolveNodeReference(node_reference_index, cfg.node);
		if (node_result.status !== 'ok') {
			node_result.section = cfg['.name'];
			die(formatNodeReferenceError(node_result));
		}

		const generated = generated_endpoints[node_result.id] || generated_outbounds[node_result.id];
		if (!generated)
			return;

		/* Selector/URLTest groups only expose their group fields. */
		if (generated.type in ['selector', 'urltest'])
			return;

		generated.bind_interface = cfg.bind_interface;
		generated.detour = get_outbound(cfg.outbound);
		if (cfg.domain_resolver)
			generated.domain_resolver = {
				server: get_resolver(cfg.domain_resolver),
				strategy: cfg.domain_strategy
			};
	});
}

if (isEmpty(config.endpoints))
	config.endpoints = null;

let outbound_tags = {};
for (let outbound in config.outbounds)
	outbound_tags[outbound.tag] = true;
for (let endpoint in config.endpoints || [])
	outbound_tags[endpoint.tag] = true;

	for (let outbound in config.outbounds) {
		if (outbound.type in ['selector', 'urltest'])
			outbound.outbounds = filter_outbounds(outbound_tags, outbound.outbounds);

		if (legacy_dns_server_format) {
			if (outbound.type in ['selector', 'urltest'])
				outbound.default = normalize_optional_outbound(outbound_tags, outbound.default);
			else
				delete outbound.default;
		} else
			outbound.default = normalize_optional_outbound(outbound_tags, outbound.default);
		outbound.detour = normalize_optional_outbound(outbound_tags, outbound.detour);
	}

for (let endpoint in config.endpoints || [])
	endpoint.detour = normalize_optional_outbound(outbound_tags, endpoint.detour);

for (let server in config.dns.servers)
	server.detour = normalize_optional_outbound(outbound_tags, server.detour);

if (config.ntp)
	config.ntp.detour = normalize_optional_outbound(outbound_tags, config.ntp.detour);
/* Outbound end */

/* Routing rules start */
/* Default settings */
config.route = {
	rules: [],
	rule_set: [],
	auto_detect_interface: isEmpty(default_interface) ? true : null,
	default_interface: default_interface
};

if (tailscale_endpoint)
	add_tailscale_routes(config.route.rules, tailscale_endpoint.advertise_routes);

if (legacy_route_rule_format) {
	push(config.route.rules, {
		inbound: 'dns-in',
		outbound: 'dns-out'
	});
	push(config.route.rules, {
		protocol: 'dns',
		outbound: 'dns-out'
	});
} else {
	/*
	 * Inbound sniff fields were removed in sing-box 1.13. The route sniff
	 * action has no exact override_destination equivalent, so keep only the
	 * corresponding early sniff actions and leave DNS inbound untouched.
	 */
	if (!legacy_inbound_sniff_fields)
		add_modern_sniff_rules(config.route.rules, sniff_inbound_tags);

	push(config.route.rules, {
		inbound: 'dns-in',
		action: 'hijack-dns'
	});
}

/* Routing rules */
if (!isEmpty(main_node)) {
	/* Avoid DNS loop */
	config.route.default_domain_resolver = {
		action: 'route',
		server: (routing_mode === 'bypass_mainland_china') ? 'china-dns' : 'default-dns',
		strategy: (ipv6_support !== '1') ? 'prefer_ipv4' : null
	};

	/* Direct list */
	if (length(direct_domain_list))
		push(config.route.rules, {
			rule_set: 'direct-domain',
			action: 'route',
			outbound: 'direct-out'
		});

	/* Main UDP out */
	if (dedicated_udp_node)
		push(config.route.rules, {
			network: 'udp',
			action: 'route',
			outbound: 'main-udp-out'
		});

	config.route.final = 'main-out';

	/* Rule set */
	/* Direct list */
	if (length(direct_domain_list))
		push(config.route.rule_set, {
			type: 'inline',
			tag: 'direct-domain',
			rules: [
				{
					domain_keyword: direct_domain_list,
				}
			]
		});

	/* Proxy list */
	if (length(proxy_domain_list))
		push(config.route.rule_set, {
			type: 'inline',
			tag: 'proxy-domain',
			rules: [
				{
					domain_keyword: proxy_domain_list,
				}
			]
		});

	if (routing_mode === 'bypass_mainland_china') {
		push(config.route.rule_set, {
			type: 'remote',
			tag: 'geoip-cn',
			format: 'binary',
			url: 'https://fastly.jsdelivr.net/gh/1715173329/IPCIDR-CHINA@rule-set/cn.srs',
			download_detour: 'main-out'
		});
		push(config.route.rule_set, {
			type: 'remote',
			tag: 'geosite-cn',
			format: 'binary',
			url: 'https://fastly.jsdelivr.net/gh/1715173329/sing-geosite@rule-set-unstable/geosite-geolocation-cn.srs',
			download_detour: 'main-out'
		});
		push(config.route.rule_set, {
			type: 'remote',
			tag: 'geosite-noncn',
			format: 'binary',
			url: 'https://fastly.jsdelivr.net/gh/1715173329/sing-geosite@rule-set-unstable/geosite-geolocation-!cn.srs',
			download_detour: 'main-out'
		});
	}

	if (isEmpty(config.route.rule_set))
		config.route.rule_set = null;
} else if (!isEmpty(default_outbound)) {
	config.route.default_domain_resolver = {
		action: 'resolve',
		server: get_resolver(default_outbound_dns, 'route.default_domain_resolver')
	};

	if (domain_strategy)
		push(config.route.rules, {
			action: 'resolve',
			strategy: domain_strategy
		});

	uci.foreach(uciconfig, uciroutingrule, (cfg) => {
		if (cfg.enabled !== '1')
			return null;

		push(config.route.rules, {
			ip_version: strToInt(cfg.ip_version),
			protocol: cfg.protocol,
			network: cfg.network,
			domain: cfg.domain,
			domain_suffix: cfg.domain_suffix,
			domain_keyword: cfg.domain_keyword,
			domain_regex: cfg.domain_regex,
			source_ip_cidr: cfg.source_ip_cidr,
			source_ip_is_private: strToBool(cfg.source_ip_is_private),
			ip_cidr: cfg.ip_cidr,
			ip_is_private: strToBool(cfg.ip_is_private),
			source_port: parse_port(cfg.source_port),
			source_port_range: cfg.source_port_range,
			port: parse_port(cfg.port),
			port_range: cfg.port_range,
			process_name: cfg.process_name,
			process_path: cfg.process_path,
			process_path_regex: cfg.process_path_regex,
			user: cfg.user,
			clash_mode: cfg.clash_mode,
			rule_set: get_ruleset(cfg.rule_set),
			rule_set_ip_cidr_match_source: strToBool(cfg.rule_set_ip_cidr_match_source),
			invert: strToBool(cfg.invert),
			action: cfg.action,
			outbound: get_outbound(cfg.outbound),
			override_address: cfg.override_address,
			override_port: strToInt(cfg.override_port),
			udp_disable_domain_unmapping: strToBool(cfg.udp_disable_domain_unmapping),
			udp_connect: strToBool(cfg.udp_connect),
			udp_timeout: strToTime(cfg.udp_timeout),
			tls_fragment: strToBool(cfg.tls_fragment),
			tls_fragment_fallback_delay: strToTime(cfg.tls_fragment_fallback_delay),
			tls_record_fragment: strToBool(cfg.tls_record_fragment)
		});
	});

	config.route.final = get_outbound(default_outbound);

	/* Rule set */
	uci.foreach(uciconfig, uciruleset, (cfg) => {
		if (cfg.enabled !== '1')
			return null;

		push(config.route.rule_set, {
			type: cfg.type,
			tag: 'cfg-' + cfg['.name'] + '-rule',
			format: cfg.format,
			path: cfg.path,
			url: cfg.url,
			download_detour: get_outbound(cfg.outbound),
			update_interval: cfg.update_interval
		});
	});
}
/* Routing rules end */

/* Experimental start */
if (routing_mode in ['bypass_mainland_china', 'custom']) {
	config.experimental = {
		cache_file: {
			enabled: true,
			path: RUN_DIR + '/cache.db',
			store_rdrc: strToBool(cache_file_store_rdrc),
			rdrc_timeout: strToTime(cache_file_rdrc_timeout),
		},
		clash_api: {
			external_controller: (enable_clash_api === '1') ? external_controller : null,
			external_ui: external_ui,
			external_ui_download_url: external_ui_download_url,
			external_ui_download_detour: normalize_outbound(outbound_tags, external_ui_download_detour),
			secret: secret,
			default_mode: default_mode
		}
	};
}

for (let rule in config.route.rules)
	rule.outbound = normalize_optional_outbound(outbound_tags, rule.outbound);

if (legacy_route_rule_format)
	for (let rule in config.route.rules) {
		switch (rule.action) {
		case 'hijack-dns':
			rule.outbound = 'dns-out';
			delete rule.action;
			break;
		case 'route':
		case 'route-options':
			delete rule.action;
			break;
		case 'reject':
			rule.outbound = 'block-out';
			delete rule.action;
			delete rule.method;
			delete rule.no_drop;
			break;
		}
	}

for (let rule_set in config.route.rule_set || []) {
	const download_detour = normalize_outbound(outbound_tags, rule_set.download_detour, config.route.final);
	normalize_rule_set_download(rule_set, download_detour, !legacy_rule_set_download_detour);
}

config.route.final = normalize_outbound(outbound_tags, config.route.final);
/* Experimental end */

system('mkdir -p ' + RUN_DIR);
writefile(RUN_DIR + '/sing-box-c.json', sprintf('%.J\n', removeBlankAttrs(config)));
