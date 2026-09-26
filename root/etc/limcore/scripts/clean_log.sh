#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
#
# Copyright (C) 2022-2023 ImmortalWrt.org

NAME="limcore"

log_max_size="50"           #KB
runaway_size=$((log_max_size * 10))
main_log_file="/var/run/$NAME/daemon.log"
core_log_file="/var/run/$NAME/core.log"

size_kb() {
	echo $(( $(wc -c < "$1" 2>/dev/null || echo 0) / 1024 ))
}

# Keep one generation instead of emptying. Truncating on overflow threw away the only
# record of whatever filled the log in the first place — usually a burst of errors, i.e.
# precisely what someone would want to read afterwards.
#
# The copy is deliberate, and `mv` here is a bug that cost a router: sing-box holds the
# log open and writes by inode, so moving the file does not make it let go — it keeps
# writing into core.log.1 while core.log stays empty forever. Rotation then never fires
# again (it only ever measures core.log), and the rotated file grows without bound. These
# logs live in /var/run, which is tmpfs, so that growth is RAM: on a 240 MB router it ate
# everything in about eighteen hours and took LuCI and ssh down with it. Copy-then-truncate
# keeps the inode, so the writer stays pointed at a file we can still empty.
while true; do
	sleep 180
	for i in "$main_log_file" "$core_log_file"; do
		# An instance that predates this fix still has its writer stuck on the rotated
		# file, and nothing else would ever cap it. Truncating in place bounds the damage
		# without waiting for a restart.
		[ "$(size_kb "$i.1")" -ge "$runaway_size" ] && : > "$i.1"

		[ -s "$i" ] || continue
		[ "$(size_kb "$i")" -ge "$log_max_size" ] && {
			cp -f "$i" "$i.1"
			: > "$i"
		}
	done
done
