#!/usr/bin/ucode
/*
 * SPDX-License-Identifier: GPL-2.0-only
 *
 * Copyright (C) 2026 l_limon_l
 */

/* TCP connect time to a node, for the ping setting "TCP".
 *
 * Usage: tcping.uc <mark> <host> <port> <count>
 *
 * The router's own TCP is redirected into the core, so a plain connect from here reaches
 * the core on this box and reads well under a millisecond whatever the node. The socket
 * carries the core's own mark instead, which the firewall lets out untouched - the same
 * way the core's own connections leave.
 *
 * Prints "<code>:<seconds> " per attempt, the shape the rpcd side already reads for curl:
 * 200 for a connect that went through, 000 for one that did not. */

'use strict';

import * as socket from 'socket';

const mark = int(ARGV[0]), host = ARGV[1], port = int(ARGV[2]), count = int(ARGV[3]) || 3;

function once(addr) {
	const s = socket.create(addr.family, socket.SOCK_STREAM | socket.SOCK_NONBLOCK);
	if (!s)
		return null;
	if (mark > 0)
		s.setopt(socket.SOL_SOCKET, socket.SO_MARK, mark);
	const t0 = clock(true);
	s.connect(addr.addr);
	const r = socket.poll(2000, [ s, socket.POLLOUT ]);
	const t1 = clock(true);
	const err = s.getopt(socket.SOL_SOCKET, socket.SO_ERROR);
	s.close();
	if (!r || !r[0] || !r[0][1] || err)
		return null;
	return (t1[0] - t0[0]) + (t1[1] - t0[1]) / 1e9;
}

let out = [];
const ai = (host && port > 0 && port < 65536)
	? socket.addrinfo(host, '' + port, { socktype: socket.SOCK_STREAM }) : null;
for (let i = 0; i < count; i++) {
	const t = (ai && length(ai)) ? once(ai[0]) : null;
	push(out, (t == null) ? '000:0' : sprintf('200:%.6f', t));
}
print(join(' ', out), '\n');
