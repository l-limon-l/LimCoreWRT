#!/usr/bin/ucode
/*
 * Cloudflare WARP Key & Config Generator for HomeProxy
 * Based on Throne & Cloudflare WARP API
 */

'use strict';

import { popen, access, readfile, writefile, unlink } from 'fs';

function shellquote(s) {
	return `'${replace(s, "'", "'\\''")}'`;
}

let seed = 12345;
function rand_fallback() {
	seed = (seed * 1103515245 + 12345) % 2147483647;
	return seed;
}

function get_rand_id() {
	if (access('/proc/sys/kernel/random/uuid')) {
		const uuid = readfile('/proc/sys/kernel/random/uuid');
		if (uuid && length(trim(uuid))) {
			return replace(trim(uuid), /-/g, '');
		}
	}
	const fd = popen('hexdump -n 8 -e \'4/4 "%08x"\' /dev/urandom 2>/dev/null || date +%s%N 2>/dev/null');
	if (fd) {
		const out = trim(fd.read('all') || '');
		fd.close();
		if (length(out)) return out;
	}
	return 'warp_' + sprintf('%d', rand_fallback());
}

function get_iso_date() {
	const fd = popen('date -u +"%Y-%m-%dT%H:%M:%S.000+00:00" 2>/dev/null');
	if (fd) {
		const out = trim(fd.read('all') || '');
		fd.close();
		if (length(out)) return out;
	}
	return '2024-01-01T00:00:00.000+00:00';
}

function generate_keypair() {
	let priv = null, pub = null;

	/* 1. Try sing-box / hiddify-core built-in keypair generator (sing-box generate wireguard-keypair) */
	const sb_cmds = [
		'/usr/bin/sing-box generate wireguard-keypair 2>&1',
		'/usr/bin/sing-box generate wg-keypair 2>&1',
		'/usr/bin/sing-box generate keypair 2>&1',
		'/usr/bin/hiddify-core generate wireguard-keypair 2>&1',
		'/usr/bin/hiddify-core generate wg-keypair 2>&1',
		'/usr/bin/sing-box-extended generate wireguard-keypair 2>&1',
		'/usr/bin/sing-box-extended generate wg-keypair 2>&1',
		'/usr/bin/hiddify generate wireguard-keypair 2>&1',
		'/usr/bin/hiddify generate wg-keypair 2>&1',
		'/usr/sbin/sing-box generate wireguard-keypair 2>&1',
		'sing-box generate wireguard-keypair 2>&1',
		'sing-box generate wg-keypair 2>&1',
		'hiddify-core generate wireguard-keypair 2>&1',
		'hiddify-core generate wg-keypair 2>&1'
	];

	for (let cmd in sb_cmds) {
		const fd_sb = popen(cmd);
		if (fd_sb) {
			const out = fd_sb.read('all') || ''; fd_sb.close();
			if (length(out)) {
				// Try JSON parsing
				try {
					const j = json(out);
					const tmp_priv = j?.private_key || j?.PrivateKey || j?.['private-key'];
					const tmp_pub  = j?.public_key  || j?.PublicKey  || j?.['public-key'];
					if (tmp_priv && tmp_pub) {
						priv = tmp_priv;
						pub  = tmp_pub;
						break;
					}
				} catch(e) {}

				// Try Regex matching
				const m_priv = match(out, /[Pp]rivate[_\s]*[Kk]ey[\s:=]+([a-zA-Z0-9+/=]{43,44})/);
				const m_pub  = match(out, /[Pp]ublic[_\s]*[Kk]ey[\s:=]+([a-zA-Z0-9+/=]{43,44})/);
				if (m_priv && m_pub) {
					priv = m_priv[1];
					pub  = m_pub[1];
					break;
				}
			}
		}
	}

	/* 2. Fallback to wg CLI (wireguard-tools) */
	if (!priv || !pub) {
		const fd_wg = popen('wg genkey 2>/dev/null');
		if (fd_wg) {
			const tmp_priv = trim(fd_wg.read('all') || '');
			fd_wg.close();
			if (tmp_priv && length(tmp_priv)) {
				const fd_pub = popen(`echo ${shellquote(tmp_priv)} | wg pubkey 2>/dev/null`);
				if (fd_pub) {
					const tmp_pub = trim(fd_pub.read('all') || '');
					fd_pub.close();
					if (tmp_pub && length(tmp_pub)) {
						priv = tmp_priv;
						pub  = tmp_pub;
					}
				}
			}
		}
	}

	/* 3. Fallback to openssl if wg is not present or failed */
	if ((!priv || !pub) && (access('/usr/bin/openssl') || access('/bin/openssl'))) {
		const tmp_key = '/tmp/warp_key_' + get_rand_id() + '.key';
		system(`openssl genpkey -algorithm X25519 -out ${shellquote(tmp_key)} >/dev/null 2>&1`);
		if (access(tmp_key)) {
			const fd_priv = popen(`openssl pkey -in ${shellquote(tmp_key)} -rawout 2>/dev/null | openssl base64 2>/dev/null | tr -d '\\r\\n' || openssl genpkey -algorithm X25519 -outform DER 2>/dev/null | tail -c 32 | openssl base64 2>/dev/null | tr -d '\\r\\n'`);
			if (fd_priv) {
				const tmp_priv = trim(fd_priv.read('all') || '');
				fd_priv.close();
				if (tmp_priv && length(tmp_priv)) priv = tmp_priv;
			}
			const fd_pub = popen(`openssl pkey -in ${shellquote(tmp_key)} -pubout -rawout 2>/dev/null | openssl base64 2>/dev/null | tr -d '\\r\\n'`);
			if (fd_pub) {
				const tmp_pub = trim(fd_pub.read('all') || '');
				fd_pub.close();
				if (tmp_pub && length(tmp_pub)) pub = tmp_pub;
			}
			unlink(tmp_key);
		}
	}

	return { private_key: priv, public_key: pub };
}

function register_warp(pub_key) {
	if (!pub_key || !length(pub_key)) return null;

	const payload = sprintf('%J', {
		key: pub_key,
		install_id: "",
		warp_enabled: true,
		tos: get_iso_date(),
		type: "Android",
		locale: "en_US"
	});

	const rand_id = get_rand_id();
	const tmp_json = '/tmp/warp_reg_' + rand_id + '.json';
	const tmp_res = '/tmp/warp_res_' + rand_id + '.json';

	writefile(tmp_json, payload);

	const urls = [
		'https://api.cloudflareclient.com/v0a737/reg',
		'https://api.cloudflareclient.com/v0a884/reg',
		'https://api.cloudflareclient.com/v0i1909051800/reg'
	];

	let raw_res = null;

	for (let url in urls) {
		const cmd = `curl -s -X POST -H "Content-Type: application/json" -H "User-Agent: WARP for Android" -d @${shellquote(tmp_json)} -o ${shellquote(tmp_res)} --connect-timeout 10 ${shellquote(url)} >/dev/null 2>&1 || wget -qO ${shellquote(tmp_res)} --header="Content-Type: application/json" --header="User-Agent: WARP for Android" --post-file=${shellquote(tmp_json)} --timeout=10 ${shellquote(url)} >/dev/null 2>&1 || uclient-fetch -q -O ${shellquote(tmp_res)} --header="Content-Type: application/json" --header="User-Agent: WARP for Android" --post-file=${shellquote(tmp_json)} ${shellquote(url)} >/dev/null 2>&1`;
		system(cmd);

		if (access(tmp_res)) {
			raw_res = readfile(tmp_res);
			unlink(tmp_res);
			if (raw_res && length(trim(raw_res))) {
				break;
			}
		}
	}

	unlink(tmp_json);

	if (!raw_res || !length(raw_res)) return null;

	let data = null;
	try {
		data = json(raw_res);
	} catch (e) {
		data = null;
	}

	return data;
}

/* Main Execution */
const keys = generate_keypair();

if (!keys.public_key || !keys.private_key) {
	print(sprintf('%J\n', {
		success: false,
		error: "Failed to generate WireGuard keypair."
	}));
	exit(1);
}

const reg_data = register_warp(keys.public_key);

if (!reg_data || (!reg_data.result && !reg_data.config)) {
	const err_msg = reg_data?.errors?.[0]?.message || reg_data?.message || "Failed to register with Cloudflare WARP API. Check internet connectivity.";
	print(sprintf('%J\n', {
		success: false,
		error: err_msg
	}));
	exit(1);
}

const res = reg_data.result || reg_data;
const peer = res.config?.peers?.[0];
const iface = res.config?.interface;

const peer_pub = peer?.public_key || "bmXOC+F1FxEMF9dyiK2H5/1SUTzH0JuVo51h2wPfgyo=";
let endpoint = peer?.endpoint?.host || peer?.endpoint?.v4 || peer?.endpoint?.host?.v4 || "engage.cloudflareclient.com:2408";
if (endpoint && !match(endpoint, /:/)) {
	endpoint = endpoint + ":2408";
}

let addr_v4 = iface?.addresses?.v4 || iface?.addresses?.all?.[0] || "172.16.0.2";
let addr_v6 = iface?.addresses?.v6 || iface?.addresses?.all?.[1] || "";

const format_cidr = (addr, is_v6) => {
	if (!addr || !length(addr)) return null;
	if (match(addr, /\//)) return addr;
	return is_v6 ? addr + '/128' : addr + '/32';
};

let addresses = format_cidr(addr_v4, false);
const formatted_v6 = format_cidr(addr_v6, true);
if (formatted_v6 && length(formatted_v6)) {
	addresses = (addresses ? addresses + "," : "") + formatted_v6;
}

let reserved_str = "0,0,0";
if (peer?.reserved && type(peer.reserved) === 'array' && length(peer.reserved) >= 3) {
	reserved_str = sprintf('%d,%d,%d', peer.reserved[0], peer.reserved[1], peer.reserved[2]);
}

print(sprintf('%J\n', {
	success: true,
	private_key: keys.private_key,
	peer_public_key: peer_pub,
	endpoint: endpoint,
	addresses: addresses || "172.16.0.2/32",
	reserved: reserved_str
}));


