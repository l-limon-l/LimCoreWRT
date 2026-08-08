#!/usr/bin/ucode
/*
 * Cloudflare WARP Key & Config Generator for HomeProxy
 */

'use strict';

import { popen, access, readfile, writefile, unlink } from 'fs';
import { rand } from 'math';
import { clock, time } from 'time';

function shellquote(s) {
	return `'${replace(s, "'", "'\\''")}'`;
}

function get_rand_id() {
	let r1 = 0;
	try { r1 = rand(); } catch (e) { r1 = time(); }
	let r2 = 0;
	try { r2 = clock(); } catch (e) { r2 = 12345; }
	return sprintf('%x_%x', r1, r2);
}

function generate_keypair() {
	let priv = null, pub = null;

	/* 1. Try sing-box / hiddify-core / sing-box-extended / hiddify wg-keypair generator first */
	const sb_cmds = [
		'/usr/bin/sing-box generate wg-keypair 2>&1',
		'/usr/bin/hiddify-core generate wg-keypair 2>&1',
		'/usr/bin/sing-box-extended generate wg-keypair 2>&1',
		'/usr/bin/hiddify generate wg-keypair 2>&1',
		'/usr/sbin/sing-box generate wg-keypair 2>&1',
		'sing-box generate wg-keypair 2>&1',
		'hiddify-core generate wg-keypair 2>&1',
		'sing-box-extended generate wg-keypair 2>&1',
		'hiddify generate wg-keypair 2>&1'
	];

	for (let cmd in sb_cmds) {
		const fd_sb = popen(cmd);
		if (fd_sb) {
			const out = fd_sb.read('all') || ''; fd_sb.close();
			const m_priv = match(out, /[Pp]rivate[_\s]*[Kk]ey[\s:=]+([a-zA-Z0-9+/=]{43,44})/);
			const m_pub  = match(out, /[Pp]ublic[_\s]*[Kk]ey[\s:=]+([a-zA-Z0-9+/=]{43,44})/);
			if (m_priv && m_pub) {
				priv = m_priv[1];
				pub  = m_pub[1];
				break;
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
			const fd_priv = popen(`openssl pkey -in ${shellquote(tmp_key)} -rawout 2>/dev/null | openssl base64 2>/dev/null | tr -d '\\r\\n'`);
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

	/* 4. Fallback: python3 cryptography */
	if (priv && !pub && (access('/usr/bin/python3') || access('/usr/bin/python'))) {
		const py_cmd = sprintf(
			'python3 -c "import base64, cryptography.hazmat.primitives.asymmetric.x25519 as x; k=x.X25519PrivateKey.from_private_bytes(base64.b64decode(\'%s\')); print(base64.b64encode(k.public_key().public_bytes_raw()).decode())" 2>/dev/null',
			priv
		);
		const fd_py = popen(py_cmd);
		if (fd_py) {
			pub = trim(fd_py.read('all') || '');
			fd_py.close();
		}
	}

	return { private_key: priv, public_key: pub };
}

function register_warp(pub_key) {
	if (!pub_key || !length(pub_key)) return null;

	const payload = sprintf('%J', {
		key: pub_key,
		install_id: "",
		fcm_token: "",
		tos: "2019-11-25T00:00:00.000-07:00",
		type: "Android",
		locale: "en_US"
	});

	const rand_id = get_rand_id();
	const tmp_json = '/tmp/warp_reg_' + rand_id + '.json';
	const tmp_res = '/tmp/warp_res_' + rand_id + '.json';

	writefile(tmp_json, payload);

	const url = 'https://api.cloudflareclient.com/v0i1909051800/reg';
	const cmd = `curl -s -X POST -H "Content-Type: application/json" -H "User-Agent: okhttp/3.12.1" -d @${shellquote(tmp_json)} -o ${shellquote(tmp_res)} --connect-timeout 15 ${shellquote(url)} >/dev/null 2>&1 || wget -qO ${shellquote(tmp_res)} --header="Content-Type: application/json" --header="User-Agent: okhttp/3.12.1" --post-file=${shellquote(tmp_json)} --timeout=15 ${shellquote(url)} >/dev/null 2>&1 || uclient-fetch -q -O ${shellquote(tmp_res)} --header="Content-Type: application/json" --header="User-Agent: okhttp/3.12.1" --post-file=${shellquote(tmp_json)} ${shellquote(url)} >/dev/null 2>&1`;

	system(cmd);

	unlink(tmp_json);

	const raw_res = readfile(tmp_res);
	unlink(tmp_res);

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
		error: "Failed to generate Curve25519 keypair."
	}));
	exit(1);
}

const reg_data = register_warp(keys.public_key);

if (!reg_data || !reg_data.result) {
	const err_msg = reg_data?.errors?.[0]?.message || reg_data?.message || "Failed to register with Cloudflare WARP API. Check internet connectivity.";
	print(sprintf('%J\n', {
		success: false,
		error: err_msg
	}));
	exit(1);
}

const res = reg_data.result;
const peer = res.config?.peers?.[0];
const iface = res.config?.interface;

const peer_pub = peer?.public_key || "bmXOC+F1FxEMF9dyiK2H5/1SUTzH0JuVo51h2wPfgyo=";
const endpoint = peer?.endpoint?.host?.v4 || peer?.endpoint?.host || "engage.cloudflareclient.com:2408";

let addr_v4 = iface?.addresses?.v4 || "172.16.0.2/32";
let addr_v6 = iface?.addresses?.v6 || "";

let addresses = addr_v4;
if (addr_v6 && length(addr_v6)) {
	addresses = addresses + "," + addr_v6;
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
	addresses: addresses,
	reserved: reserved_str
}));

