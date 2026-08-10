#!/usr/bin/ucode
/*
 * SPDX-License-Identifier: GPL-2.0-only
 *
 * Emits a throwaway sing-box config on stdout that chains Cloudflare WARP behind the
 * currently selected main node, so the LuCI page can find out whether WARP actually comes
 * up through it. Whether it does is a property of the server, not of anything visible in
 * the node's settings — measured across nine nodes, ws and tcp work with or without
 * xtls-rprx-vision, xhttp never does, and one server refused UDP for no stated reason.
 *
 * The proxy outbound is lifted VERBATIM out of the generated runtime config rather than
 * rebuilt from UCI. Rebuilding it would test a node assembled by different code than the
 * one the service actually runs, and could pass while the real thing fails.
 *
 * Usage: warp_probe.uc <listen_port>
 */
'use strict';

import { readfile } from 'fs';

const RUN_DIR = '/var/run/limcore';
const port = int(ARGV[0]) || 10899;

const raw = readfile(`${RUN_DIR}/core.json`);
if (!raw) {
	warn('no generated config — start LimCore first\n');
	exit(1);
}

let cfg;
try { cfg = json(raw); } catch (e) { cfg = null; }
if (!cfg) {
	warn('generated config is not valid JSON\n');
	exit(1);
}

/* main-out may live in either list: plain protocols land in outbounds, wireguard-style
 * ones in endpoints. */
let proxy = null, from_endpoints = false;
for (let o in (cfg.outbounds || []))
	if (o.tag === 'main-out') proxy = o;
if (!proxy)
	for (let e in (cfg.endpoints || []))
		if (e.tag === 'main-out') { proxy = e; from_endpoints = true; }

if (!proxy) {
	warn('no main-out in the generated config — select a main node first\n');
	exit(1);
}

proxy = { ...proxy, tag: 'proxy-out' };

const probe = {
	log: { level: 'error', timestamp: true },
	inbounds: [ { type: 'socks', tag: 'in', listen: '127.0.0.1', listen_port: port } ],
	endpoints: [ { type: 'warp', tag: 'warp-out', detour: 'proxy-out' } ],
	outbounds: [ { type: 'direct', tag: 'direct-out' } ],
	route: {
		rules: [ { inbound: 'in', action: 'route', outbound: 'warp-out' } ],
		final: 'direct-out'
	}
};

if (from_endpoints)
	push(probe.endpoints, proxy);
else
	push(probe.outbounds, proxy);

printf('%.J\n', probe);
