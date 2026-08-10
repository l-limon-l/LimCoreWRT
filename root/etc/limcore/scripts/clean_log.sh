#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
#
# Copyright (C) 2022-2023 ImmortalWrt.org

NAME="limcore"

log_max_size="50" #KB
main_log_file="/var/run/$NAME/daemon.log"
core_log_file="/var/run/$NAME/core.log"

# Rotate instead of emptying. Truncating on overflow threw away the only record of
# whatever filled the log in the first place — usually a burst of errors, i.e. precisely
# what someone would want to read afterwards. One generation is kept, so at worst the
# evidence is one file over.
while true; do
	sleep 180
	for i in "$main_log_file" "$core_log_file"; do
		[ -s "$i" ] || continue
		[ "$(( $(ls -l "$i" | awk -F ' ' '{print $5}') / 1024 >= log_max_size))" -eq "0" ] || {
			mv -f "$i" "$i.1"
			: > "$i"
		}
	done
done
