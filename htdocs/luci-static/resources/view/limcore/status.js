/*
 * SPDX-License-Identifier: GPL-2.0-only
 *
 * Copyright (C) 2022-2025 ImmortalWrt.org
 */

'use strict';
'require dom';
'require form';
'require fs';
'require limcore as hp';
'require poll';
'require rpc';
'require uci';
'require ui';
'require view';

/* Thanks to luci-app-aria2 */
const css = '\
.hp-log-window {\
	padding: 10px;\
	text-align: left;\
	max-height: 420px;\
	overflow-y: auto;\
	background: #18181b;\
	color: #e4e4e7;\
	border-radius: 6px;\
	border: 1px solid #27272a;\
	font-family: ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, "Liberation Mono", "Courier New", monospace;\
	font-size: 0.85rem;\
	line-height: 1.4;\
}\
.hp-log-window pre {\
	padding: 0;\
	word-break: break-all;\
	white-space: pre-wrap;\
	margin: 0;\
	font-family: inherit;\
	color: inherit;\
	background: transparent;\
	border: 0;\
}\
.description {\
	background-color: #33ccff;\
}';

const hp_dir = '/var/run/limcore';

/* Map a sing-box outbound tag to its human-readable UCI label */
function resolveTag(tag) {
	const m = tag && tag.match(/^cfg-(.+)-out$/);
	if (m) {
		const label = uci.get('limcore', m[1], 'label');
		if (label) return label;
	}
	/* Fixed tags: look up the backing UCI section via the 'main' config section */
	const specials = { 'main-out': 'main_node', 'main-udp-out': 'main_udp_node' };
	if (specials[tag]) {
		const section = uci.get('limcore', 'main', specials[tag]);
		if (section) {
			const label = uci.get('limcore', section, 'label');
			if (label) return label;
		}
	}
	return tag;
}

function getConnStat(o, site) {
	const callConnStat = rpc.declare({
		object: 'luci.limcore',
		method: 'connection_check',
		params: ['site'],
		expect: { '': {} }
	});

	o.default = E('div', { 'style': 'cbi-value-field' }, [
		E('button', {
			'class': 'btn cbi-button cbi-button-action',
			'click': ui.createHandlerFn(this, () => {
				return L.resolveDefault(callConnStat(site), {}).then((ret) => {
                                        let ele = o.default.firstElementChild.nextElementSibling;
					if (ret.result) {
						ele.style.setProperty('color', 'green');
                                                ele.innerHTML = _('passed');
					} else {
						ele.style.setProperty('color', 'red');
                                                ele.innerHTML = _('failed');
					}
				});
			})
		}, [ _('Check') ]),
		' ',
		E('strong', { 'style': 'color:gray' }, _('unchecked')),
	]);
}

function getRuntimeLog(o, name, _option_index, section_id, _in_table) {
	const filename = o.option.split('_')[1];

	let section, log_level_el;
	switch (filename) {
	case 'daemon':
		section = null;
		break;
	case 'core':
		section = 'config';
		break;
	}

	if (section) {
		const selected = uci.get('limcore', section, 'log_level') || 'warn';
		const choices = {
			trace: _('Trace'),
			debug: _('Debug'),
			info: _('Info'),
			warn: _('Warn'),
			error: _('Error'),
			fatal: _('Fatal'),
			panic: _('Panic')
		};

		log_level_el = E('select', {
			'id': o.cbid(section_id),
			'class': 'cbi-input-select',
			'style': 'margin-left: 4px; width: 6em;',
			'change': ui.createHandlerFn(this, (ev) => {
				uci.set('limcore', section, 'log_level', ev.target.value);
				return o.map.save(null, true).then(() => {
					ui.changes.apply(true);
				});
			})
		});

		Object.keys(choices).forEach((v) => {
			log_level_el.appendChild(E('option', {
				'value': v,
				'selected': (v === selected) ? '' : null
			}, [ choices[v] ]));
		});
	}

	const callLogClean = rpc.declare({
		object: 'luci.limcore',
		method: 'log_clean',
		params: ['type'],
		expect: { '': {} }
	});

	const log_textarea = E('div', {
		'id': 'log_textarea_' + filename,
		'class': 'hp-log-window'
	}, [
		E('img', {
			'src': L.resource('icons/loading.svg'),
			'alt': _('Loading'),
			'style': 'vertical-align:middle'
		}),
		' ',
		_('Collecting data...')
	]);

	let preEl = null;

	poll.add(L.bind(() => {
		return fs.read_direct(String.format('%s/%s.log', hp_dir, filename), 'text')
		.then((res) => {
			const textContent = res.trim() || _('Log is empty.');
			const isAtBottom = (log_textarea.scrollHeight - log_textarea.scrollTop - log_textarea.clientHeight) < 30;

			if (!preEl || log_textarea.querySelector('img')) {
				preEl = E('pre', {}, [ textContent ]);
				dom.content(log_textarea, preEl);
				log_textarea.scrollTop = log_textarea.scrollHeight;
			} else {
				if (preEl.textContent !== textContent) {
					preEl.textContent = textContent;
					if (isAtBottom) {
						log_textarea.scrollTop = log_textarea.scrollHeight;
					}
				}
			}
		}).catch((err) => {
			const errText = err.toString().includes('NotFoundError')
				? _('Log file does not exist.')
				: _('Unknown error: %s').format(err);

			if (!preEl || log_textarea.querySelector('img')) {
				preEl = E('pre', {}, [ errText ]);
				dom.content(log_textarea, preEl);
			} else {
				preEl.textContent = errText;
			}
		});
	}));

	return E([
		E('style', [ css ]),
		E('div', {'class': 'cbi-map'}, [
			E('h3', {'name': 'content', 'style': 'align-items: center; display: flex;'}, [
				_('%s log').format(name),
				log_level_el || '',
				E('button', {
					'class': 'btn cbi-button cbi-button-action',
					'style': 'margin-left: 4px;',
					'click': ui.createHandlerFn(this, () => {
						return L.resolveDefault(callLogClean(filename), {});
					})
				}, [ _('Clean log') ])
			]),
			E('div', {'class': 'cbi-section'}, [
				log_textarea,
				E('div', {'style': 'text-align:right'},
					E('small', {}, _('Refresh every %s seconds.').format(L.env.pollinterval))
				)
			])
		])
	]);
}

const CORE_MGMT = '/usr/share/limcore/scripts/core_mgmt.uc';

const callCurlStatus = rpc.declare({
	object: 'luci.limcore',
	method: 'curl_status',
	expect: { '': {} }
});

const callCurlInstall = rpc.declare({
	object: 'luci.limcore',
	method: 'curl_install',
	expect: { '': {} }
});

const callCurlRemove = rpc.declare({
	object: 'luci.limcore',
	method: 'curl_remove',
	expect: { '': {} }
});

const callByeDPIStatus = rpc.declare({
	object: 'luci.limcore',
	method: 'byedpi_status',
	expect: { '': {} }
});

const callByeDPIPrepareInstall = rpc.declare({
	object: 'luci.limcore',
	method: 'byedpi_prepare_install',
	expect: { '': {} }
});

const callByeDPIInstallPkg = rpc.declare({
	object: 'luci.limcore',
	method: 'byedpi_install_pkg',
	params: ['tmp_path', 'pkg_manager'],
	expect: { '': {} }
});

const callByeDPIRemove = rpc.declare({
	object: 'luci.limcore',
	method: 'byedpi_remove',
	expect: { '': {} }
});

const callZapretStatus = rpc.declare({
	object: 'luci.limcore',
	method: 'zapret_status',
	expect: { '': {} }
});

const callZapretPrepareInstall = rpc.declare({
	object: 'luci.limcore',
	method: 'zapret_prepare_install',
	expect: { '': {} }
});

const callZapretInstallPkg = rpc.declare({
	object: 'luci.limcore',
	method: 'zapret_install_pkg',
	params: ['tmp_path', 'pkg_manager'],
	expect: { '': {} }
});

const callZapretRemove = rpc.declare({
	object: 'luci.limcore',
	method: 'zapret_remove',
	expect: { '': {} }
});

function buildByeDPICard(byedpi, isMainNode) {
	let installed = byedpi?.installed || false;
	let version   = byedpi?.version   || null;
	const running    = byedpi?.running    || false;
	const pkgMgr     = byedpi?.pkg_manager || null;
	const canInstall = !!pkgMgr;

	const statusEl = E('strong', {
		style: installed ? 'color:green' : 'color:gray'
	}, installed ? (version ? 'v' + version : _('Installed')) : _('Not installed'));

	const runEl = E('span', {
		style: 'margin-left:6px; font-size:0.9em; color:' + (running ? 'green' : 'gray')
	}, running ? _('running') : _('stopped'));

	const msgEl = E('span', { style: 'margin-left:8px; font-size:0.9em' }, '');
	const setMsg = (txt, color) => { msgEl.textContent = txt; msgEl.style.color = color || 'gray'; };

	const installBtn = E('button', {
		class: 'btn cbi-button cbi-button-action',
		style: 'margin-left:4px',
		disabled: !canInstall || null,
		title: canInstall ? '' : _('No supported package manager detected'),
		click: async function() {
			const prevInstalled = installed;
			const prevVersion   = version;
			installBtn.disabled = true;
			removeBtn.disabled  = true;
			statusEl.textContent = _('Installing...');
			statusEl.style.color = 'gray';

			const fail = (msg) => {
				installed = prevInstalled;
				version   = prevVersion;
				statusEl.textContent = installed ? (version ? 'v' + version : _('Installed')) : _('Not installed');
				statusEl.style.color = installed ? 'green' : 'gray';
				installBtn.disabled = false;
				removeBtn.disabled  = !installed;
				setMsg(msg, 'red');
			};

			setMsg(_('Checking requirements...'), 'gray');
			const prep = await L.resolveDefault(callByeDPIPrepareInstall(), {});
			if (prep.error) return fail(prep.error);

			setMsg(_('Downloading...'), 'gray');
			const dl = await L.resolveDefault(callCoreDownload(prep.dl_url, prep.tmp_path), {});
			if (!dl.result) return fail(dl.error || _('Download failed'));

			setMsg(_('Installing package...'), 'gray');
			const inst = await L.resolveDefault(callByeDPIInstallPkg(prep.tmp_path, prep.pkg_manager), {});
			if (!inst.result) return fail(inst.error || _('Installation failed'));

			const fresh = await L.resolveDefault(callByeDPIStatus(), {});
			installed = fresh.installed || false;
			version   = fresh.version   || null;
			statusEl.textContent = installed ? (version ? 'v' + version : _('Installed')) : _('Unknown');
			statusEl.style.color = installed ? 'green' : 'gray';
			installBtn.textContent = _('Update');
			installBtn.disabled = false;
			removeBtn.disabled  = false;
			setMsg(_('Installed successfully'), 'green');
		}
	}, [ installed ? _('Update') : _('Install') ]);

	const removeBtn = E('button', {
		class: 'btn cbi-button cbi-button-negative',
		style: 'margin-left:4px',
		disabled: !installed || isMainNode || null,
		title: isMainNode ? _('Cannot remove: ByeDPI is selected as Main Node. Change Main Node first.') : '',
		click: async function() {
			removeBtn.disabled  = true;
			installBtn.disabled = true;
			setMsg(_('Removing...'), 'gray');
			const ret = await L.resolveDefault(callByeDPIRemove(), {});
			installBtn.disabled = false;
			if (ret.result) {
				installed = false;
				version   = null;
				statusEl.textContent = _('Not installed');
				statusEl.style.color = 'gray';
				installBtn.textContent = _('Install');
				setMsg(_('Removed successfully'), 'green');
			} else {
				removeBtn.disabled = false;
				setMsg(ret.error || _('Removal failed'), 'red');
			}
		}
	}, [ _('Remove') ]);

	return E('div', { style: 'margin-bottom:12px; padding:8px 10px; border:1px solid #ddd; border-radius:4px' }, [
		E('div', { style: 'display:flex; align-items:center; flex-wrap:wrap; gap:6px' }, [
			E('strong', {}, 'ciadpi (ByeDPI)'),
			statusEl,
			runEl,
			installBtn,
			removeBtn,
			msgEl
		]),
		E('div', { style: 'margin-top:4px; font-size:0.9em; color:#666' },
			_('Local SOCKS5 DPI bypass proxy by <a href="https://github.com/hufrea/byedpi" target="_blank">hufrea</a>. ' +
			  'Packages by <a href="https://github.com/1andrevich/ByeDPI-OpenWrt" target="_blank">1andrevich/ByeDPI-OpenWrt</a>. ' +
			  'Configure in the Client → ByeDPI tab.'))
	]);
}

function buildZapretCard(zapret) {
	let installed = zapret?.installed || false;
	let version   = zapret?.version   || null;
	const running    = zapret?.running    || false;
	const pkgMgr     = zapret?.pkg_manager || null;
	let kmodOk       = (zapret?.kmod_ok != null) ? zapret.kmod_ok : true;
	const canInstall = !!pkgMgr;

	const statusEl = E('strong', {
		style: installed ? 'color:green' : 'color:gray'
	}, installed ? (version ? 'v' + version : _('Installed')) : _('Not installed'));

	const runEl = E('span', {
		style: 'margin-left:6px; font-size:0.9em; color:' + (running ? 'green' : 'gray')
	}, running ? _('running') : _('stopped'));

	const msgEl = E('span', { style: 'margin-left:8px; font-size:0.9em' }, '');
	const setMsg = (txt, color) => { msgEl.textContent = txt; msgEl.style.color = color || 'gray'; };

	const installBtn = E('button', {
		class: 'btn cbi-button cbi-button-action',
		style: 'margin-left:4px',
		disabled: !canInstall || null,
		title: canInstall ? '' : _('No supported package manager detected'),
		click: async function() {
			const prevInstalled = installed;
			const prevVersion   = version;
			installBtn.disabled = true;
			removeBtn.disabled  = true;
			statusEl.textContent = _('Installing...');
			statusEl.style.color = 'gray';

			const fail = (msg) => {
				installed = prevInstalled;
				version   = prevVersion;
				statusEl.textContent = installed ? (version ? 'v' + version : _('Installed')) : _('Not installed');
				statusEl.style.color = installed ? 'green' : 'gray';
				installBtn.disabled = false;
				removeBtn.disabled  = !installed;
				setMsg(msg, 'red');
			};

			setMsg(_('Checking requirements...'), 'gray');
			const prep = await L.resolveDefault(callZapretPrepareInstall(), {});
			if (prep.error) return fail(prep.error);

			setMsg(_('Downloading...'), 'gray');
			const dl = await L.resolveDefault(callCoreDownload(prep.dl_url, prep.tmp_path), {});
			if (!dl.result) return fail(dl.error || _('Download failed'));

			setMsg(_('Installing package...'), 'gray');
			const inst = await L.resolveDefault(callZapretInstallPkg(prep.tmp_path, prep.pkg_manager), {});
			if (!inst.result) return fail(inst.error || _('Installation failed'));

			const fresh = await L.resolveDefault(callZapretStatus(), {});
			installed = fresh.installed || false;
			version   = fresh.version   || null;
			kmodOk    = (fresh.kmod_ok != null) ? fresh.kmod_ok : true;
			statusEl.textContent = installed ? (version ? 'v' + version : _('Installed')) : _('Unknown');
			statusEl.style.color = installed ? 'green' : 'gray';
			installBtn.textContent = _('Update');
			installBtn.disabled = false;
			removeBtn.disabled  = false;
			if (installed && !kmodOk)
				setMsg(_('Installed, but kmod-nft-queue is missing — Zapret cannot intercept traffic without it.'), 'red');
			else
				setMsg(_('Installed successfully'), 'green');
		}
	}, [ installed ? _('Update') : _('Install') ]);

	const removeBtn = E('button', {
		class: 'btn cbi-button cbi-button-negative',
		style: 'margin-left:4px',
		disabled: !installed || null,
		click: async function() {
			removeBtn.disabled  = true;
			installBtn.disabled = true;
			setMsg(_('Removing...'), 'gray');
			const ret = await L.resolveDefault(callZapretRemove(), {});
			installBtn.disabled = false;
			if (ret.result) {
				installed = false;
				version   = null;
				statusEl.textContent = _('Not installed');
				statusEl.style.color = 'gray';
				installBtn.textContent = _('Install');
				setMsg(_('Removed successfully'), 'green');
			} else {
				removeBtn.disabled = false;
				setMsg(ret.error || _('Removal failed'), 'red');
			}
		}
	}, [ _('Remove') ]);

	/* nfqws2's NFQUEUE rule needs kmod-nft-queue; warn up-front if it's missing. */
	if (installed && !kmodOk)
		setMsg(_('Warning: kmod-nft-queue is not installed — Zapret cannot intercept traffic without it.'), 'red');

	return E('div', { style: 'margin-bottom:12px; padding:8px 10px; border:1px solid #ddd; border-radius:4px' }, [
		E('div', { style: 'display:flex; align-items:center; flex-wrap:wrap; gap:6px' }, [
			E('strong', {}, 'nfqws2 (Zapret 2)'),
			statusEl,
			runEl,
			installBtn,
			removeBtn,
			msgEl
		]),
		E('div', { style: 'margin-top:4px; font-size:0.9em; color:#666' },
			_('Packet-level (NFQUEUE) DPI bypass by <a href="https://github.com/bol-van/zapret2" target="_blank">bol-van</a> (nfqws2). ' +
			  'Packages by <a href="https://github.com/1andrevich/zapret2-openwrt" target="_blank">1andrevich/zapret2-openwrt</a>. ' +
			  'Configure in the Node Settings → Zapret tab.'))
	]);
}

function buildCurlCard(curl) {
	let installed = curl?.installed || false;
	const pkgMgr  = curl?.pkg_manager || null;
	const canInstall = !!pkgMgr;

	const statusEl = E('strong', {
		style: installed ? 'color:green' : 'color:gray'
	}, installed ? _('Installed') : _('Not installed'));

	const msgEl = E('span', { style: 'margin-left:8px; font-size:0.9em' }, '');
	const setMsg = (txt, color) => { msgEl.textContent = txt; msgEl.style.color = color || 'gray'; };

	const installBtn = E('button', {
		class: 'btn cbi-button cbi-button-action',
		style: 'margin-left:4px',
		disabled: !canInstall || null,
		title: canInstall ? '' : _('No supported package manager detected'),
		click: async function() {
			installBtn.disabled = true;
			removeBtn.disabled  = true;
			statusEl.textContent = _('Installing...');
			statusEl.style.color = 'gray';
			setMsg('', 'gray');
			const ret = await L.resolveDefault(callCurlInstall(), {});
			if (ret.result) {
				installed = true;
				statusEl.textContent = _('Installed');
				statusEl.style.color = 'green';
				installBtn.textContent = _('Reinstall');
				removeBtn.disabled  = false;
				setMsg(_('Installed successfully'), 'green');
			} else {
				statusEl.textContent = _('Not installed');
				statusEl.style.color = 'gray';
				installBtn.disabled = false;
				setMsg(ret.error || _('Installation failed'), 'red');
			}
		}
	}, [ _('Install') ]);

	const removeBtn = E('button', {
		class: 'btn cbi-button cbi-button-negative',
		style: 'margin-left:4px',
		disabled: !installed || null,
		click: async function() {
			removeBtn.disabled  = true;
			installBtn.disabled = true;
			setMsg(_('Removing...'), 'gray');
			const ret = await L.resolveDefault(callCurlRemove(), {});
			installBtn.disabled = false;
			if (ret.result) {
				installed = false;
				statusEl.textContent = _('Not installed');
				statusEl.style.color = 'gray';
				installBtn.textContent = _('Install');
				setMsg(_('Removed successfully'), 'green');
			} else {
				removeBtn.disabled = false;
				setMsg(ret.error || _('Removal failed'), 'red');
			}
		}
	}, [ _('Remove') ]);

	return E('div', { style: 'margin-bottom:12px; padding:8px 10px; border:1px solid #ddd; border-radius:4px' }, [
		E('div', { style: 'display:flex; align-items:center; flex-wrap:wrap; gap:6px' }, [
			E('strong', {}, 'curl'),
			statusEl,
			installBtn,
			removeBtn,
			msgEl
		]),
		E('div', { style: 'margin-top:4px; font-size:0.9em; color:#666' },
			_('Enables real HTTP-based ByeDPI strategy testing. Required for the "Test all strategies" feature in Client → ByeDPI tab.'))
	]);
}

function callCoreInfo() {
	return fs.exec_direct('/usr/bin/ucode', [CORE_MGMT, 'info'], 'json');
}

function callCoreCheckRemote() {
	return fs.exec_direct('/usr/bin/ucode', [CORE_MGMT, 'check_remote'], 'json');
}

function callCorePrepare() {
	return fs.exec_direct('/usr/bin/ucode', [CORE_MGMT, 'prepare_install'], 'json');
}

function callCoreDownload(url, tmpPath, expectedSize) {
	return fs.exec_direct('/usr/bin/ucode',
		[CORE_MGMT, 'download_pkg', url, tmpPath, String(expectedSize || 0)], 'json');
}

function callCoreInstallPkg(tmpPath, pkgManager) {
	return fs.exec_direct('/usr/bin/ucode', [CORE_MGMT, 'install_pkg', tmpPath, pkgManager], 'json');
}

function callCoreInstallKmods(pkgManager) {
	return fs.exec_direct('/usr/bin/ucode', [CORE_MGMT, 'install_kmods', pkgManager], 'json');
}

function callCoreRemove() {
	return fs.exec_direct('/usr/bin/ucode', [CORE_MGMT, 'remove'], 'json');
}

function buildCoreCard(coreInfo) {
	const name = 'sing-box-extended';
	const pkgMgr = coreInfo.pkg_manager;
	const coreData = coreInfo.singbox || {};
	const canInstall = !!pkgMgr;

	const desc = _('Extended sing-box with additional protocols including AmneziaWG and TrustTunnel support. Created by shtorm-7.');

	let installed = coreData.installed || false;
	let version   = coreData.version   || null;

	const statusEl = E('strong', {
		style: installed ? 'color:green' : 'color:gray'
	}, installed ? 'v' + version : _('Not installed'));

	const msgEl = E('span', { style: 'margin-left:8px; font-size:0.9em' }, '');
	const setMsg = (txt, color) => { msgEl.textContent = txt; msgEl.style.color = color || 'gray'; };

	const remoteEl = E('span', { style: 'font-size:0.9em; color:gray' }, '');

	const checkBtn = E('button', {
		class: 'btn cbi-button',
		click: async function() {
			checkBtn.disabled = true;
			remoteEl.textContent = _('Checking...');
			remoteEl.style.color = 'gray';
			const ret = await L.resolveDefault(callCoreCheckRemote(), {});
			checkBtn.disabled = false;
			/* Say what to do, not just what exists. "Latest: v1.2.3" in orange meant the
			   reader had to compare two version strings themselves to find out whether
			   that was good news. */
			if (ret.error) {
				remoteEl.textContent = ret.error;
				remoteEl.style.color = '#c0392b';
			} else if (!installed) {
				remoteEl.textContent = _('Available: v%s').format(ret.version);
				remoteEl.style.color = 'gray';
			} else if (version === ret.version) {
				remoteEl.textContent = _('Up to date (v%s)').format(version);
				remoteEl.style.color = 'green';
			} else {
				remoteEl.textContent = _('Update available: v%s → v%s').format(version, ret.version);
				remoteEl.style.color = '#d35400';
				installBtn.classList.add('cbi-button-positive');
			}
		}
	}, [ _('Check update') ]);

	const doInstall = async () => {
		const prevInstalled = installed;
		const prevVersion   = version;
		installBtn.disabled = true;
		removeBtn.disabled  = true;
		statusEl.textContent = _('Installing...');
		statusEl.style.color = 'gray';

		const fail = (msg) => {
			installed = prevInstalled;
			version   = prevVersion;
			statusEl.textContent = installed ? 'v' + (version || '?') : _('Not installed');
			statusEl.style.color = installed ? 'green' : 'gray';
			installBtn.disabled = false;
			removeBtn.disabled  = !installed;
			setMsg(msg, 'red');
		};

		setMsg(_('Checking requirements...'), 'gray');
		const prep = await L.resolveDefault(callCorePrepare(), {});
		if (prep.error) return fail(prep.error);

		setMsg(_('Downloading...'), 'gray');
		const dl = await L.resolveDefault(callCoreDownload(prep.dl_url, prep.tmp_path, prep.dl_size), {});
		if (!dl.result) return fail(dl.error || _('Download failed'));

		setMsg(_('Installing package...'), 'gray');
		const inst = await L.resolveDefault(callCoreInstallPkg(prep.tmp_path, prep.pkg_manager), {});
		if (!inst.result) return fail(inst.error || _('Installation failed'));

		setMsg(_('Installing kernel modules...'), 'gray');
		await L.resolveDefault(callCoreInstallKmods(prep.pkg_manager), {});

		/* Trust the fresh probe, not the installer's exit code: a package can register
		 * without its binary ever landing on disk. */
		const fresh = await L.resolveDefault(callCoreInfo(), {});
		const fd = fresh.singbox || {};
		if (!fd.installed)
			return fail(_('Package installed but the sing-box binary is missing — retry the installation'));

		installed = true;
		version   = fd.version || null;
		statusEl.textContent = version ? 'v' + version : _('Installed');
		statusEl.style.color = 'green';
		installBtn.textContent = _('Update');
		installBtn.disabled = false;
		removeBtn.disabled  = false;
		setMsg(_('Installed successfully'), 'green');
	};

	const installBtn = E('button', {
		class: 'btn cbi-button cbi-button-action',
		style: 'margin-left:4px',
		disabled: !canInstall || null,
		title: canInstall ? '' : _('No supported package manager detected'),
		click: function() { return doInstall(); }
	}, [ installed ? _('Update') : _('Install') ]);

	const removeBtn = E('button', {
		class: 'btn cbi-button cbi-button-negative',
		style: 'margin-left:4px',
		disabled: !installed || null,
		click: async function() {
			removeBtn.disabled  = true;
			installBtn.disabled = true;
			setMsg(_('Removing...'), 'gray');

			const ret = await L.resolveDefault(callCoreRemove(), {});

			installBtn.disabled = false;
			if (ret.result) {
				installed = false;
				version   = null;
				statusEl.textContent = _('Not installed');
				statusEl.style.color = 'gray';
				installBtn.textContent = _('Install');
				setMsg(_('Removed successfully'), 'green');
			} else {
				removeBtn.disabled = false;
				setMsg(ret.error || _('Removal failed'), 'red');
			}
		}
	}, [ _('Remove') ]);

	return E('div', { style: 'margin-bottom:12px; padding:8px 10px; border:1px solid #ddd; border-radius:4px' }, [
		E('div', { style: 'display:flex; align-items:center; flex-wrap:wrap; gap:6px' }, [
			E('strong', {}, name),
			statusEl,
			checkBtn,
			remoteEl,
			installBtn,
			removeBtn,
			msgEl
		]),
		E('div', { style: 'margin-top:4px; font-size:0.9em; color:#666' }, desc)
	]);
}

function buildLimCoreAppCard() {
	const statusEl = E('strong', { style: 'color:green' }, _('Installed'));
	const msgEl = E('span', { style: 'margin-left:8px; font-size:0.9em' }, '');
	const setMsg = (txt, color) => { msgEl.textContent = txt; msgEl.style.color = color || 'gray'; };

	const callAppUpdate = rpc.declare({
		object: 'luci.limcore',
		method: 'app_update',
		expect: { '': {} }
	});

	const callAppUpdateStatus = rpc.declare({
		object: 'luci.limcore',
		method: 'app_update_status',
		expect: { '': {} }
	});

	const callAppCheckUpdate = rpc.declare({
		object: 'luci.limcore',
		method: 'app_check_update',
		expect: { '': {} }
	});

	const callCheckAll = rpc.declare({
		object: 'luci.limcore',
		method: 'check_all_updates',
		params: ['refresh'],
		expect: { '': {} }
	});

	/* One line per installed component, so "is anything out of date" is answerable at a
	   glance instead of by opening each card in turn. */
	const allEl = E('div', { style: 'margin-top:6px; font-size:0.9em' }, '');

	const showAll = (ret) => {
		if (!ret || !ret.components) {
			dom.content(allEl, E('em', { style: 'color:#c0392b' }, _('Could not check components')));
			return;
		}
		dom.content(allEl, ret.components.map(function(c) {
			let text, colour;
			if (c.latest === null) {
				text = _('%s — could not reach GitHub').format(c.name);
				colour = '#c0392b';
			} else if (c.update_available) {
				text = _('%s — update available: %s → %s').format(c.name, c.installed, c.latest);
				colour = '#d35400';
			} else {
				text = _('%s — up to date (%s)').format(c.name, c.installed || c.latest);
				colour = 'green';
			}
			return E('div', { style: 'color:' + colour }, text);
		}));
	};

	/* Says outright whether anything needs doing. The old wording — "Latest: v<tag>" in
	   orange — left you comparing two version strings by eye to work out which was which. */
	const versionEl = E('span', { style: 'margin-left:8px; font-size:0.9em; color:gray' }, '');

	const showVersions = (ret) => {
		if (!ret || ret.error) {
			versionEl.style.color = '#c0392b';
			versionEl.textContent = (ret && ret.error) ? ret.error : _('Check failed');
			return;
		}
		if (ret.update_available) {
			versionEl.style.color = '#d35400';
			versionEl.textContent = _('Update available: %s → %s').format(ret.installed, ret.latest);
			updateBtn.classList.add('cbi-button-positive');
		} else {
			versionEl.style.color = 'green';
			versionEl.textContent = _('Up to date (%s)').format(ret.installed || ret.latest);
			updateBtn.classList.remove('cbi-button-positive');
		}
	};

	const checkBtn = E('button', {
		class: 'btn cbi-button',
		style: 'margin-left:4px',
		click: async function() {
			checkBtn.disabled = true;
			versionEl.style.color = 'gray';
			versionEl.textContent = _('Checking…');
			dom.content(allEl, E('em', { style: 'color:gray' }, _('Checking every installed component…')));
			/* refresh: the cache exists to stop page loads burning the hourly GitHub
			   budget, but pressing the button is an explicit request for fresh data. */
			const [app, all] = await Promise.all([
				L.resolveDefault(callAppCheckUpdate(), {}),
				L.resolveDefault(callCheckAll('1'), {})
			]);
			showVersions(app);
			showAll(all);
			checkBtn.disabled = false;
		}
	}, [ _('Check update') ]);

	/* Check once when the page opens, so the answer is already on screen. Cached server
	   side, so reloading the page costs no API quota. */
	L.resolveDefault(callAppCheckUpdate(), {}).then(showVersions);
	L.resolveDefault(callCheckAll(''), {}).then(showAll);

	const updateBtn = E('button', {
		class: 'btn cbi-button cbi-button-action',
		style: 'margin-left:4px',
		click: async function() {
			updateBtn.disabled = true;
			statusEl.textContent = _('Updating...');
			statusEl.style.color = 'orange';
			setMsg(_('Starting LimCore update...'), 'gray');

			const res = await L.resolveDefault(callAppUpdate(), {});
			if (!res || res.result === false) {
				updateBtn.disabled = false;
				statusEl.textContent = _('Installed');
				statusEl.style.color = 'green';
				setMsg(res.error || _('Failed to launch update process'), 'red');
				return;
			}

			const stop = (text, color, reload) => {
				clearInterval(timer);
				updateBtn.disabled = false;
				statusEl.textContent = reload ? _('Updated') : _('Installed');
				statusEl.style.color = reload ? 'green' : 'red';
				setMsg(text, color);
				if (reload)
					setTimeout(() => { window.location.reload(); }, 2000);
			};

			/* Don't equate "process gone" with "update succeeded": the updater writes an
			   explicit completion marker, and its absence means it was killed mid-run. */
			let pollCount = 0;
			var timer = setInterval(async () => {
				pollCount++;
				const st = await L.resolveDefault(callAppUpdateStatus(), {});

				/* finished wins over running: the completion marker is authoritative, and
				   a stale PID file must never keep the page spinning. */
				if (st && st.finished) {
					if (st.exit_code === 0)
						stop(_('LimCore successfully updated! Reloading...'), 'green', true);
					else
						stop(_('Update failed (exit code %d) — see /tmp/limcore-update.log').format(st.exit_code),
						     'red', false);
				} else if (st && st.running) {
					setMsg(_('Updating LimCore & dependencies in background...'), 'gray');
				} else if (st && st.interrupted) {
					stop(_('Update was interrupted before it finished — see /tmp/limcore-update.log'), 'red', false);
				}

				if (pollCount > 150)
					stop(_('Update is still running after 5 minutes — check /tmp/limcore-update.log'), 'darkorange', false);
			}, 2000);
		}
	}, [ _('Update LimCore') ]);

	return E('div', { style: 'margin-bottom:12px; padding:8px 10px; border:1px solid #ddd; border-radius:4px' }, [
		E('div', { style: 'display:flex; align-items:center; flex-wrap:wrap; gap:6px' }, [
			E('strong', {}, 'LimCore App (luci-app-limcore)'),
			statusEl,
			versionEl,
			checkBtn,
			updateBtn,
			msgEl
		]),
		allEl,
		E('div', { style: 'margin-top:4px; font-size:0.9em; color:#666' },
			_('Automated one-click updater for LimCore LuCI application, translations, and core scripts from GitHub releases. Updating also refreshes the core, ByeDPI and Zapret when they are installed.'))
	]);
}

return view.extend({
	load() {
		return Promise.all([
			hp.getBuiltinFeatures(),
			L.resolveDefault(callCoreInfo(), {}),
			uci.load('limcore'),
			L.resolveDefault(callByeDPIStatus(), {}),
			L.resolveDefault(callCurlStatus(), {}),
			L.resolveDefault(callZapretStatus(), {})
		]);
	},

	render([features, coreInfo, _uci, byedpiStatus, curlStatus, zapretStatus]) {
		const routingMode = uci.get('limcore', 'config', 'routing_mode') || '';
		const isRuMode = routingMode === 'proxy_banned_ru';
		let m, s, o;

		m = new form.Map('limcore');

		s = m.section(form.NamedSection, 'config', 'limcore', _('Resources management'));
		s.anonymous = true;

		o = s.option(form.DummyValue, '_active_core', _('Active core'));
		const coreName = features.core_type === 'singbox' ? 'sing-box' : null;
		const coreVer = features.version ? ' v' + features.version : '';
		const coreCustomSuffix = features.core_custom ? ' (custom)' : '';

		if (!features.core_type) {
			const callDetectCustomCore = rpc.declare({
				object: 'luci.limcore',
				method: 'detect_custom_core',
				params: ['path'],
				expect: { '': {} }
			});

			const savedPath = uci.get('limcore', 'config', 'custom_core_path') || '';
			const pathInput = E('input', {
				'type': 'text',
				'class': 'cbi-input-text',
				'value': savedPath,
				'placeholder': '/path/to/sing-box',
				'style': 'width:260px; margin-right:4px'
			});
			const detectMsg = E('span', { 'style': 'margin-left:8px; font-size:0.9em; color:gray' }, '');
			const detectBtn = E('button', {
				'class': 'btn cbi-button cbi-button-action',
				'click': async function() {
					const path = pathInput.value.trim();
					if (!path) return;
					detectBtn.disabled = true;
					detectMsg.textContent = _('Detecting...');
					detectMsg.style.color = 'gray';
					const ret = await L.resolveDefault(callDetectCustomCore(path), {});
					detectBtn.disabled = false;
					if (ret.result) {
						detectMsg.textContent = _('Detected') + ': sing-box' + (ret.version ? ' v' + ret.version : '') + ' — ' + _('reload page to apply');
						detectMsg.style.color = 'green';
					} else {
						detectMsg.textContent = ret.error || _('Detection failed');
						detectMsg.style.color = 'red';
					}
				}
			}, [ _('Detect') ]);

			o.default = E('div', {}, [
				E('strong', { 'style': 'color:red' }, _('No core installed')),
				E('details', { 'style': 'margin-top:6px' }, [
					E('summary', { 'style': 'cursor:pointer; color:#666; font-size:0.9em' }, _('I have a custom core path')),
					E('div', { 'style': 'margin-top:6px' }, [ pathInput, detectBtn, detectMsg ])
				])
			]);
		} else {
			o.default = E('strong', { 'style': 'color:green' }, coreName + coreVer + coreCustomSuffix);
		}

		/* Region rule-sets (geosite/geoip .srs) are versioned and refreshed by the core itself,
		 * so there are no local list-version files to display here. */


		if (!isRuMode) {
			o = s.option(form.Value, 'github_token', _('GitHub token'));
			o.description = _('Used to check for ByeDPI and Zapret updates. Without a token, GitHub limits anonymous requests to 60/hour. Create at github.com → Settings → Developer settings → Personal access tokens (no scopes needed).');
			o.password = true;
			o.renderWidget = function() {
				let node = form.Value.prototype.renderWidget.apply(this, arguments);

				(node.querySelector('.control-group') || node).appendChild(E('button', {
					'class': 'cbi-button cbi-button-apply',
					'title': _('Save'),
					'click': ui.createHandlerFn(this, () => {
						return this.map.save(null, true).then(() => {
							ui.changes.apply(true);
						});
					}, this.option)
				}, [ _('Save') ]));

				return node;
			}
		}

		s = m.section(form.NamedSection, 'config', 'limcore', _('Core management'));
		s.anonymous = true;

		o = s.option(form.DummyValue, '_core_env');
		const tmpMB     = coreInfo.tmp_free_kb     != null ? Math.round(coreInfo.tmp_free_kb     / 1024) : '?';
		const overlayMB = coreInfo.overlay_free_kb != null ? Math.round(coreInfo.overlay_free_kb / 1024) : '?';
		o.default = E('div', { style: 'font-size:0.9em; color:#555; padding:2px 0 6px' }, [
			_('Package manager') + ': ',
			E('strong', {}, coreInfo.pkg_manager || _('none detected')),
			E('span', { style: 'margin:0 8px' }, '|'),
			_('Architecture') + ': ',
			E('strong', {}, coreInfo.arch || '?'),
			E('span', { style: 'margin:0 8px' }, '|'),
			_('Free /tmp') + ': ',
			E('strong', {
				style: (coreInfo.tmp_free_kb != null && coreInfo.tmp_free_kb < 30720) ? 'color:red' : 'color:green'
			}, tmpMB + ' MB'),
			E('span', { style: 'margin:0 8px' }, '|'),
			_('Free overlay') + ': ',
			E('strong', {
				style: (coreInfo.overlay_free_kb != null && coreInfo.overlay_free_kb < 30720) ? 'color:red' : 'color:green'
			}, overlayMB + ' MB')
		]);

		o = s.option(form.DummyValue, '_app_limcore');
		o.default = buildLimCoreAppCard();

		o = s.option(form.Flag, 'app_auto_update', _('Update LimCore automatically'),
			_('Install new releases on a schedule, without opening this page. Uses the same updater as the button above.'));
		o.default = o.enabled;
		o.rmempty = false;

		o = s.option(form.ListValue, 'app_auto_update_days', _('How often'));
		o.value('1', _('Every day'));
		o.value('3', _('Every 3 days'));
		o.value('7', _('Every week'));
		o.value('14', _('Every 2 weeks'));
		o.default = '3';
		o.depends('app_auto_update', '1');

		o = s.option(form.ListValue, 'app_auto_update_hour', _('At'));
		for (let h = 0; h < 24; h++)
			o.value(String(h), (h < 10 ? '0' + h : String(h)) + ':00');
		o.default = '4';
		o.depends('app_auto_update', '1');

		o = s.option(form.DummyValue, '_core_singbox');
		o.default = buildCoreCard(coreInfo);

		s = m.section(form.NamedSection, 'config', 'limcore', _('AntiDPI'));
		s.anonymous = true;

		o = s.option(form.DummyValue, '_byedpi_card');
		o.default = buildByeDPICard(byedpiStatus, uci.get('limcore', 'config', 'main_node') === 'byedpi-out');

		o = s.option(form.DummyValue, '_curl_card', _('ByeDPI strategy tester'));
		o.default = buildCurlCard(curlStatus);

		o = s.option(form.DummyValue, '_zapret_card');
		o.default = buildZapretCard(zapretStatus);

		s = m.section(form.NamedSection, 'config', 'limcore');
		s.anonymous = true;

		o = s.option(form.DummyValue, '_daemon_logview');
		o.render = L.bind(getRuntimeLog, this, o, _('LimCore'));

		o = s.option(form.DummyValue, '_core_logview');
		o.render = L.bind(getRuntimeLog, this, o, _('core client'));

		return m.render();
	},

	handleSaveApply: null,
	handleSave: null,
	handleReset: null
});
