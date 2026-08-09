#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
#
# Copyright (C) 2022-2023 ImmortalWrt.org

NAME="homeproxy"

log_max_size="50" #KB
main_log_file="/var/run/$NAME/$NAME.log"
limcore_log_file="/var/run/$NAME/limcore.log"

while true; do
	sleep 180
	for i in "$main_log_file" "$limcore_log_file"; do
		[ -s "$i" ] || continue
		[ "$(( $(ls -l "$i" | awk -F ' ' '{print $5}') / 1024 >= log_max_size))" -eq "0" ] || echo "" > "$i"
	done
done
