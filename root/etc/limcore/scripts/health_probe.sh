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
	probe_node() {
		wget -qO- --timeout=8 \
			"http://127.0.0.1:9090/proxies/main-out/delay?timeout=5000&url=http%3A%2F%2Fwww.gstatic.com%2Fgenerate_204" \
			2>/dev/null | sed -n 's/.*"delay":\([0-9]*\).*/\1/p'
	}

	# Confirm a failure before recording one. A single miss can be the API being busy for a
	# moment, and a log full of phantom outages is worse than no log — it sends you
	# investigating something that never happened. Only a second consecutive miss counts as
	# DOWN; one that recovers is marked as such, which is a useful signal in its own right.
	DELAY=$(probe_node)
	RETRIED=""
	if [ -z "$DELAY" ]; then
		sleep 2
		DELAY=$(probe_node)
		[ -n "$DELAY" ] && RETRIED=" recovered-on-retry"
	fi

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

	# "DOWN" reads better than "DOWNms", and a failed sample is the one you will be
	# squinting at later, so keep it unambiguous.
	[ -n "$DELAY" ] && DELAY="${DELAY}ms" || DELAY="DOWN"
	[ -n "$WAN" ] && WAN="${WAN}ms" || WAN="DOWN"

	# Memory, and how much of it /tmp is holding. Both are here because of the outage on
	# 12 Aug 2026: a log rotated by mv kept growing in tmpfs until the router had no memory
	# left, and nothing running at the time recorded either number — so the diagnosis had to
	# be reconstructed afterwards from a device that had already been rebooted clean. Two
	# fields per sample make a repeat explain itself.
	MEM=$(( $(sed -n 's/^MemAvailable: *\([0-9]*\).*/\1/p' /proc/meminfo) / 1024 ))
	TMP=$(( $(df -k /tmp | awk 'NR==2{print $3}') / 1024 ))

	# mem= alone says memory is going, not where. These two name the other two ways this
	# router runs out: the core leaking, and the connection table filling. Without them a
	# falling mem= is only enough to rule the log back in or out, and the investigation
	# stalls exactly where it did last time.
	#
	# No pgrep on this device, hence ps + grep; the bracket keeps the grep out of its own
	# match. RSS is the resident figure — sing-box is Go and reserves over a gigabyte of
	# address space, so VSZ from ps is meaningless here and would read as a permanent leak.
	CORE_PID=$(ps w | grep '[s]ing-box run' | awk '{print $1}' | head -1)
	if [ -n "$CORE_PID" ]; then
		RSS=$(( $(awk '/^VmRSS:/{print $2}' "/proc/$CORE_PID/status" 2>/dev/null || echo 0) / 1024 ))
	else
		RSS=0
	fi
	CT=$(cat /proc/sys/net/netfilter/nf_conntrack_count 2>/dev/null || echo 0)

	printf '%s node=%s wan=%s dns=%sms/%s mem=%sM tmp=%sM rss=%sM ct=%s%s\n' \
		"$TS" "$DELAY" "$WAN" "$DNS" "$DOK" "$MEM" "$TMP" "$RSS" "$CT" "$RETRIED" >> "$LOG"

	# Keep it bounded, keeping one generation like the other logs here.
	#
	# cp rather than mv, matching clean_log.sh. This loop appends with >>, which reopens the
	# file every time, so mv did work here — but only by that accident. The same mv in
	# clean_log.sh met a writer that holds its log open, kept it writing into the rotated
	# file, and cost a router. Leaving a second copy of that pattern around is a trap for
	# whoever changes how this line is written.
	if [ -s "$LOG" ] && [ "$(( $(wc -c < "$LOG") / 1024 ))" -ge "$MAX_KB" ]; then
		cp -f "$LOG" "$LOG.1"
		: > "$LOG"
	fi

	sleep "$INTERVAL"
done
