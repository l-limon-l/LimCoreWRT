#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
#
# Throughput sweep over every configured node, against Ookla's Speedtest network.
#
# The node list answers "does this node answer, and how quickly" — which is latency, and
# latency is not the question anyone actually has about a proxy. A node fronted by a CDN
# pings from the nearest edge and says nothing about the tunnel behind it: the pool here
# sat on its lowest-latency node while that node stalled real transfers for 15 s at a
# time. Only moving bytes tells them apart, so this moves bytes.
#
# One node at a time, unlike the reachability sweep, and not as an oversight: two transfers
# sharing the router's uplink measure each other. Each node is reported the moment it is
# done rather than at the end, so a sweep over eight nodes is readable while it runs.
#
# Ookla is unreachable from Russia without a tunnel, which is why every run goes through a
# node and there is no direct mode to pick: direct would report a blank, not a baseline.
#
# The server is chosen once, by the first node that gets that far, and every later node is
# measured against that same server. Letting each node pick its own nearest server would
# produce a column of numbers taken against different endpoints — which is exactly the
# comparison this exists to make possible.
#
# Usage: speedtest.sh <core_path> <socks_port> <target> <result_file> <config_file> <log_file>
#   target: a node section id to measure just that one, or '' for every configured node.
#
# Writes NDJSON to <result_file>: one object per node, rewritten in place as that node
# moves through its stages, so a poller always sees the whole table with the node in hand
# marked as still running.

CORE="$1"
PORT="$2"
TARGET="$3"
RESULT="$4"
CFG="$5"
LOG="$6"

API='https://www.speedtest.net/api/js/servers?engine=js&limit=5&https_functional=true'
DL_TIME=12
UP_TIME=10
UP_BYTES=8000000
NONCE=$(date +%s)$$
LINES="$RESULT.part"

SERVER=''
HOST=''
BASE=''
PING_URL=''
PROXY=''
CORE_PID=''

# The node being measured right now.
SECTION=''
LABEL=''
PING=''
DL=''
UP=''

json_escape() {
	printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

# The whole table is rewritten on every update rather than appended to: the node in hand
# has to be able to go from a stage word to a row of numbers, and a poller reading an
# append-only file would show it twice.
flush() {
	state="$1"
	err="$2"
	{
		[ -s "$LINES" ] && cat "$LINES"
		printf '{"section":"%s","label":"%s","state":"%s","server":"%s","host":"%s","ping":%s,"download":%s,"upload":%s,"error":%s}\n' \
			"$SECTION" "$(json_escape "$LABEL")" "$state" "$(json_escape "$SERVER")" "$HOST" \
			"${PING:-null}" "${DL:-null}" "${UP:-null}" \
			"$([ -n "$err" ] && printf '"%s"' "$(json_escape "$err")" || printf 'null')"
	} > "$RESULT.tmp"
	mv "$RESULT.tmp" "$RESULT"
}

# Keep the finished node and start a fresh row for the next one.
commit() {
	cat "$RESULT" > "$LINES"
	PING=''
	DL=''
	UP=''
}

cleanup_core() {
	[ -n "$CORE_PID" ] && kill "$CORE_PID" 2>/dev/null
	CORE_PID=''
	rm -f "$CFG"
}

# Bring a throwaway core up on the loopback SOCKS port, wired to exactly this node, and
# wait for it to answer. Returns non-zero if it never does, and the sweep reports that node
# as a failure and carries on rather than stopping on it.
start_core() {
	ucode /etc/limcore/scripts/generate_client.uc speedtest "$PORT" "$1" > "$CFG" 2>/dev/null
	[ -s "$CFG" ] || return 1

	# A core left over from a run that was killed mid-way holds the port, and the new one
	# would exit on bind while the test happily measured the old one's outbound.
	kill $(ps w | grep "[-]c $CFG" | awk '{print $1}') 2>/dev/null

	"$CORE" run -c "$CFG" > "$LOG" 2>&1 &
	CORE_PID=$!

	i=0
	while [ $i -lt 20 ]; do
		curl -s -x "socks5h://127.0.0.1:$PORT" --max-time 3 -o /dev/null \
			http://www.gstatic.com/generate_204 2>/dev/null && return 0
		i=$((i+1))
		sleep 1
	done
	return 1
}

pick_server() {
	# One object per line first, because the API answers with a single line and busybox
	# sed has no lazy quantifiers to pick fields out of it.
	LIST=$(curl -s $PROXY --max-time 20 "$API" 2>/dev/null | sed 's/},{/}\n{/g')
	[ -n "$LIST" ] || return 1

	ENTRY=$(echo "$LIST" | head -n 1)
	HOST=$(echo "$ENTRY" | sed -n 's/.*"host":"\([^"]*\)".*/\1/p')
	URL=$(echo "$ENTRY" | sed -n 's/.*"url":"\([^"]*\)".*/\1/p')
	SPONSOR=$(echo "$ENTRY" | sed -n 's/.*"sponsor":"\([^"]*\)".*/\1/p')
	CITY=$(echo "$ENTRY" | sed -n 's/.*"name":"\([^"]*\)".*/\1/p')
	CC=$(echo "$ENTRY" | sed -n 's/.*"cc":"\([^"]*\)".*/\1/p')
	[ -n "$HOST" ] || return 1

	SERVER="$SPONSOR, $CITY ($CC)"
	BASE=$(echo "$URL" | sed 's#/upload\.php$##')
	[ -n "$BASE" ] || BASE="http://$HOST/speedtest"

	# Two shapes of server: the PHP ones have latency.txt under the base path, the newer
	# OoklaServer answers /hello and has no such file — asking only the first left the
	# figure blank against every modern server in the list.
	for U in "$BASE/latency.txt" "http://$HOST/hello"; do
		if curl -s $PROXY --max-time 8 -o /dev/null -f "$U?x=$NONCE" 2>/dev/null; then
			PING_URL="$U"
			break
		fi
	done
	return 0
}

# Response time, not a ping: through a SOCKS proxy curl's time_connect is the hop to the
# proxy on loopback and always reads about zero, so the figure that means anything is how
# long the far end takes to answer. Best of three, for the reason ping reports a minimum.
measure_ping() {
	i=0
	while [ -n "$PING_URL" ] && [ $i -lt 3 ]; do
		T=$(curl -s $PROXY --max-time 8 -o /dev/null -w '%{time_starttransfer}' \
			"$PING_URL?x=$NONCE$i" 2>/dev/null)
		case "$T" in
			''|0.000000|*[!0-9.]*) ;;
			*) PING=$(awk -v a="$PING" -v b="$T" 'BEGIN{ b=b*1000; if (a=="" || b<a) printf "%.1f", b; else printf "%.1f", a }') ;;
		esac
		i=$((i+1))
	done
}

# Two shapes of Speedtest server again: the PHP ones serve a fixed random image, the newer
# OoklaServer takes a size. Whichever answers with real bytes is the one this server is.
measure_download() {
	for U in "$BASE/random4000x4000.jpg?nocache=$NONCE" "http://$HOST/download?nocache=$NONCE&size=100000000"; do
		R=$(curl -s $PROXY --max-time "$DL_TIME" -o /dev/null -w '%{speed_download} %{size_download}' "$U" 2>/dev/null)
		[ -n "$R" ] || continue
		B=${R##* }
		if [ "${B%%.*}" -gt 1000000 ] 2>/dev/null; then
			DL=${R%% *}
			return 0
		fi
	done
	return 1
}

# From /dev/zero down a pipe rather than a temp file: /tmp is a couple of megabytes of RAM
# on these boxes and an 8 MB payload written there is how you fill it.
measure_upload() {
	for U in "$BASE/upload.php?nocache=$NONCE" "http://$HOST/upload?nocache=$NONCE"; do
		R=$(head -c "$UP_BYTES" /dev/zero | curl -s $PROXY --max-time "$UP_TIME" -o /dev/null \
			-H 'Content-Type: application/octet-stream' --data-binary @- \
			-w '%{speed_upload} %{size_upload}' "$U" 2>/dev/null)
		[ -n "$R" ] || continue
		B=${R##* }
		if [ "${B%%.*}" -gt 500000 ] 2>/dev/null; then
			UP=${R%% *}
			return 0
		fi
	done
	return 1
}

run_one() {
	SECTION="$1"
	LABEL=$(uci -q get "limcore.$SECTION.label")
	[ -n "$LABEL" ] || LABEL=$(uci -q get "limcore.$SECTION.address")
	[ -n "$LABEL" ] || LABEL="$SECTION"

	flush core
	if ! start_core "$SECTION"; then
		flush error "the test core did not come up for this node"
		commit
		cleanup_core
		return 0
	fi

	PROXY="-x socks5h://127.0.0.1:$PORT"

	if [ -z "$HOST" ]; then
		flush servers
		if ! pick_server; then
			flush error "could not reach the Speedtest server list through this node"
			commit
			cleanup_core
			return 0
		fi
	fi

	flush measuring
	measure_ping
	flush download
	measure_download
	flush upload
	measure_upload

	if [ -z "$DL" ]; then
		flush error "the Speedtest server accepted no transfer through this node"
	else
		flush done
	fi
	commit
	cleanup_core
}

rm -f "$LINES" "$RESULT"

if [ -n "$TARGET" ]; then
	TARGETS="$TARGET"
else
	TARGETS=$(uci -q show limcore | sed -n 's/^limcore\.\([^.=]*\)=node$/\1/p')
fi

if [ -z "$TARGETS" ]; then
	SECTION=''
	LABEL=''
	flush error "no nodes configured"
	exit 1
fi

for T in $TARGETS; do
	run_one "$T"
done

rm -f "$LINES"
exit 0
