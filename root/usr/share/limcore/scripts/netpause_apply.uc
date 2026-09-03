#!/usr/bin/ucode
/*
 * SPDX-License-Identifier: GPL-2.0-only
 *
 * Device Control — per-device internet kill switch.
 *
 * Ported into LimCore from Device-Control (luci-app-netpause) by Yany1944:
 * https://github.com/Yany1944/Device-Control
 * The devices now live in LimCore's own UCI file and the table is named
 * limcore_netpause, so this can coexist with a standalone netpause install
 * rather than fighting it over the same table.
 *
 * Builds a private nftables table and loads it in one atomic `nft -f`.
 *
 * The table hooks prerouting at priority -450, ahead of everything fw4 installs
 * (its earliest is raw, -300) and therefore ahead of LimCore's own transparent
 * proxy. That placement is the whole point: LimCore REDIRECTs TCP and TPROXYs
 * UDP in prerouting, so the packet is delivered locally and never reaches the
 * forward chain. A conventional MAC-based block rule lives in forward and would
 * silently miss all proxied traffic, which on this router is nearly everything.
 */

'use strict';

import { cursor } from 'uci';
import { writefile } from 'fs';

const RULE_FILE = '/var/run/limcore-netpause.nft';

const uci = cursor();
uci.load('limcore');

const enabled = uci.get('limcore', 'netpause', 'enabled') !== '0';

let macs = [];
uci.foreach('limcore', 'device', (d) => {
	if (d.paused !== '1')
		return;

	/* Normalise: nftables wants lower case, and the UI may hand back whatever
	   case the lease file happened to carry. */
	const mac = lc(trim(d.mac ?? ''));
	if (match(mac, /^([0-9a-f]{2}:){5}[0-9a-f]{2}$/) && index(macs, mac) === -1)
		push(macs, mac);
});

/* Declaring the table before deleting it makes the delete safe on a first run,
   when no such table exists yet. Both statements ride in the same transaction,
   so the ruleset is never momentarily half-applied. */
let out = 'table inet limcore_netpause {\n}\ndelete table inet limcore_netpause\n';

if (enabled && length(macs) > 0) {
	out += 'table inet limcore_netpause {\n';
	out += '\tset paused {\n';
	out += '\t\ttype ether_addr\n';
	out += '\t\telements = { ' + join(', ', macs) + ' }\n';
	out += '\t}\n\n';
	out += '\tchain prerouting {\n';
	out += '\t\ttype filter hook prerouting priority -450; policy accept;\n';
	/* DHCP stays open so a paused device keeps its lease and reappears in the
	   device list by name instead of turning into a bare MAC. */
	out += '\t\tether saddr @paused udp dport { 67, 68 } counter accept comment "limcore netpause: keep DHCP"\n';
	/* Anything addressed to the router itself stays open, so the paused device
	   can still reach LuCI, SSH and DNS. Only traffic leaving for the world is
	   dropped — the device reads as "connected, no internet", not "no network".
	   At this priority the destination is still the original one: the proxy's
	   redirect has not rewritten it yet. */
	out += '\t\tether saddr @paused fib daddr type local counter accept comment "limcore netpause: keep router access"\n';
	out += '\t\tether saddr @paused counter drop comment "limcore netpause: paused device"\n';
	out += '\t}\n';
	out += '}\n';
}

if (!writefile(RULE_FILE, out)) {
	warn('limcore netpause: cannot write ' + RULE_FILE + '\n');
	exit(1);
}

const rc = system('/usr/sbin/nft -f ' + RULE_FILE + ' 2>&1');
if (rc !== 0) {
	warn('limcore netpause: nft refused the ruleset (exit ' + rc + ')\n');
	exit(1);
}

exit(0);
