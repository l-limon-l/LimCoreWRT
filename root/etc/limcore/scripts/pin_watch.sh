#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
#
# Gives a hand-picked node back to URLTest once it stops being the right choice.
#
# Pinning a node in the main selector is deliberate — URLTest chooses on latency alone, and
# the fastest node by ping is not always the one to use — but a pin is absolute: the core
# will sit on that node while it answers in two seconds, and go on sitting on it while it
# answers not at all. Nothing in the core moves off a selector's choice, so without this the
# only thing that can notice is a person, and they notice by finding the internet broken.
#
# So the pin is watched rather than made conditional. Every interval this measures the
# pinned node and every other node in the pool through the core's own API, and hands the
# selector back to the pool ("Automatic") when the pinned node is either not answering at
# all or is slower than the best alternative by more than the configured margin. The choice
# then belongs to URLTest again — including the failover that is the reason to run a pool —
# and the page shows "Automatic" the next time it polls, so the change is visible rather
# than silent.
#
# The measurements are the same ones URLTest re-selects on: asking a node for a delay writes
# that answer into its history inside the core. Watching the pin therefore also keeps the
# pool's own numbers fresh, so the node it picks the moment it gets the choice back is
# picked on data from seconds ago rather than from whenever it last tested itself.
#
# Usage: pin_watch.sh [interval_seconds] [margin_ms]
#   margin 0 = only a node that stops answering is given back; any delay is tolerated.

NAME="limcore"
RUN_DIR="/var/run/$NAME"
LOG="$RUN_DIR/daemon.log"
API="http://127.0.0.1:9090"
TEST_URL="http%3A%2F%2Fwww.gstatic.com%2Fgenerate_204"

# The two tags the generator emits for URLTest mode: the selector traffic actually leaves
# through, and the pool inside it. Both are fixed names, so a pin is recognisable as
# "main-out holds something other than the pool".
SELECTOR="main-out"
POOL="main-urltest-out"

INTERVAL="${1:-180}"
MARGIN="${2:-150}"

[ "$INTERVAL" -ge 30 ] 2>/dev/null || INTERVAL=180
[ "$MARGIN" -ge 0 ] 2>/dev/null || MARGIN=150

mkdir -p "$RUN_DIR"

log() {
	echo -e "$(date "+%Y-%m-%d %H:%M:%S") [PIN] $*" >> "$LOG"
}

api_get() {
	wget -qO- --timeout=5 "$API/$1" 2>/dev/null
}

# One node's latency as the core measures it, empty when it did not answer. A failure comes
# back as an error status rather than a number, and wget prints nothing for those, so an
# empty answer here means "unusable" whichever way it failed.
delay_of() {
	wget -qO- --timeout=12 "$API/proxies/$1/delay?timeout=8000&url=$TEST_URL" 2>/dev/null |
		sed -n 's/.*"delay"[ ]*:[ ]*\([0-9][0-9]*\).*/\1/p'
}

# The pinned node gets three attempts spread over half a minute before it is called dead.
# A single measurement is a poor witness — a healthy node misses one now and then, and the
# core is measuring the same node the traffic is using — and the verdict here overrides a
# choice a person made deliberately, so it is worth the extra seconds to be sure.
pinned_delay() {
	local i=1 d=""
	while [ $i -le 3 ]; do
		d=$(delay_of "$1")
		[ -n "$d" ] && { echo "$d"; return; }
		[ $i -lt 3 ] && sleep 5
		i=$((i+1))
	done
}

# Hand the selector back to the pool. The core takes this over its HTTP API and nowhere
# else, and the API wants a PUT — which neither BusyBox wget nor uclient-fetch can send — so
# the request is written straight down a socket with nc.
unpin() {
	local body req
	body="{\"name\":\"$POOL\"}"
	req="PUT /proxies/$SELECTOR HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Type: application/json\r\nContent-Length: ${#body}\r\nConnection: close\r\n\r\n$body"
	printf "$req" | nc 127.0.0.1 9090 >/dev/null 2>&1
}

while true; do
	# What the selector is holding. A group's own object is small enough to read with sed;
	# the whole /proxies document is not.
	INFO=$(api_get "proxies/$SELECTOR")
	PINNED=$(echo "$INFO" | sed -n 's/.*"now"[ ]*:[ ]*"\([^"]*\)".*/\1/p')

	# Nothing to watch: the core is down or still starting, the running config predates the
	# selector, or the choice already belongs to the pool.
	if [ -z "$PINNED" ] || [ "$PINNED" = "$POOL" ]; then
		sleep "$INTERVAL"
		continue
	fi

	PIN_DELAY=$(pinned_delay "$PINNED")

	if [ -z "$PIN_DELAY" ]; then
		unpin
		log "pinned node $PINNED stopped answering — the pool chooses again"
		sleep "$INTERVAL"
		continue
	fi

	# A margin of zero means the pin is held for as long as the node answers at all, so
	# there is nothing left to compare and the rest of the sweep is not worth its cost.
	if [ "$MARGIN" -le 0 ]; then
		sleep "$INTERVAL"
		continue
	fi

	# The best of the alternatives, measured in one pass. In parallel, so a dead node costs
	# its own timeout and not the sweep's — five nodes, one of them gone, would otherwise
	# spend a quarter of a minute on the one that will never answer.
	MEMBERS=$(api_get "proxies/$POOL" |
		sed -n 's/.*"all"[ ]*:[ ]*\[\([^]]*\)\].*/\1/p' | tr -d '" ' | tr ',' ' ')
	TMP="$RUN_DIR/pinwatch.$$"
	rm -rf "$TMP"; mkdir -p "$TMP"
	for M in $MEMBERS; do
		[ "$M" = "$PINNED" ] && continue
		( delay_of "$M" > "$TMP/$M" ) &
	done
	wait
	BEST=$(cat "$TMP"/* 2>/dev/null | sed '/^$/d' | sort -n | head -1)
	BEST_NODE=$(grep -l "^$BEST\$" "$TMP"/* 2>/dev/null | head -1)
	BEST_NODE=$(basename "${BEST_NODE:-unknown}")
	rm -rf "$TMP"

	# Nobody else answered: the pinned node may be slow, but it is the only one working, and
	# handing the pool a choice between nothing and nothing would only make things worse.
	if [ -n "$BEST" ] && [ $((PIN_DELAY - BEST)) -gt "$MARGIN" ]; then
		unpin
		log "pinned node $PINNED at ${PIN_DELAY}ms is more than ${MARGIN}ms behind $BEST_NODE at ${BEST}ms — the pool chooses again"
	fi

	sleep "$INTERVAL"
done
