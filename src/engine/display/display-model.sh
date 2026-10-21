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

# La FASE e' un ingresso del modello come la topologia: desktop (il riposo)
# o session:<target> (il display consegnato al gioco). Prima la fase SESSION
# viveva solo nelle richieste scritte a mano dal riconciliatore, quindi non
# era ne' dichiarata ne' testabile.
phase="desktop"
case "${1:-}" in
--session)
	phase="session"
	session_target="${2:-}"
	case "$session_target" in
	crt | lcd) ;;
	*) echo "display-model: --session needs crt|lcd" >&2; exit 2 ;;
	esac
	;;
"") ;;
*)
	echo "display-model: unknown argument '$1' (only --session <crt|lcd>)" >&2
	exit 2
	;;
esac

_x() { timeout 5 env DISPLAY="${DISPLAY:-:0}" xrandr --current 2>/dev/null; }
_modes() { _x | sed -n "/^$1 connected/,/^[^ ]/p" | awk 'NF >= 2 && $1 ~ /^[0-9]/ { print }'; }
_pref() { _modes "$1" | awk '$0 ~ /\+/ { print $1; exit }'; }
_cur() { _modes "$1" | awk '$0 ~ /\*/ { print $1; exit }'; }
_prefer_progressive() { # $1 output, $2 mode -> progressive mode if available, else original mode
	local out="$1" m="$2"
	if [[ "$m" =~ ^(.*)i$ ]]; then
		local prog="${BASH_REMATCH[1]}"
		if _modes "$out" | awk -v m="$prog" '$1 == m { exit 0 } END { exit 1 }'; then
			printf '%s\n' "$prog"
			return 0
		fi
	fi
	printf '%s\n' "$m"
}
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
	lcd_mode=$(_prefer_progressive "$lcd" "$lcd_mode")
	[ -n "$crt_mode" ] && [ -n "$lcd_mode" ] || {
		echo "display-model: no mode offered for the CRT or the panel" >&2
		exit 1
	}
	if [ "$phase" = "desktop" ]; then
		printf 'SCREEN\t640x480\n'
		printf '%s\ton\t%s\tprimary\t0x0\t-\n' "$crt" "$crt_mode"
		printf '%s\ton\t%s\t-\t0x0\t640x480\n' "$lcd" "$lcd_mode"
	else
		# Il display lo prende il gioco: il bersaglio on+primary e NON
		# scalato (un residuo di scale manda il gioco in un framebuffer
		# piccolo), l'altro libero. Il modo del bersaglio qui e' solo la
		# partenza: il raster del gioco lo mette lo stock (misurato).
		if [ "$session_target" = "crt" ]; then
			sz=$(_size_of "$crt_mode")
			[ -n "$sz" ] || sz=none
			printf 'SCREEN\t%s\n' "$sz"
			printf '%s\ton\t%s\tprimary\t0x0\t-\n' "$crt" "$crt_mode"
			printf '%s\toff\t-\t-\t-\t-\n' "$lcd"
		else
			sz=$(_size_of "$lcd_mode")
			[ -n "$sz" ] || sz=none
			printf 'SCREEN\t%s\n' "$sz"
			printf '%s\ton\t%s\tprimary\t0x0\t-\n' "$lcd" "$lcd_mode"
			printf '%s\toff\t-\t-\t-\t-\n' "$crt"
		fi
	fi
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
	lcd_mode=$(_prefer_progressive "$lcd" "$lcd_mode")
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
