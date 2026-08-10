#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
#
# Samples the things that matter when someone says "it went slow for a minute", and writes
# one line per sample. Intermittent trouble is impossible to diagnose after the fact
# otherwise: by the time it is reported, everything measures fine again, which is exactly
# what kept happening here.
#
# Deliberately cheap. The node delay goes through the tunnel but fetches a 204, the WAN
# check is one ping to the gateway, and the DNS check is a local lookup. A sample costs
# well under a kilobyte, so this can run continuously without distorting what it measures.

NAME="limcore"
RUN_DIR="/var/run/$NAME"
LOG="$RUN_DIR/health.log"
INTERVAL="${1:-60}"
MAX_KB=200

mkdir -p "$RUN_DIR"

gw() { ip route | awk '/^default/{print $3; exit}'; }

while true; do
	TS=$(date "+%Y-%m-%d %H:%M:%S")

	# Latency to the proxy node, as the core itself measures it. Empty when the core is
	# down or the Clash API is off — which is itself worth recording.
	DELAY=$(wget -qO- --timeout=8 \
		"http://127.0.0.1:9090/proxies/main-out/delay?timeout=5000&url=http%3A%2F%2Fwww.gstatic.com%2Fgenerate_204" \
		2>/dev/null | sed -n 's/.*"delay":\([0-9]*\).*/\1/p')

	# Is the upstream link itself healthy? Separates "the proxy is unhappy" from "the
	# internet is gone", which is the first fork in any such investigation.
	G=$(gw)
	if [ -n "$G" ]; then
		WAN=$(ping -c 1 -W 2 "$G" 2>/dev/null | sed -n 's/.*time=\([0-9.]*\).*/\1/p')
	else
		WAN=""
	fi

	# Local resolution, through dnsmasq and the core's DNS inbound.
	DS=$(date +%s%N)
	nslookup ya.ru 127.0.0.1 >/dev/null 2>&1 && DOK=ok || DOK=FAIL
	DE=$(date +%s%N)
	DNS=$(( (DE - DS) / 1000000 ))

	printf '%s node=%sms wan=%sms dns=%sms/%s\n' \
		"$TS" "${DELAY:-DOWN}" "${WAN:-DOWN}" "$DNS" "$DOK" >> "$LOG"

	# Keep it bounded, keeping one generation like the other logs here.
	if [ -s "$LOG" ] && [ "$(( $(ls -l "$LOG" | awk '{print $5}') / 1024 ))" -ge "$MAX_KB" ]; then
		mv -f "$LOG" "$LOG.1"
		: > "$LOG"
	fi

	sleep "$INTERVAL"
done
