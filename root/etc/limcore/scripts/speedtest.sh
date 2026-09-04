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
# Usage: speedtest.sh <core_path> <socks_port> <target> <result_file> <config_file> #                     <log_file> [queue_file] [running_marker]
#   target: node section ids separated by spaces, or '' for every configured node.
#   queue_file: nodes another tab asked for while this sweep was running, one list per
#     line. They are picked up when the sweep runs out of its own, because two sweeps at
#     once would share the uplink and measure each other.
#
# Writes NDJSON to <result_file>: one object per node, rewritten in place as that node
# moves through its stages, so a poller always sees the whole table with the node in hand
# carrying its running figure.

CORE="$1"
PORT="$2"
TARGET="$3"
RESULT="$4"
CFG="$5"
LOG="$6"
QUEUE="$7"
RUNNING="$8"

API='https://www.speedtest.net/api/js/servers?engine=js&limit=5&https_functional=true'

# Several streams, not one. A single TCP connection through a proxy is bounded by its
# window over the round trip, so a node 200 ms away reports a fraction of what it can
# carry and a near one reports most of it — the ranking then measures distance rather than
# the node. Measured here against the same node, one stream said 4.9 Mbit/s where the
# desktop VPN client, which also uses several, said an order of magnitude more.
PAR=4

# Fifteen seconds a phase, which is what speedtest.net spends on its own: the number here
# is read next to the one the browser gives, so it has to be taken over the same kind of
# window. Shorter is not a cheaper version of the same measurement - a few seconds is spent
# almost entirely in TCP slow start and the tunnel's own ramp, so it reports the climb
# rather than the ceiling, and it reports it low.
#
# The sweep is serial, so this is also its length: about forty seconds a node once the core
# is up, and a dozen nodes is therefore several minutes rather than one.
DL_TIME=15
UP_TIME=15
NONCE=$(date +%s)$$
LINES="$RESULT.part"
TMPD="/tmp/limcore-speedtest.d"

SERVER=''
HOST=''
BASE=''
PING_URL=''
PROXY=''
CORE_PID=''
PIDS=''

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
# check it carries. Returns non-zero if it does not, and the sweep reports that node as a
# failure and carries on rather than stopping on it.
#
# Two tries of a few seconds, not twenty of them. A dead node is the case this path is on
# most often — a sweep of a dozen nodes usually has two or three — and waiting a minute and
# a half for each to prove it is dead is most of why a sweep felt endless. A node that
# needs longer than this to answer at all is not a node anyone wants their traffic on.
start_core() {
	ucode /etc/limcore/scripts/generate_client.uc speedtest "$PORT" "$1" > "$CFG" 2>/dev/null
	[ -s "$CFG" ] || return 1

	# A core left over from a run that was killed mid-way holds the port, and the new one
	# would exit on bind while the test happily measured the old one's outbound.
	kill $(ps w | grep "[-]c $CFG" | awk '{print $1}') 2>/dev/null

	"$CORE" run -c "$CFG" > "$LOG" 2>&1 &
	CORE_PID=$!
	sleep 1

	i=0
	while [ $i -lt 2 ]; do
		# A core that died on its own config will never answer, and waiting out the
		# timeout to discover that is time spent on nothing.
		kill -0 "$CORE_PID" 2>/dev/null || return 1

		curl -s -x "socks5h://127.0.0.1:$PORT" --max-time 5 -o /dev/null \
			http://www.gstatic.com/generate_204 2>/dev/null && return 0
		i=$((i+1))
	done
	return 1
}

pick_server() {
	# One object per line first, because the API answers with a single line and busybox
	# sed has no lazy quantifiers to pick fields out of it.
	LIST=$(curl -s $PROXY --max-time 15 "$API" 2>/dev/null | sed 's/},{/}\n{/g')
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
		if curl -s $PROXY --max-time 6 -o /dev/null -f "$U?x=$NONCE" 2>/dev/null; then
			PING_URL="$U"
			break
		fi
	done
	return 0
}

# Response time, not a ping: through a SOCKS proxy curl's time_connect is the hop to the
# proxy on loopback and always reads about zero, so the figure that means anything is how
# long the far end takes to answer. Best of two, for the reason ping reports a minimum.
measure_ping() {
	i=0
	while [ -n "$PING_URL" ] && [ $i -lt 2 ]; do
		T=$(curl -s $PROXY --max-time 6 -o /dev/null -w '%{time_starttransfer}' \
			"$PING_URL?x=$NONCE$i" 2>/dev/null)
		case "$T" in
			''|0.000000|*[!0-9.]*) ;;
			*) PING=$(awk -v a="$PING" -v b="$T" 'BEGIN{ b=b*1000; if (a=="" || b<a) printf "%.1f", b; else printf "%.1f", a }') ;;
		esac
		i=$((i+1))
	done
}

# What the running streams have actually pulled, divided by how long they have been at it.
#
# The obvious source, the average speed curl prints in its own meter, could not be summed:
# each stream averages from its own start, the streams' stderr reaches their files in
# bursts rather than in step, and a stream that ends on a timeout replaces its last
# progress line with an error message. Summing four "last lines" therefore mixed figures
# from different moments with parsed nonsense, and the total jumped around instead of
# climbing — it looked made up because it was.
#
# Bytes received do not have those problems: the count only ever grows, a finished stream
# has its exact total in its result file, and a stream still running has it in the meter's
# fourth column. Elapsed time comes from the caller, so every stream is divided by the same
# clock.
#
# Nothing else on the box could report a transfer in flight: this kernel has no per-process
# IO accounting, and the bytes cannot be counted by writing them to a file first -- eight
# seconds at 300 Mbit/s is 300 MB and /tmp is RAM.
running_speed() {
	pfx="$1"
	started="$2"
	# Which column carries the bytes: curl's meter counts a download under "Received" and an
	# upload under "Xferd", and reading the download column during an upload reports a
	# confident zero for the whole transfer.
	col="$3"

	elapsed=$(( $(date +%s) - started ))
	# Under two seconds there is nothing worth showing: an upload of a few megabytes can be
	# over inside the first tick, and dividing it by a one-second clock printed the size of
	# the payload as if it were a speed.
	[ "$elapsed" -lt 2 ] && return

	for f in "$TMPD"/$pfx.*.prog; do
		[ -f "$f" ] || continue
		res="${f%.prog}.res"
		if [ -s "$res" ]; then
			# Finished: the exact byte count, rather than a meter line that may have been
			# overwritten by curl's parting error message.
			awk '{ print $2 }' "$res"
		else
			# Still running: the last line that is actually a progress line. Anything else
			# in this file is curl telling us why it stopped.
			tr '
' '
' < "$f" | grep -E '^ *[0-9]' | tail -1 | awk -v c="$col" '{ print $c }'
		fi
	done | awk -v el="$elapsed" '{
		v = $1
		if (v ~ /^[0-9]+$/)
			n = v + 0
		else if (v ~ /^[0-9.]+[kMG]$/) {
			u = substr(v, length(v), 1)
			n = substr(v, 1, length(v) - 1) + 0
			if (u == "k") n *= 1024
			else if (u == "M") n *= 1048576
			else n *= 1073741824
		} else
			n = 0
		s += n
	} END {
		# Under a few hundred kilobytes the streams are still opening and the quotient is
		# noise, which is the one thing this must not print.
		if (s > 200000) printf "%d", s / el
	}'
}

# Report the climb while it happens rather than one number at the end: the figure people
# trust is the one they watched settle, and on a serial sweep a cell that only ever says
# "download…" for eight seconds gives them nothing to read.
watch_streams() {
	pfx="$1"
	stage="$2"
	started="$3"
	while :; do
		alive=0
		for pid in $PIDS; do
			kill -0 "$pid" 2>/dev/null && alive=1
		done
		[ "$alive" = 1 ] || break

		if [ "$stage" = download ]; then col=4; else col=6; fi
		cur=$(running_speed "$pfx" "$started" "$col")
		if [ -n "$cur" ]; then
			if [ "$stage" = download ]; then DL="$cur"; else UP="$cur"; fi
			flush "$stage"
		fi
		sleep 1
	done
}

# Sum of what the streams finally reported, not of the running meter: the meter averages
# over the ramp-up and always reads a little under the ceiling.
total_speed() {
	cat "$TMPD"/$1.*.res 2>/dev/null | awk '{ s += $1; b += $2 } END { printf "%d %d", s, b }'
}

start_streams() {
	url="$1"
	pfx="$2"
	rm -f "$TMPD"/$pfx.*
	PIDS=''
	i=0
	while [ $i -lt $PAR ]; do
		# No -s: silent suppresses the progress meter along with everything else, and the
		# meter is the only live view of the transfer there is.
		curl $PROXY --max-time "$3" -o /dev/null \
			-w '%{speed_download} %{size_download}\n' "$url&stream=$i" \
			> "$TMPD/$pfx.$i.res" 2> "$TMPD/$pfx.$i.prog" &
		PIDS="$PIDS $!"
		i=$((i+1))
	done
}

# Two shapes of Speedtest server: the newer OoklaServer takes a size and streams until the
# time is up, the older PHP ones serve a fixed random image. The sized one is tried first
# because it is what the list mostly returns now, and because a fixed 25 MB image is over
# in under a second on a fast node and measures the ramp-up rather than the ceiling.
measure_download() {
	# The size has to be more than a stream can pull in DL_TIME, or the transfer ends on
	# running out of payload instead of on the clock and the phase measures the ramp again:
	# a stream doing 10 MB/s wants 150 MB of it, and the old 100 MB was already short.
	for U in "http://$HOST/download?nocache=$NONCE&size=1000000000" "$BASE/random4000x4000.jpg?nocache=$NONCE"; do
		STARTED=$(date +%s)
		start_streams "$U" dl "$DL_TIME"
		watch_streams dl download "$STARTED"
		wait $PIDS 2>/dev/null

		set -- $(total_speed dl)
		if [ "${2:-0}" -gt 1000000 ] 2>/dev/null; then
			DL="$1"
			return 0
		fi
	done
	DL=''
	return 1
}

# From /dev/zero down a pipe rather than a temp file: /tmp is RAM on these boxes and a
# payload per stream written there is how you fill it.
#
# Streamed with -T rather than handed over with --data-binary, and that is the whole fix
# for an upload figure that used to arrive in about a second. --data-binary needs a
# Content-Length, so curl reads the entire payload into memory before it sends any of it,
# which caps the payload at what the box can hold - it was six megabytes a stream, gone in
# under a second on a fast node. The phase then ended long inside its own budget, the
# number it reported was the ramp-up rather than the speed, and the cell never showed a
# climb because the transfer was over before the first tick that could have drawn one.
#
# -T - sends chunked from stdin instead, holding nothing: measured on this router it moved
# 553 MB in 15 s with free memory unchanged. The far end never gets to answer, since the
# clock cuts the request off mid-body, so curl exits on timeout and its http_code is
# meaningless here - which is already true of the download, and why both phases are judged
# by the bytes -w reports rather than by curl's exit status.
measure_upload() {
	for U in "http://$HOST/upload?nocache=$NONCE" "$BASE/upload.php?nocache=$NONCE"; do
		rm -f "$TMPD"/ul.*
		STARTED=$(date +%s)
		PIDS=''
		i=0
		while [ $i -lt $PAR ]; do
			cat /dev/zero | curl $PROXY --max-time "$UP_TIME" -o /dev/null \
				-X POST -H 'Content-Type: application/octet-stream' -T - \
				-w '%{speed_upload} %{size_upload}\n' "$U&stream=$i" \
				> "$TMPD/ul.$i.res" 2> "$TMPD/ul.$i.prog" &
			PIDS="$PIDS $!"
			i=$((i+1))
		done
		watch_streams ul upload "$STARTED"
		wait $PIDS 2>/dev/null

		set -- $(total_speed ul)
		if [ "${2:-0}" -gt 500000 ] 2>/dev/null; then
			UP="$1"
			return 0
		fi
	done
	UP=''
	return 1
}

run_one() {
	SECTION="$1"
	# The caller ages the marker out to decide whether a sweep is still alive, and a
	# queue can carry this one well past that window. Touching it per node keeps a
	# working sweep alive without keeping an abandoned one alive.
	[ -n "$RUNNING" ] && touch "$RUNNING" 2>/dev/null
	LABEL=$(uci -q get "limcore.$SECTION.label")
	[ -n "$LABEL" ] || LABEL=$(uci -q get "limcore.$SECTION.address")
	[ -n "$LABEL" ] || LABEL="$SECTION"

	flush core
	if ! start_core "$SECTION"; then
		flush error "no answer from this node"
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

rm -rf "$TMPD"
mkdir -p "$TMPD"
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

TESTED=''
while [ -n "$TARGETS" ]; do
	for T in $TARGETS; do
		# A tab pressed twice, or two tabs sharing a node, would otherwise measure it
		# twice and write a second row for it.
		case " $TESTED " in *" $T "*) continue ;; esac
		run_one "$T"
		TESTED="$TESTED $T"
	done

	# Whatever was asked for while this sweep was busy. Taken by rename so a press that
	# lands between the read and the clear is not swallowed.
	TARGETS=''
	if [ -n "$QUEUE" ] && [ -s "$QUEUE" ]; then
		if mv "$QUEUE" "$QUEUE.taken" 2>/dev/null; then
			TARGETS=$(cat "$QUEUE.taken" 2>/dev/null)
			rm -f "$QUEUE.taken"
		fi
	fi
done

rm -rf "$TMPD"
rm -f "$LINES"
exit 0
