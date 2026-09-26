/*
 * SPDX-License-Identifier: GPL-2.0-only
 *
 * Copyright (C) 2024-2026 l_limon_l
 */

'use strict';
'require dom';
'require fs';
'require poll';
'require rpc';
'require uci';
'require ui';
'require view';

'require limcore';

/* The landing page: whether everything is working, and the few things done often enough
 * to deserve a switch here instead of a trip into the settings. It writes nothing of its
 * own — every switch sets the same option its settings page does. */

const callServiceList = rpc.declare({
	object: 'rc',
	method: 'list',
	params: ['name'],
	expect: { '': {} }
});

const callServiceInit = rpc.declare({
	object: 'rc',
	method: 'init',
	params: ['name', 'action'],
	expect: { '': {} }
});

const callActiveNode = rpc.declare({
	object: 'luci.limcore',
	method: 'clash_active_node',
	params: ['tag'],
	expect: { '': {} }
});

const callSelectNode = rpc.declare({
	object: 'luci.limcore',
	method: 'clash_select_node',
	params: ['tag', 'name'],
	expect: { '': {} }
});

const callNodesProbeStart = rpc.declare({
	object: 'luci.limcore',
	method: 'nodes_probe_start',
	params: ['targets'],
	expect: { '': {} }
});

const callNodesProbeStatus = rpc.declare({
	object: 'luci.limcore',
	method: 'nodes_probe_status',
	expect: { '': {} }
});

const callSpeedtestStart = rpc.declare({
	object: 'luci.limcore',
	method: 'speedtest_start',
	params: ['targets'],
	expect: { '': {} }
});

const callSpeedtestStatus = rpc.declare({
	object: 'luci.limcore',
	method: 'speedtest_status',
	expect: { '': {} }
});

const callSpeedtestStop = rpc.declare({
	object: 'luci.limcore',
	method: 'speedtest_stop',
	expect: { '': {} }
});

const callCheckAll = rpc.declare({
	object: 'luci.limcore',
	method: 'check_all_updates',
	params: ['refresh'],
	expect: { '': {} }
});

const callByeDPIStatus = rpc.declare({
	object: 'luci.limcore',
	method: 'byedpi_status',
	expect: { '': {} }
});

const callZapretStatus = rpc.declare({
	object: 'luci.limcore',
	method: 'zapret_status',
	expect: { '': {} }
});

const css = '\
.lc-ov-grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(220px, 1fr)); gap: 1em; margin-bottom: 1em; }\
.lc-ov-card { padding: .8em 1em; border: 1px solid rgba(128,128,128,.3); border-radius: 6px; }\
.lc-ov-card h4 { margin: 0 0 .4em; font-size: .9em; font-weight: normal; opacity: .75; }\
.lc-ov-big { font-size: 1.15em; font-weight: bold; }\
.lc-ov-sub { font-size: .85em; opacity: .7; margin-top: .2em; }\
.lc-ov-row { display: flex; align-items: center; justify-content: space-between; gap: 1em; padding: .35em 0; border-top: 1px solid rgba(128,128,128,.2); }\
.lc-ov-row:first-of-type { border-top: 0; }\
.lc-ov-actions { display: flex; gap: .5em; flex-wrap: wrap; }\
.lc-ov-nodes { display: grid; grid-template-columns: repeat(auto-fill, minmax(190px, 1fr)); gap: .4em; }\
.lc-ov-node { padding: .35em .6em; border: 1px solid rgba(128,128,128,.25); border-radius: 6px; cursor: pointer; font-size: .9em; min-width: 0; display: flex; flex-direction: column; justify-content: center; }\
.lc-ov-node .top { display: flex; justify-content: space-between; align-items: center; gap: .6em; }\
.lc-ov-node .s { font-size: .8em; white-space: nowrap; }\
.lc-ov-node .s:empty { display: none; }\
.lc-ov-checks { display: flex; align-items: center; gap: .4em; flex-wrap: wrap; }\
.lc-ov-autorow { display: flex; align-items: stretch; gap: .5em; margin-bottom: .6em; }\
.lc-ov-autorow .lc-ov-node { flex: 1; max-width: 380px; }\
.lc-ov-autorow .lc-ov-node.dpi { flex: 0 1 170px; }.lc-ov-node.auto { position: relative; padding-right: 2.8em; }.lc-ov-gear { position: absolute; right: .45em; top: 50%; transform: translateY(-50%); font-size: 1.6em; line-height: 1; padding: .1em .15em; margin: 0; border: 0; background: transparent; color: inherit; opacity: .55; cursor: pointer; min-height: 0; box-shadow: none; }.lc-ov-gear:hover { opacity: 1; }\
.lc-ov-poolgrp { margin-bottom: .8em; }\
.lc-ov-poolhead { margin-bottom: .3em; }\
.lc-ov-picks { display: grid; grid-template-columns: repeat(auto-fill, minmax(200px, 1fr)); gap: .2em .8em; }\
.lc-ov-pick { display: flex; align-items: center; gap: .3em; cursor: pointer; }\
.lc-ov-node:hover { border-color: rgba(128,128,128,.6); }\
.lc-ov-node.active { border-color: #2e9e5b; box-shadow: inset 0 0 0 1px #2e9e5b; }\
.lc-ov-node.busy { opacity: .5; pointer-events: none; }\
.lc-ov-node .n { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }\
.lc-ov-node .d { white-space: nowrap; }\
.lc-ov-mini { font: inherit; font-size: .85em; line-height: 1; padding: 0 .2em; margin: 0 0 0 .2em; border: 0; background: transparent; color: inherit; opacity: .45; cursor: pointer; min-height: 0; height: auto; box-shadow: none; }\
.lc-ov-mini:hover { opacity: 1; }\
.lc-ov-node .top .d { margin-left: auto; }\
.lc-ov-nodeshead { display: flex; justify-content: space-between; align-items: center; gap: 1em; flex-wrap: wrap; margin-bottom: .6em; }\
.lc-ov-tabs { display: flex; gap: .3em; flex-wrap: wrap; margin-bottom: .6em; }\
.lc-ov-tab { font: inherit; font-size: .85em; padding: .25em .7em; border: 1px solid rgba(128,128,128,.3); border-radius: 6px; background: transparent; color: inherit; cursor: pointer; opacity: .75; }\
.lc-ov-tab.on { opacity: 1; border-color: #2e9e5b; box-shadow: inset 0 0 0 1px #2e9e5b; }';

const MODES = {
	proxy_banned_ru: _('Russia (Proxy Banned)'),
	bypass_cn: _('China (bypass mainland)'),
	bypass_ir: _('Iran (bypass domestic)'),
	global: _('Global'),
	custom: _('Custom routing'),
	custom_json: _('Custom JSON')
};

function nodeLabel(sid) {
	return uci.get('limcore', sid, 'label') || sid;
}

/* The node behind a sing-box outbound tag, as the settings pages name it. */
function tagLabel(tag) {
	const m = tag && tag.match(/^cfg-(.+)-out$/);
	return m ? nodeLabel(m[1]) : tag;
}

function card(title, body) {
	return E('div', { 'class': 'lc-ov-card' }, [ E('h4', {}, title) ].concat(body));
}

function pageLink(path, text) {
	return E('a', { 'class': 'btn cbi-button', 'href': L.url('admin/services/limcore/' + path) }, text);
}

/* One switch bound to a boolean in limcore.config. Applied at once, the way the log
 * level on the system page is: a switch that needed a separate Save would not be one. */
let switchSeq = 0;

/* The markup LuCI's own Flag produces, down to the two wrappers around it: themes draw a
 * switch only for `.cbi-value > .cbi-value-field > .cbi-checkbox`, and a bare checkbox
 * otherwise. The wrappers take no box of their own, so the row keeps its layout. */
function switchWidget(checked) {
	const id = 'lc-ov-sw-' + (++switchSeq);
	const input = E('input', { 'type': 'checkbox', 'id': id, 'checked': checked ? '' : null });
	return { input, el: E('div', { 'class': 'cbi-value', 'style': 'display:contents' },
		E('div', { 'class': 'cbi-value-field', 'style': 'display:contents' },
			E('div', { 'class': 'cbi-checkbox' }, [ input, E('label', { 'for': id }) ]))) };
}

function optionSwitch(option, extraCheck) {
	const { input, el } = switchWidget(uci.get('limcore', 'config', option) === '1');
	input.addEventListener('change', function() {
		const want = input.checked;
		const refusal = want && extraCheck ? extraCheck() : null;
		if (refusal) {
			input.checked = false;
			ui.addNotification(null, E('p', refusal), 'error');
			return;
		}
		input.disabled = true;
		uci.set('limcore', 'config', option, want ? '1' : '0');
		return uci.save().then(() => ui.changes.apply(true));
	});
	return el;
}

return view.extend({
	load() {
		return Promise.all([
			uci.load('limcore'),
			limcore.getBuiltinFeatures(),
			L.resolveDefault(callServiceList('limcore'), {}),
			L.resolveDefault(callByeDPIStatus(), {}),
			L.resolveDefault(callZapretStatus(), {})
		]);
	},

	render([, features, services, byedpi, zapret]) {
		/* rc list runs the init script to answer, and while LimCore is restarting - a switch
		 * or a node was just changed - it times out and says nothing. Nothing is not "off":
		 * reading it that way showed the core as stopped and its switch off while it was
		 * starting up. An unknown state is shown as such and read again below. */
		const svc = services?.limcore || null;
		let running = !!svc?.running;
		const mode = uci.get('limcore', 'config', 'routing_mode') || 'proxy_banned_ru';
		const rules = uci.sections('limcore', 'proxy_ru_rule').filter((r) => r.enabled !== '0' && r.source);
		/* The servers inside a provider's auto-select group are its business, not choices of
		 * their own: they are reached through the group. */
		const nodes = uci.sections('limcore', 'node').filter((n) => !n.member_of);

		/* --- status cards ------------------------------------------------------------ */
		const coreName = features.core_type === 'singbox' ? 'sing-box' : null;
		const coreStr = coreName ? '%s %s'.format(coreName, features.version ? 'v' + features.version : '') : _('no core installed');

		const coreStateEl = E('div', { 'class': 'lc-ov-big' }, '');
		const paintCore = (st) => {
			coreStateEl.textContent = !st ? '…' : st.running ? _('RUNNING') : _('NOT RUNNING');
			coreStateEl.style.color = !st ? 'gray' : st.running ? 'green' : '#c00';
		};
		paintCore(svc);
		const statusCard = card(_('Core'), [
			coreStateEl,
			E('div', { 'class': 'lc-ov-sub' }, coreStr)
		]);

		const activeEl = E('div', { 'class': 'lc-ov-big' }, '—');
		const activeSub = E('div', { 'class': 'lc-ov-sub' }, '');
		const mainNode = uci.get('limcore', 'config', 'main_node') || 'nil';
		activeSub.textContent = (mainNode === 'urltest') ? _('URLTest') :
			(mainNode === 'nil') ? _('Disable') :
			(mainNode === 'byedpi-out' || mainNode === 'zapret-out') ? _('DPI bypass, no VPN') : _('Main node');
		const activeCard = card(_('Active node'), [ activeEl, activeSub ]);

		const modeCard = card(_('Routing mode'), [
			E('div', { 'class': 'lc-ov-big' }, MODES[mode] || mode),
			E('div', { 'class': 'lc-ov-sub' }, _('%d proxy rules on').format(rules.length))
		]);

		let activeTag = null;
		const refreshActive = () => {
			if (!running) {
				activeEl.textContent = '—';
				activeEl.style.color = '';
				return Promise.resolve();
			}
			return L.resolveDefault(callActiveNode('main-out'), {}).then((ret) => {
				if (!ret || ret.error || !ret.node) {
					activeEl.textContent = _('No active node');
					activeEl.style.color = 'gray';
					activeTag = null;
				} else {
					/* With a single node as the main one there is no group to ask: the answer
					 * is main-out itself, and the node behind it is the one configured. */
					activeTag = /^cfg-.+-out$/.test(ret.node) ? ret.node
						: (/^(nil|urltest|byedpi-out|zapret-out)$/.test(mainNode) ? ret.node : 'cfg-' + mainNode + '-out');
					const band = limcore.delayBand(ret.delay);
					/* A provider's group is named the way its app names it. The member it is
					 * on carries the provider's internal tag ("proxy-3"), which means nothing
					 * to anyone, so it is not shown. */
					/* A bypass is no node: the core reports it as a direct outbound called
					 * main-out, which is no name to show anyone. */
					const dpiName = { 'zapret-out': 'Zapret', 'byedpi-out': 'ByeDPI' }[mainNode];
					const name = dpiName || (groupMain ? nodeLabel(mainNode) : tagLabel(activeTag));
					activeEl.textContent = name +
						((band === 'dead') ? ' — ' + _('timeout') : (band !== 'none') ? ' — ' + ret.delay + ' ms' : '');
					activeEl.style.color = limcore.delayColor(ret.delay);
				}
				/* In the pool the pick is either held on a node or left to URLTest. */
				const held = isPool && /^cfg-.+-out$/.test(ret.selected || '');
				/* A provider's auto-select group as the main node reports the member it is
				 * on, and members have no tile: the group's own tile is the one to light. */
				for (const row of nodeRows)
					row.tile.classList.toggle('active', groupMain ? row.sid === mainNode
					                                              : activeTag === 'cfg-' + row.sid + '-out');
				autoTile.tile.classList.toggle('active', isPool && !held);
			});
		};

		/* --- nodes, in the order the subscriptions give them --------------------------
		 * A grid of small tiles rather than a list: thirty nodes one per line pushed
		 * everything else off the screen. Clicking a tile makes it the node in use. */
		const AUTO = 'main-urltest-out';
		const isPool = (mainNode === 'urltest');
		const groupMain = nodes.some((n) => n['.name'] === mainNode && n.type === 'urltest');
		/* Only members that still exist: a pool keeps the names of nodes a removed
		 * subscription took with it. */
		const pool = (uci.get('limcore', 'config', 'main_urltest_nodes') || [])
			.filter((sid) => nodes.some((n) => n['.name'] === sid));

		const choose = (tile, sid) => {
			/* Turning on a pool that has no members yet means choosing them first. */
			if (sid === null && !pool.length)
				return editPool();
			if (isPool && (sid === null || pool.includes(sid))) {
				/* The pool keeps running and only the pick changes: no restart. */
				tile.classList.add('busy');
				return L.resolveDefault(callSelectNode('main-out', sid ? 'cfg-' + sid + '-out' : AUTO), {}).then((ret) => {
					tile.classList.remove('busy');
					if (!ret || ret.result !== true)
						ui.addNotification(null, E('p', ret?.error || _('Could not switch')), 'error');
					return refreshActive();
				});
			}
			const target = sid ? nodeLabel(sid) : _('Best node');
			if (!confirm(_('Make %s the main node? LimCore restarts and the connection drops for a few seconds.').format(target)))
				return;
			tile.classList.add('busy');
			uci.set('limcore', 'config', 'main_node', sid || 'urltest');
			return uci.save().then(() => ui.changes.apply(true));
		};

		const makeTile = (sid, label) => {
			const delay = E('span', { 'class': 'd' }, '');
			const speed = E('div', { 'class': 's' }, '');
			const tile = E('div', { 'class': 'lc-ov-node', 'title': label }, [
				E('div', { 'class': 'top' }, [ E('span', { 'class': 'n' }, label), delay ]),
				speed
			]);
			const row = { sid, delay, speed, tile };
			tile.addEventListener('click', () => choose(tile, sid));
			/* One node's speed on its own, without choosing it: the click stops here. */
			if (sid)
				tile.querySelector('.top').appendChild(E('button', {
					'class': 'lc-ov-mini',
					'title': _('Check the speed of this node'),
					'click': (ev) => { ev.stopPropagation(); return runSpeed([ row ]); }
				}, '⇅'));
			return row;
		};

		const nodeRows = nodes.map((n) => makeTile(n['.name'], (pool.includes(n['.name']) ? '★ ' : '') + nodeLabel(n['.name'])));

		/* Best node sits above the subscription groups rather than in one of them: its
		 * pool is picked from every subscription at once, and from own nodes too. Choosing
		 * it hands the choice to the pool, or turns the pool on. */
		const autoTile = makeTile(null, '★ ' + _('Best node'));
		autoTile.tile.classList.add('auto');
		autoTile.speed.textContent = pool.length ? _('Nodes in the pool: %d').format(pool.length) : _('not set up yet');
		/* Its settings open from a gear on the tile itself; the click stops there, so it
		 * does not also choose the pool. */
		autoTile.tile.appendChild(E('button', {
			'class': 'lc-ov-gear',
			'title': _('Pick the nodes'),
			'click': (ev) => { ev.stopPropagation(); editPool(); }
		}, '⚙'));

		/* The DPI bypasses as main nodes: traffic that would go through a VPN goes out
		 * directly instead, with the bypass applied. They used to be picked in the main node
		 * list on the Routing page, which is gone now that the main node is chosen here.
		 * Choosing one turns its engine on too - a main node pointing at a bypass that is off
		 * would quietly send everything direct. */
		const dpiTile = (label, target, status, option, blocked) => {
			if (!status?.installed)
				return null;
			const tile = E('div', { 'class': 'lc-ov-node dpi' + ((mainNode === target) ? ' active' : '') }, [
				E('div', { 'class': 'top' }, [ E('span', { 'class': 'n' }, label) ]),
				E('div', { 'class': 's' }, _('DPI bypass, no VPN'))
			]);
			tile.addEventListener('click', () => {
				if (mainNode === target)
					return;
				const why = blocked ? blocked() : null;
				if (why)
					return ui.addNotification(null, E('p', why), 'warning');
				if (!confirm(_('Make %s the main node? LimCore restarts and the connection drops for a few seconds.').format(label)))
					return;
				tile.classList.add('busy');
				uci.set('limcore', 'config', option, '1');
				uci.set('limcore', 'config', 'main_node', target);
				return uci.save().then(() => ui.changes.apply(true));
			});
			return tile;
		};
		const zapretBlocked = () => (zapret?.kmod_ok === false)
			? _('Zapret is installed, but the NFQUEUE kernel module (kmod-nft-queue) is missing.<br>Turning it on now could break the firewall. Reinstall Zapret or install kmod-nft-queue first.')
			: null;
		const dpiTiles = [
			dpiTile('Zapret', 'zapret-out', zapret, 'zapret_enabled', zapretBlocked),
			dpiTile('ByeDPI', 'byedpi-out', byedpi, 'byedpi_enabled')
		].filter((t) => t);

		/* Which nodes the pool measures and picks from, grouped the way the tiles are. */
		const editPool = () => {
			const checks = {};
			const body = groups.map((g) => {
				/* Every server on the tab, groups included. A provider sends a server as a
				 * group when it carries several transports of one host (TLS, Reality,
				 * XHTTP), and leaving groups out dropped six of Sworkle's ten servers from
				 * the list. sing-box takes a group inside the pool as it is. */
				const pickable = g.rows;
				const picks = pickable.map((r) => {
					const cb = E('input', { 'type': 'checkbox', 'checked': pool.includes(r.sid) ? '' : null });
					checks[r.sid] = cb;
					return E('label', { 'class': 'lc-ov-pick' }, [ cb, ' ', nodeLabel(r.sid) ]);
				});
				const setAll = (on) => (ev) => {
					ev.preventDefault();
					for (const r of pickable) checks[r.sid].checked = on;
				};
				return E('div', { 'class': 'lc-ov-poolgrp' }, [
					E('div', { 'class': 'lc-ov-poolhead' }, [
						E('strong', {}, g.title), ' ',
						E('a', { 'href': '#', 'click': setAll(true) }, _('check all')), ' · ',
						E('a', { 'href': '#', 'click': setAll(false) }, _('uncheck all'))
					]),
					E('div', { 'class': 'lc-ov-picks' }, picks)
				]);
			});
			const err = E('p', { 'style': 'color:#c00' }, '');
			const save = (turnOn) => {
				const chosen = nodeRows.filter((r) => checks[r.sid]?.checked).map((r) => r.sid);
				if (!chosen.length) {
					err.textContent = _('Pick at least one node.');
					return;
				}
				uci.set('limcore', 'config', 'main_urltest_nodes', chosen);
				if (turnOn)
					uci.set('limcore', 'config', 'main_node', 'urltest');
				ui.hideModal();
				return uci.save().then(() => ui.changes.apply(true));
			};
			ui.showModal(_('Best node'), [
				E('p', {}, _('Best node measures these nodes and keeps traffic on the fastest one, leaving a node that stops answering.<br>Nodes from different subscriptions can be mixed.<br>Saving restarts LimCore.')),
				E('div', {}, body),
				err,
				E('div', { 'class': 'right' }, [
					E('button', { 'class': 'btn', 'click': ui.hideModal }, _('Cancel')), ' ',
					isPool
						? E('button', { 'class': 'btn cbi-button-action', 'click': () => save(false) }, _('Save'))
						: E('button', { 'class': 'btn cbi-button-action', 'click': () => save(true) }, _('Save and turn on'))
				])
			]);
		};

		const paint = (row, delay) => {
			if (delay == null) { row.delay.textContent = _('no answer'); row.delay.style.color = '#c00'; }
			else { row.delay.textContent = '%d ms'.format(delay); row.delay.style.color = limcore.delayColor(delay); }
		};

		/* Down / up in Mbit/s under the name, with the same bands as the Nodes page used:
		 * below 10 is why video buffers, however well the node pings. Grey until final. */
		const paintSpeed = (row, r) => {
			const el = row.speed;
			el.title = '';
			if (r.state === 'error') {
				el.textContent = '↓ – ↑ –';
				el.style.color = '#c00';
				if (r.error) el.title = r.error;
				return;
			}
			const dl = (r.download == null) ? null : (r.download * 8) / 1000000;
			const up = (r.upload == null) ? null : (r.upload * 8) / 1000000;
			const fmt = (v) => (v == null) ? '–' : (v >= 100 ? v.toFixed(0) : v.toFixed(1));
			if (r.state !== 'done' && dl == null) {
				el.textContent = _('testing…');
				el.style.color = 'gray';
				return;
			}
			el.textContent = '↓ %s ↑ %s'.format(fmt(dl), fmt(up));
			el.style.color = (r.state !== 'done') ? 'gray'
				: (dl == null) ? '#c00' : (dl >= 50) ? '#2e9e5b' : (dl >= 10) ? '#c80' : '#c00';
		};

		/* Both checks measure the group on screen: picking a group is picking the set of
		 * nodes, and the two buttons next to each other mean the same set. */
		const shownRows = () => (groups[shown]?.rows || []);
		const rowOf = (sid) => nodeRows.find((x) => x.sid === sid);

		const sweepMsg = E('span', { 'class': 'lc-ov-sub', 'style': 'margin-left:.6em' }, '');
		const sweepBtn = E('button', {
			'class': 'btn cbi-button cbi-button-action',
			'disabled': nodes.length ? null : '',
			'click': ui.createHandlerFn(this, () => {
				const rows = shownRows();
				for (const r of rows) { r.delay.textContent = '…'; r.delay.style.color = ''; }
				sweepMsg.style.color = '';
				sweepMsg.textContent = _('Testing…');
				return callNodesProbeStart(rows.map((r) => r.sid).join(' ')).then((res) => {
					if (!res || res.result !== true)
						throw new Error(res?.error || _('could not start the test'));
					const total = res.total || rows.length;
					const deadline = Date.now() + 90000;
					const step = () => new Promise((ok) => window.setTimeout(ok, 1500))
						.then(callNodesProbeStatus)
						.then((st) => {
							for (const r of (st?.results || [])) {
								const row = rowOf(r.section);
								if (row) paint(row, r.delay);
							}
							const seen = (st?.results || []).length;
							if (!st || st.running !== true) {
								sweepMsg.textContent = _('Tested %d of %d nodes.').format(seen, total);
								return;
							}
							sweepMsg.textContent = _('Testing… %d of %d').format(seen, total);
							if (Date.now() > deadline) {
								sweepMsg.textContent = _('Test timed out.');
								return;
							}
							return step();
						});
					return step();
				}).catch((e) => { sweepMsg.textContent = e.message || _('Test failed'); });
			})
		}, [ _('Check delay') ]);

		/* One node at a time on the router, since two transfers over one line measure each
		 * other; each result is painted the moment it is in. A press while another run is
		 * going queues these nodes behind it rather than joining it. */
		let speedStopped = false;
		const stopBtn = E('button', {
			'class': 'btn cbi-button cbi-button-negative',
			'style': 'display:none',
			'click': () => {
				speedStopped = true;
				stopBtn.disabled = true;
				stopBtn.textContent = _('Stopping…');
				return L.resolveDefault(callSpeedtestStop(), {});
			}
		}, [ _('Stop') ]);
		const showStop = (on) => {
			stopBtn.style.display = on ? '' : 'none';
			if (on) { stopBtn.disabled = false; stopBtn.textContent = _('Stop'); }
		};

		const runSpeed = (rows) => {
			const mine = {};
			for (const r of rows) mine[r.sid] = true;

			speedStopped = false;
			showStop(true);
			sweepMsg.style.color = '';
			sweepMsg.textContent = _('Starting…');

			return callSpeedtestStart(rows.map((r) => r.sid).join(' ')).then((res) => {
				const attached = (res && res.result !== true && res.running === true);
				const queued = (res && res.result === true && res.queued === true);
				if (!res || (res.result !== true && !attached))
					throw new Error(res?.error || _('could not start the test'));

				if (attached)
					sweepMsg.textContent = _('A test was already running — showing it.');
				else {
					if (queued)
						sweepMsg.textContent = _('Queued — these nodes are measured once the running test finishes.');
					for (const r of rows) { r.speed.textContent = '…'; r.speed.style.color = ''; r.speed.title = ''; }
				}

				const total = rows.length;
				const deadline = Date.now() + ((queued || attached) ? 1800000 : Math.max(120000, total * 60000));

				const step = () => new Promise((ok) => window.setTimeout(ok, 1500))
					.then(callSpeedtestStatus)
					.then((st) => {
						const results = st?.results || [];
						for (const r of results) {
							const row = rowOf(r.section);
							if (row) paintSpeed(row, r);
						}
						const ours = results.filter((r) => mine[r.section]);

						if (!st || st.running !== true) {
							showStop(false);
							/* A node the run never finished - not reached, or cut off by
							 * Stop mid-transfer - keeps no half figure that reads as live. */
							const final = {};
							for (const r of ours)
								if (r.state === 'done' || r.state === 'error') final[r.section] = true;
							for (const r of rows)
								if (!final[r.sid]) { r.speed.textContent = ''; r.speed.style.color = ''; }
							const done = ours.filter((r) => r.state === 'done').length;
							sweepMsg.textContent = speedStopped
								? _('Stopped — %d of %d nodes measured.').format(done, total)
								: _('Tested %d of %d nodes.').format(done, total);
							return;
						}

						const waiting = (st.pending || []).filter((sec) => mine[sec]).length;
						sweepMsg.textContent = (!ours.length && waiting)
							? _('Queued — %d nodes waiting for the running test.').format(waiting)
							: _('Testing… %d of %d').format(ours.length, total);

						if (Date.now() > deadline) {
							showStop(false);
							sweepMsg.style.color = '#c00';
							sweepMsg.textContent = _('Test timed out.');
							return;
						}
						return step();
					});
				return step();
			}).catch((e) => {
				showStop(false);
				sweepMsg.style.color = '#c00';
				sweepMsg.textContent = e.message || _('Test failed');
			});
		};

		const speedBtn = E('button', {
			'class': 'btn cbi-button cbi-button-action',
			'disabled': nodes.length ? null : '',
			'click': ui.createHandlerFn(this, () => runSpeed(shownRows()))
		}, [ _('Check speed') ]);

		/* Nodes grouped by subscription, the way desktop clients group them, named after
		 * the subscription's profile-title when the provider sends one (saved by the
		 * subscription update) and after the URL fragment or host otherwise. Nodes that
		 * belong to no subscription form a group of their own, first. */
		const titles = {};
		for (const e of (uci.get('limcore', 'subscription', 'subscription_title') || [])) {
			const m = e.match(/^([0-9a-f]{32}) (.+)$/);
			if (m) titles[m[1]] = m[2];
		}
		const groups = (uci.get('limcore', 'subscription', 'subscription_url') || []).map((url) => {
			const hash = limcore.calcStringMD5(url.replace(/#.*$/, ''));
			let fallback = url;
			try {
				const u = new URL(url);
				fallback = u.hash ? decodeURIComponent(u.hash.slice(1)) : u.hostname;
			} catch (e) {}
			return { hash, title: titles[hash] || fallback };
		});
		const known = groups.map((g) => g.hash);
		if (nodes.some((n) => !known.includes(n.grouphash)))
			groups.unshift({ hash: null, title: _('Own nodes') });
		for (const g of groups)
			g.rows = nodeRows.filter((r) => g.hash ? uci.get('limcore', r.sid, 'grouphash') === g.hash
			                                       : !known.includes(uci.get('limcore', r.sid, 'grouphash')));

		const gridEl = E('div', { 'class': 'lc-ov-nodes' });
		const tabsEl = E('div', { 'class': 'lc-ov-tabs' });
		const subUpdateEl = E('div', { 'class': 'lc-ov-subupd' });
		let shown = groups.findIndex((g) => g.rows.some((r) => r.sid === mainNode));
		try {
			const back = sessionStorage.getItem('limcore-ov-group');
			sessionStorage.removeItem('limcore-ov-group');
			if (back && groups.some((g) => g.hash === back))
				shown = groups.findIndex((g) => g.hash === back);
		} catch (e) {}
		if (shown < 0) shown = 0;

		const updateSub = (g) => {
			if (!confirm(_('Update subscription %s? If the provider changed anything, the core restarts at the end and the connection drops for a moment.').format(g.title)))
				return;
			dom.content(subUpdateEl, E('em', { 'class': 'lc-ov-sub' }, _('Fetching nodes…')));
			return fs.exec_direct('/etc/limcore/scripts/update_subscriptions.uc', [ g.hash ])
				.then((out) => {
					if (!String(out).includes('LIMCORE_SUB_OK'))
						throw new Error(_('the update did not finish, the LimCore log has the details'));
					/* Back on this subscription after the reload, not on the main node's. */
					try { sessionStorage.setItem('limcore-ov-group', g.hash); } catch (e) {}
					location.reload();
				})
				.catch((err) => dom.content(subUpdateEl, E('span', { 'style': 'color:#c00' },
					_('An error occurred during updating subscriptions: %s').format(err?.message || err))));
		};

		const showGroup = (i) => {
			shown = i;
			const g = groups[i];
			dom.content(gridEl, (g ? g.rows : []).map((r) => r.tile));
			Array.prototype.forEach.call(tabsEl.children, (b, j) => b.classList.toggle('on', j === i));
			dom.content(subUpdateEl, (g && g.hash) ? E('button', {
				'class': 'btn cbi-button',
				'click': ui.createHandlerFn(this, () => updateSub(g))
			}, _('Update subscription')) : '');
		};

		/* Shown whenever there is a subscription, so its name is on screen even when it is
		 * the only one. */
		const withTabs = groups.some((g) => g.hash);
		if (withTabs)
			groups.forEach((g, i) => tabsEl.appendChild(E('button', {
				'class': 'lc-ov-tab',
				'click': () => showGroup(i)
			}, '%s (%d)'.format(g.title, g.rows.length))));
		showGroup(shown);

		const nodesCard = card(_('Nodes'), [
			E('div', { 'class': 'lc-ov-nodeshead' }, [
				E('div', { 'class': 'lc-ov-checks' }, [ sweepBtn, speedBtn, stopBtn, sweepMsg ]),
				subUpdateEl
			]),
			(nodes.length || dpiTiles.length) ? E('div', { 'class': 'lc-ov-autorow' }, [
				nodes.length ? autoTile.tile : '',
				...dpiTiles
			]) : '',
			withTabs ? tabsEl : '',
			nodes.length ? gridEl : E('em', {}, _('No nodes configured.')),
			E('div', { 'class': 'lc-ov-sub', 'style': 'margin-top:.6em' }, isPool
				? _('Click a node to hold traffic on it; the change is immediate. Automatic hands the choice back to the pool.')
				: _('Click a node to make it the main node. LimCore restarts to apply it.'))
		]);

		/* --- switches ---------------------------------------------------------------- */
		const { input: svcSwitch, el: svcSwitchEl } = switchWidget(!!(svc && (svc.running || svc.enabled)));
		if (!svc)
			svcSwitch.disabled = true;
		/* Read again until there is an answer, and on after that, so a restart that was
		 * still under way when the page loaded does not leave the page saying so. */
		const refreshSvc = () => L.resolveDefault(callServiceList('limcore'), {}).then((res) => {
			const st = res?.limcore;
			if (!st)
				return;
			paintCore(st);
			running = !!st.running;
			if (svcSwitch.dataset.busy !== '1') {
				svcSwitch.checked = !!(st.running || st.enabled);
				svcSwitch.disabled = false;
			}
		});
		poll.add(refreshSvc, 5);
		svcSwitch.addEventListener('change', function() {
			const on = svcSwitch.checked;
			if (!on && !confirm(_('Stop LimCore? Traffic will go directly, without the proxy, until it is switched back on.'))) {
				svcSwitch.checked = true;
				return;
			}
			svcSwitch.disabled = true;
			svcSwitch.dataset.busy = '1';
			/* enable/disable as well as start/stop: a switch left off should stay off
			 * across a reboot, not come back on by itself. */
			const steps = on ? [ 'enable', 'start' ] : [ 'stop', 'disable' ];
			return steps.reduce((p, a) => p.then(() => L.resolveDefault(callServiceInit('limcore', a), {})), Promise.resolve())
				.then(() => window.setTimeout(() => location.reload(), 1500));
		});

		const dpiRow = (name, status, option, extraCheck) => E('div', { 'class': 'lc-ov-row' }, [
			E('span', {}, name),
			status?.installed ? optionSwitch(option, extraCheck)
			                  : E('a', { 'href': L.url('admin/services/limcore/dpi') }, _('Install'))
		]);

		const switchesCard = card(_('Quick switches'), [
			E('div', { 'class': 'lc-ov-row' }, [ E('span', {}, 'LimCore'), svcSwitchEl ]),
			dpiRow('ByeDPI', byedpi, 'byedpi_enabled'),
			dpiRow('Zapret', zapret, 'zapret_enabled', zapretBlocked)
		]);

		/* --- updates ------------------------------------------------------------------ */
		const updatesEl = E('div', {}, E('em', { 'class': 'lc-ov-sub' }, _('Collecting data...')));
		const updatesCard = card(_('Updates'), [ updatesEl ]);
		L.resolveDefault(callCheckAll(''), null).then((ret) => {
			if (!ret || !ret.components) {
				dom.content(updatesEl, E('em', { 'style': 'color:#c0392b' }, _('Could not check components')));
				return;
			}
			dom.content(updatesEl, ret.components.map((c) => {
				let text, colour;
				if (c.latest === null) { text = _('could not reach GitHub'); colour = '#c0392b'; }
				else if (c.update_available) { text = '%s → %s'.format(c.installed, c.latest); colour = '#d35400'; }
				else { text = _('up to date'); colour = 'green'; }
				return E('div', { 'class': 'lc-ov-row' }, [ E('span', {}, c.name), E('span', { 'style': 'color:' + colour }, text) ]);
			}));
		});

		refreshActive();
		poll.add(refreshActive, 10);

		return E([
			E('style', {}, css),
			E('h2', {}, _('Overview')),
			E('div', { 'class': 'lc-ov-grid' }, [ statusCard, activeCard, modeCard ]),
			nodesCard,
			E('div', { 'class': 'lc-ov-grid', 'style': 'margin-top:1em' }, [ switchesCard, updatesCard ]),
			E('div', { 'class': 'lc-ov-actions' }, [
				pageLink('system/diagnostics', _('Diagnostics')),
				pageLink('system/core', _('Logs'))
			])
		]);
	},

	handleSaveApply: null,
	handleSave: null,
	handleReset: null
});
