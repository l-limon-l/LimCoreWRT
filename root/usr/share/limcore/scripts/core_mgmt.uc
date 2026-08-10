#!/usr/bin/ucode
/*
 * SPDX-License-Identifier: GPL-2.0-only
 *
 * Copyright (C) 2022-2025 ImmortalWrt.org
 */

'use strict';

import { access, lstat, popen, readfile } from 'fs';

function shellquote(s) {
	return `'${replace(s, "'", "'\\''")}'`;
}

/* Optional GitHub mirror (set by a provisioning tool or the user as
 * uci limcore.config.github_mirror). Used ONLY as a FALLBACK: every fetch tries
 * GitHub first and only swaps to the mirror if GitHub fails — so a healthy GitHub is
 * never bypassed, but a blocked/failed one still gets the file via the mirror. */
function gh_mirror_base() {
	let base = null;
	const fd = popen('uci -q get limcore.config.github_mirror 2>/dev/null');
	if (fd) { base = trim(fd.read('all')); fd.close(); }
	return (base && length(base)) ? replace(base, /\/+$/, '') : null;
}

function gh_mirror_of(url, base) {
	const m = match(url, /^https:\/\/github\.com(\/[^\/]+\/[^\/]+\/releases\/.+)$/);
	return m ? `${base}${m[1]}` : null;
}

function file_size(path) {
	const st = lstat(path);
	return (st && st.type === 'file') ? st.size : 0;
}

/* GitHub-first, mirror-FALLBACK download. Returns wget exit code (0 = success). */
function gh_fetch(url, dest, timeout_ms) {
	let rc = system(`wget -qO ${shellquote(dest)} --timeout=15 ${shellquote(url)} 2>/dev/null`, timeout_ms);
	if (rc !== 0) {
		const base = gh_mirror_base();
		const mu = base ? gh_mirror_of(url, base) : null;
		if (mu)
			rc = system(`wget -qO ${shellquote(dest)} --timeout=15 ${shellquote(mu)} 2>/dev/null`, timeout_ms);
	}
	return rc;
}

function detect_pkg_manager() {
	for (let p in ['/usr/bin/apk', '/sbin/apk', '/usr/sbin/apk'])
		if (access(p)) return 'apk';
	for (let p in ['/bin/opkg', '/usr/bin/opkg'])
		if (access(p)) return 'opkg';
	return null;
}

function detect_arch() {
	const os_rel = readfile('/etc/os-release') || '';
	const m = match(os_rel, /OPENWRT_ARCH="([^"]+)"/) ||
	          match(os_rel, /OPENWRT_ARCH=([^\n]+)/);
	return m ? trim(m[1]) : '';
}

function free_kb(path) {
	const fd = popen(`df -k ${path} 2>/dev/null | awk 'NR==2{print $4}'`);
	if (!fd) return 0;
	const v = int(trim(fd.read('all'))); fd.close();
	return v || 0;
}

function free_ram_kb() {
	const m = match(readfile('/proc/meminfo') || '', /MemAvailable:\s+([0-9]+)/);
	return m ? int(m[1]) : 0;
}

/* Does the overlay filesystem transparently compress? jffs2/ubifs do, ext4/f2fs do not.
 * This decides how much flash the binary actually occupies. Measured on ubifs: 81.4 MB of
 * logical content occupied 36.8 MB of blocks, a ratio of 2.21.
 *
 * Measure this with df, never du: du reports apparent size on a compressing filesystem, so
 * comparing du against du yields a ratio of 1.0 and makes compression look absent. */
function overlay_compresses() {
	const fd = popen("mount 2>/dev/null | awk '$3==\"/overlay\"{print $5; exit}'");
	let t = '';
	if (fd) { t = trim(fd.read('all')); fd.close(); }
	return (t in ['jffs2', 'ubifs']);
}

/* Footprint thresholds (KB). The Go binary is ~72 MB raw → ~72 MB on ext4/f2fs, and ~33 MB
 * on a compressing overlay at the measured 2.21 ratio.
 *
 * Note that ubifs reports free space pessimistically right after heavy writes, before its
 * garbage collector settles: the same device read 22 MB free immediately after a core
 * install and 54 MB free once quiescent. A check running in that window can refuse an
 * install that would in fact have fit. Retrying later is the workaround. */
const FULL_OVERLAY_RAW_KB  = 81920;   /* ~80 MB free on an uncompressed overlay */
const FULL_OVERLAY_COMP_KB = 32768;   /* ~32 MB on a compressing overlay */

const CORE_BINARY = '/usr/bin/sing-box';
const RELEASE_API = 'https://api.github.com/repos/shtorm-7/sing-box-extended/releases/latest';

function github_api(url) {
	const fd = popen('wget -qO- --timeout=10 ' + shellquote(url) + ' 2>/dev/null');
	if (!fd) return { error: 'wget failed' };
	const raw = trim(fd.read('all')); fd.close();
	if (!length(raw)) return { error: 'no response from GitHub API' };
	let data;
	try { data = json(raw); } catch(e) { data = null; }
	return data ? { data } : { error: 'invalid JSON from GitHub API' };
}

function core_version() {
	if (!access(CORE_BINARY)) return null;
	const fd = popen(CORE_BINARY + ' version 2>/dev/null');
	if (!fd) return null;
	const out = fd.read('all'); fd.close();
	const m = match(out, /version v?(\S+)/);
	return m ? m[1] : null;
}

const action = ARGV[0];
let result;

if (action === 'info') {
	const pkg_manager = detect_pkg_manager();
	const arch = detect_arch();

	const tmp_free_kb = free_kb('/tmp');
	let overlay_free_kb = free_kb('/overlay');
	if (!overlay_free_kb) overlay_free_kb = free_kb('/');
	const ram_free_kb = free_ram_kb();

	const singbox_installed = !!access(CORE_BINARY);
	let singbox_version = null;
	let singbox_extended = false;
	if (singbox_installed) {
		const fd = popen(CORE_BINARY + ' version 2>/dev/null');
		if (fd) {
			const out = fd.read('all'); fd.close();
			const m = match(out, /version v?(\S+)/);
			if (m) singbox_version = m[1];
			singbox_extended = !!match(out, /amneziawg|with_amnezia/);
		}
	}

	result = {
		pkg_manager, arch, tmp_free_kb, overlay_free_kb, ram_free_kb,
		singbox: { installed: singbox_installed, version: singbox_version, extended: singbox_extended }
	};

} else if (action === 'check_remote') {
	const api = github_api(RELEASE_API);
	if (api.error)
		result = { error: api.error };
	else if (!api.data?.tag_name)
		result = { error: 'could not read tag_name from response' };
	else
		result = { tag: api.data.tag_name, version: replace(api.data.tag_name, /^v/, '') };

} else if (action === 'prepare_install') {
	const pkg_manager = detect_pkg_manager();
	if (!pkg_manager) {
		result = { error: 'no supported package manager found (apk or opkg)' };
	} else {
		const arch = detect_arch();
		if (!arch || !match(arch, /^[a-zA-Z0-9_-]+$/)) {
			result = { error: 'could not detect device architecture' };
		} else {
			const tmp_free_kb = free_kb('/tmp');
			if (tmp_free_kb < 30720) {
				result = { error: `not enough /tmp space: ${tmp_free_kb} KB free, need 30 MB` };
			} else {
				let overlay_free_kb = free_kb('/overlay');
				if (!overlay_free_kb) overlay_free_kb = free_kb('/');
				const ext = pkg_manager === 'apk' ? '.apk' : '.ipk';
				const need = overlay_compresses() ? FULL_OVERLAY_COMP_KB : FULL_OVERLAY_RAW_KB;

				/* An install that runs out of overlay mid-extraction leaves a registered
				 * package with a truncated/absent binary, so refuse up front. */
				if (overlay_free_kb < need) {
					result = { error: `Not enough overlay space: ${overlay_free_kb} KB free, sing-box-extended needs ~${need} KB.` };
				} else {
					const api = github_api(RELEASE_API);
					if (api.error) {
						result = { error: api.error };
					} else if (!api.data?.tag_name) {
						result = { error: 'could not determine latest version from GitHub' };
					} else {
						let dl_url = null, dl_size = 0;
						for (let asset in (api.data?.assets || [])) {
							const n = asset?.name || '';
							if (!match(n, /openwrt/)) continue;
							if (length(split(n, arch)) < 2) continue;
							if (ext === '.apk' && !match(n, /\.apk$/)) continue;
							if (ext === '.ipk' && !match(n, /\.ipk$/)) continue;
							dl_url  = asset?.browser_download_url;
							dl_size = int(asset?.size) || 0;
							break;
						}
						if (!dl_url)
							result = { error: `no package found for arch ${arch} in latest release` };
						else
							result = {
								pkg_manager, arch, dl_url,
								/* expected byte count — download_pkg verifies against it, so a
								 * truncated transfer can never reach apk/opkg */
								dl_size,
								version: replace(api.data.tag_name, /^v/, ''),
								tmp_path: `/tmp/sing-box-extended${ext}`
							};
					}
				}
			}
		}
	}

} else if (action === 'download_pkg') {
	/* (url, tmp_path [, expected_size]). A truncated download is the classic silent
	 * failure here: wget can exit 0 on a short read, apk then registers the package but
	 * never extracts the 75 MB binary, and the UI reports "installed / not found". */
	const url      = ARGV[1];
	const tmp_path = ARGV[2];
	const expected = int(ARGV[3]) || 0;

	if (!url || !tmp_path) {
		result = { result: false, error: 'missing arguments' };
	} else {
		system(`rm -f ${shellquote(tmp_path)}`);
		const exit_code = gh_fetch(url, tmp_path, 300000);
		const got = file_size(tmp_path);

		if (exit_code !== 0) {
			system(`rm -f ${shellquote(tmp_path)}`);
			result = { result: false, error: 'download failed (network error or GitHub unreachable)' };
		} else if (!got) {
			system(`rm -f ${shellquote(tmp_path)}`);
			result = { result: false, error: 'download produced an empty file' };
		} else if (expected && got !== expected) {
			system(`rm -f ${shellquote(tmp_path)}`);
			result = { result: false, error: `download is incomplete: got ${got} of ${expected} bytes — retry (a mirror via GH_MIRROR may help)` };
		} else {
			result = { result: true, size: got };
		}
	}

} else if (action === 'install_pkg') {
	/* (tmp_path, pkg_manager) */
	const tmp_path    = ARGV[1];
	const pkg_manager = ARGV[2];

	if (!tmp_path || !pkg_manager) {
		result = { result: false, error: 'invalid arguments' };
	} else if (!access(tmp_path)) {
		result = { result: false, error: 'package file not found — download it first' };
	} else {
		/* Keep the manager's own diagnostics: silencing them is what turned a failed
		 * extraction into a reported success. */
		const log = '/tmp/limcore-core-install.log';
		const cmd = (pkg_manager === 'apk')
			/* sing-box-extended ships unsigned — allow-untrusted is unavoidable */
			? `apk add --allow-untrusted ${shellquote(tmp_path)}`
			: `opkg install --force-reinstall ${shellquote(tmp_path)}`;

		const exit_code = system(`{ ${cmd}; } >${log} 2>&1; RC=$?; rm -f ${shellquote(tmp_path)}; exit $RC`, 300000);

		let out = trim(readfile(log) || '');
		/* Trim to the tail: apk lists every package it touched, and only the end matters. */
		if (length(out) > 600)
			out = '…' + substr(out, length(out) - 600);

		if (exit_code !== 0) {
			result = { result: false, error: length(out) ? out : 'package installation failed' };
		} else if (!access(CORE_BINARY)) {
			/* Registered but not extracted — the exact state a truncated package leaves
			 * behind. Roll the registration back so a retry actually reinstalls instead of
			 * hitting apk's "already installed" no-op. */
			if (pkg_manager === 'apk')
				system('apk del sing-box-extended >/dev/null 2>&1', 60000);
			else
				system('opkg remove sing-box-extended >/dev/null 2>&1', 60000);
			result = { result: false, error: `installation reported success but ${CORE_BINARY} is missing (package was rolled back — retry the download)` };
		} else {
			result = { result: true, version: core_version() };
		}
	}

} else if (action === 'install_kmods') {
	const pkg_manager = ARGV[1] || detect_pkg_manager();
	let exit_code = 1;
	/* No --no-cache: it forces apk to refetch the package index over the network
	 * (slow / >60s on poor uplinks, and the index is usually already cached from the
	 * app install). The kmods are tiny and resolve from the local index in seconds. */
	if (pkg_manager === 'apk')
		exit_code = system('apk add kmod-nft-tproxy kmod-tun >/dev/null 2>&1', 120000);
	else if (pkg_manager === 'opkg')
		exit_code = system('opkg install kmod-nft-tproxy kmod-tun >/dev/null 2>&1', 60000);
	result = (exit_code === 0)
		? { result: true }
		: { result: false, error: `kmod install failed (pkg_manager=${pkg_manager || 'none'})` };

} else if (action === 'remove') {
	const pkg_manager = detect_pkg_manager();
	if (!pkg_manager) {
		result = { result: false, error: 'no supported package manager found' };
	} else {
		const exit_code = pkg_manager === 'apk'
			? system('apk del sing-box-extended >/dev/null 2>&1', 60000)
			: system('opkg remove sing-box-extended >/dev/null 2>&1', 60000);
		result = { result: (exit_code === 0) };
	}

} else {
	result = { error: `unknown action: ${action}` };
}

printf('%s\n', result);
