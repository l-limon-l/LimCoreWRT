#!/usr/bin/ucode
/*
 * Cloudflare WARP Key & Config Generator for HomeProxy
 */

'use strict';

import { popen, access, readfile, unlink } from 'fs';

function shellquote(s) {
	return `'${replace(s, "'", "'\\''")}'`;
}

function generate_keypair() {
	let priv = null, pub = null;

	/* 1. Try sing-box / hiddify-core built-in wg-keypair generator first (ALWAYS present) */
	const fd_sb = popen('/usr/bin/sing-box generate wg-keypair 2>&1 || /usr/bin/hiddify-core generate wg-keypair 2>&1 || sing-box generate wg-keypair 2>&1');

	if (fd_sb) {
		const out = fd_sb.read('all') || ''; fd_sb.close();
		const m_priv = match(out, /Private\s*key:\s*(\S+)/i);
		const m_pub  = match(out, /Public\s*key:\s*(\S+)/i);
		if (m_priv) priv = m_priv[1];
		if (m_pub)  pub  = m_pub[1];
	}

	/* 2. Fallback to wg CLI (wireguard-tools) */
	if (!priv || !pub) {
		const fd_wg = popen('wg genkey 2>/dev/null');
		if (fd_wg) {
			priv = trim(fd_wg.read('all') || '');
			fd_wg.close();
			if (priv && length(priv)) {
				const fd_pub = popen(`echo ${shellquote(priv)} | wg pubkey 2>/dev/null`);
				if (fd_pub) {
					pub = trim(fd_pub.read('all') || '');
					fd_pub.close();
				}
			}
		}
	}

	/* 3. Fallback to openssl if wg is not present or failed */
	if ((!priv || !pub) && (access('/usr/bin/openssl') || access('/bin/openssl'))) {
		const tmp_key = '/tmp/warp_key_' + sprintf('%x', rand()) + '.key';
		system(`openssl genpkey -algorithm X25519 -out ${shellquote(tmp_key)} 2>/dev/null`);
		if (access(tmp_key)) {
			const fd_priv = popen(`openssl pkey -in ${shellquote(tmp_key)} -rawout 2>/dev/null | openssl base64 2>/dev/null | tr -d '\\r\\n'`);
			if (fd_priv) {
				priv = trim(fd_priv.read('all') || '');
				fd_priv.close();
			}
			const fd_pub = popen(`openssl pkey -in ${shellquote(tmp_key)} -pubout -rawout 2>/dev/null | openssl base64 2>/dev/null | tr -d '\\r\\n'`);
			if (fd_pub) {
				pub = trim(fd_pub.read('all') || '');
				fd_pub.close();
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

	const tmp_json = '/tmp/warp_reg_' + sprintf('%x', rand()) + '.json';
	const tmp_res = '/tmp/warp_res_' + sprintf('%x', rand()) + '.json';

	const fd = popen(`cat << 'EOF' > ${shellquote(tmp_json)}\n${payload}\nEOF\n`);
	if (fd) fd.close();

	const url = 'https://api.cloudflareclient.com/v0i1909051800/reg';
	const cmd = `curl -s -X POST -H "Content-Type: application/json" -H "User-Agent: okhttp/3.12.1" -d @${shellquote(tmp_json)} -o ${shellquote(tmp_res)} --connect-timeout 15 ${shellquote(url)} 2>/dev/null || wget -qO ${shellquote(tmp_res)} --header="Content-Type: application/json" --header="User-Agent: okhttp/3.12.1" --post-data=${shellquote(payload)} --timeout=15 ${shellquote(url)} 2>/dev/null`;

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
	print(sprintf('%J\n', {
		success: false,
		error: "Failed to register with Cloudflare WARP API. Check internet connectivity."
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
