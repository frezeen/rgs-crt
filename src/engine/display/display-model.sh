#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
# Copyright (C) 2026 FreZeeN
# Part of crt-dual — https://github.com/frezeen
# display-model.sh — wanted state (ADR-002): a PURE function of
# (topology, phase) -> ONE plan. No writes, no state, no machine facts.
#
# Plan format (TAB-separated):
#   SCREEN	<WxH>
#   <x-output>	on|off	<mode|->	primary|-	<pos>	<scale-from|->
# The CRT mode comes from the engine state file (the boot generator names
# it via the Switchres API); with no state file the analog output's first
# offered mode is used. The panel mode is its X-preferred mode. No literal
# connector, resolution or mode name lives in this file.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_DIR="${CRT_DUAL_STATE_DIR:-/tmp/crt-dual}"
XCONF="${CRT_DUAL_XCONF:-/etc/X11/xorg.conf.d/99-crt.conf}"

_x() { timeout 5 env DISPLAY="${DISPLAY:-:0}" xrandr --current 2>/dev/null; }
_modes() { _x | sed -n "/^$1 connected/,/^[^ ]/p" | awk 'NF >= 2 && $1 ~ /^[0-9]/ { print }'; }
_pref() { _modes "$1" | awk '$0 ~ /\+/ { print $1; exit }'; }
_cur() { _modes "$1" | awk '$0 ~ /\*/ { print $1; exit }'; }
_desktop() { # the analog desktop mode: engine state, else the conf's 15 kHz Modeline
	local n
	n=$(awk 'NR == 1 { print $1 }' "$STATE_DIR/crt-desktop-mode" 2>/dev/null)
	[ -n "$n" ] && {
		printf '%s\n' "$n"
		return 0
	}
	# The generated conf is the source of truth (the Switchres API wrote it):
	# pick its 15 kHz-class Modeline by TIMING (clock*1000/htotal in
	# 14-18 kHz) — no literal timing or name in the code.
	awk '
		/^[[:space:]]*Modeline/ {
			name = $2; gsub(/"/, "", name)
			clock = $3; htotal = $7
			if (htotal > 0 && clock * 1000 / htotal >= 14 && clock * 1000 / htotal <= 18) {
				print name
				exit
			}
		}' "$XCONF" 2>/dev/null
}
_size_of() { # "640x480i" -> 640x480; "1920x1080" -> 1920x1080; other -> empty
	case "${1:-}" in
	[0-9]*x[0-9]*) printf '%s' "${1%i}" ;;
	*) printf '' ;;
	esac
}

out=$(bash "$HERE/display-detect.sh" --check 2>/dev/null) || {
	echo "display-model: detect failed (X down or a connected output has no X name)" >&2
	exit 1
}
crt=$(printf '%s' "$out" | sed -n 's/.*crt=\([^ ]*\).*/\1/p')
lcd=$(printf '%s' "$out" | sed -n 's/.*lcd=\([^ ]*\).*/\1/p')
state=$(printf '%s' "$out" | sed -n 's/.*state=\([^ ]*\).*/\1/p')

case "$state" in
dual)
	crt_mode=$(_desktop)
	[ -n "$crt_mode" ] || crt_mode=$(_pref "$crt")
	[ -n "$crt_mode" ] || crt_mode=$(_cur "$crt")
	lcd_mode=$(_pref "$lcd")
	[ -n "$lcd_mode" ] || lcd_mode=$(_cur "$lcd")
	[ -n "$crt_mode" ] && [ -n "$lcd_mode" ] || {
		echo "display-model: no mode offered for the CRT or the panel" >&2
		exit 1
	}
	printf 'SCREEN\t640x480\n'
	printf '%s\ton\t%s\tprimary\t0x0\t-\n' "$crt" "$crt_mode"
	printf '%s\ton\t%s\t-\t0x0\t640x480\n' "$lcd" "$lcd_mode"
	;;
crt)
	crt_mode=$(_desktop)
	[ -n "$crt_mode" ] || crt_mode=$(_pref "$crt")
	[ -n "$crt_mode" ] || crt_mode=$(_cur "$crt")
	[ -n "$crt_mode" ] || {
		echo "display-model: no mode offered for the CRT" >&2
		exit 1
	}
	sz=$(_size_of "$crt_mode")
	[ -n "$sz" ] || sz=640x480
	printf 'SCREEN\t%s\n' "$sz"
	printf '%s\ton\t%s\tprimary\t0x0\t-\n' "$crt" "$crt_mode"
	;;
lcd)
	lcd_mode=$(_pref "$lcd")
	[ -n "$lcd_mode" ] || lcd_mode=$(_cur "$lcd")
	[ -n "$lcd_mode" ] || {
		echo "display-model: no mode offered for the panel" >&2
		exit 1
	}
	sz=$(_size_of "$lcd_mode")
	printf 'SCREEN\t%s\n' "$sz"
	printf '%s\ton\t%s\tprimary\t0x0\t-\n' "$lcd" "$lcd_mode"
	;;
none)
	printf 'SCREEN\tnone\n'
	;;
*)
	echo "display-model: unknown topology state '$state'" >&2
	exit 1
	;;
esac
