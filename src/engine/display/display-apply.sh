#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
# Copyright (C) 2026 FreZeeN
# Part of crt-dual — https://github.com/frezeen
# display-apply.sh — transition (ADR-002): compare reality with the plan;
# if different, ONE xrandr invocation, then verify the kernel truth.
# Mismatch after the batch = one bounded repair (off->on per output), one
# re-verify, then LOUD failure. No retry ladder, no alternate path.
#
# Usage:
#   display-apply.sh            plan + verdict (NO writes; default = dry)
#   display-apply.sh --apply    do the writes (batch + verify + repair)
#   display-apply.sh --plan     print the plan only
set -uo pipefail
export DISPLAY="${DISPLAY:-:0}" # the daemon is setsid-detached: every xrandr call needs it explicitly
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SYSFS="${CRT_DUAL_SYSFS:-/sys/class/drm}"
# CRTC ownership truth (modetest; CRT_DUAL_MODETEST = test seam). Kernel
# `enabled` alone means "encoder attached" — see crtc-owner.sh.
[ -r "$HERE/crtc-owner.sh" ] && . "$HERE/crtc-owner.sh"

_x() { timeout 5 env DISPLAY="${DISPLAY:-:0}" xrandr --current 2>/dev/null; }
_cur_mode() { _x | sed -n "/^$1 connected/,/^[^ ]/p" | awk '$0 ~ /\*/ { print $1; exit }'; }
_cur_pos() { _x | awk -v o="$1" '$1 == o { for (i = 1; i <= NF; i++) if ($i ~ /^[0-9]+x[0-9]+\+[0-9]+\+[0-9]+$/) { split($i, p, "+"); print p[2] "x" p[3]; exit } }'; }
_cur_prim() { _x | awk -v o="$1" '$1 == o { print ($0 ~ / primary/) ? "primary" : "-"; exit }'; }
_screen() { _x | sed -n 's/^Screen 0:.*current \([0-9]* x [0-9]*\).*/\1/p' | tr -d ' '; }
_drm_of_x() { bash "$HERE/display-detect.sh" --list 2>/dev/null | awk -F'\t' -v x="$1" '$3 == x { print $1; exit }'; }
_enabled() { local d; d=$(_drm_of_x "$1"); [ -n "$d" ] && cat "$SYSFS/card0-$d/enabled" 2>/dev/null; }
_all_x() { _x | awk '$2 == "connected" { print $1 }'; }
_x_name_for_drm() { # $1 = DRM connector -> its X output name (exact, then slot-stripped)
	local drm="$1" x
	x=$(printf '%s' "$drm" | sed -E 's/-[A-Za-z]-/-/')
	if _x | awk -v a="$drm" '$1 == a { f = 1 } END { exit !f }'; then
		printf '%s\n' "$drm"
		return 0
	fi
	if _x | awk -v b="$x" '$1 == b { f = 1 } END { exit !f }'; then
		printf '%s\n' "$x"
		return 0
	fi
	return 1
}
_planned() { printf '%s\n' "$plan" | awk -F'\t' -v o="$1" '$1 == o { f = 1 } END { exit !f }'; }
XCONF="${CRT_DUAL_XCONF:-/etc/X11/xorg.conf.d/99-crt.conf}"
_modes() { _x | sed -n "/^$1 connected/,/^[^ ]/p" | awk 'NF >= 2 && $1 ~ /^[0-9]/ { print }'; }
_ensure_mode() { # $1 output, $2 mode — re-add the conf modeline when X lost it
	# dce_v6 mode-pool loss after an LCD excursion (root cause 2026-08-29,
	# seen again in the ADR-002 swap 2026-09-19): the generated conf IS the
	# source of truth; re-add its Modeline dynamically (no literal timing).
	local x="$1" m="$2" line params
	_modes "$x" | awk -v m="$m" '$1 == m { f = 1 } END { exit !f }' && return 0
	line=$(grep -m1 -E "^[[:space:]]*Modeline[[:space:]]+\"$m\"" "$XCONF" 2>/dev/null)
	[ -n "$line" ] || {
		echo "display-apply: mode '$m' missing on $x and no Modeline in $XCONF" >&2
		return 1
	}
	params=$(printf '%s\n' "$line" | sed -E 's/^[[:space:]]*Modeline[[:space:]]+"[^"]+"[[:space:]]+//')
	read -r -a _parr <<<"$params"
	xrandr --newmode "$m" "${_parr[@]}" 2>/dev/null || true # already known = fine
	xrandr --addmode "$x" "$m" 2>/dev/null || {
		echo "display-apply: --addmode '$m' on $x failed" >&2
		return 1
	}
	echo "display-apply: re-added mode '$m' on $x from $XCONF (mode-pool loss)"
	return 0
}
_unplanned_enabled() { # connectors whose CURRENT encoder HOLDS A CRTC, outside the plan
	# Kernel `enabled` only says an encoder is attached (drm_sysfs.c) —
	# the CRTC id comes from modetest (crtc-owner.sh). An encoder-only
	# attach has nothing RandR can free, so it is NOT a mismatch (the
	# 2026-09-22 tester report: DVI-D-1 enabled with no CRTC failed every
	# apply and the bounded repair blinked the tube). Unknown truth (tool
	# missing/broken) falls back to the old, louder behavior.
	local f drm x crtc
	for f in "$SYSFS"/card*-*/enabled; do
		[ -f "$f" ] || continue
		[ "$(cat "$f" 2>/dev/null)" = "enabled" ] || continue
		drm=$(basename "$(dirname "$f")")
		drm=${drm#card*-}
		crtc="?"
		command -v crtc_of >/dev/null 2>&1 && crtc=$(crtc_of "$drm")
		[ -z "$crtc" ] && continue # no CRTC: encoder-only attach, not a holder
		x=$(_x_name_for_drm "$drm" 2>/dev/null) || x=""
		if [ -n "$x" ]; then
			_planned "$x" || printf '%s\n' "$x"
		else
			printf '?%s\n' "$drm" # no X output: cannot free via RandR (see _ignored_holders for the conf-ignored class)
		fi
	done
}
_encoder_only_holders() { # enabled+disconnected with a KNOWN-empty CRTC: a note, never a mismatch
	local f drm crtc
	command -v crtc_of >/dev/null 2>&1 || return 0
	for f in "$SYSFS"/card*-*/enabled; do
		[ -f "$f" ] || continue
		[ "$(cat "$f" 2>/dev/null)" = "enabled" ] || continue
		drm=$(basename "$(dirname "$f")")
		drm=${drm#card*-}
		[ "$(cat "$(dirname "$f")/status" 2>/dev/null)" = "disconnected" ] || continue
		crtc=$(crtc_of "$drm")
		[ -z "$crtc" ] && printf '%s\n' "$drm"
	done
}
_ignored_by_conf() { # $1 = connector name — true when the generated conf ignores it
	local _id="$1" _f="$XCONF"
	[ -f "$_f" ] || return 1
	awk -v id="$_id" '
		/^[[:space:]]*Section[[:space:]]+"Monitor"/ { ins = 1; hit = 0; ign = 0; next }
		/^[[:space:]]*EndSection/ { if (ins && hit && ign) ok = 1; ins = 0; next }
		ins && /^[[:space:]]*Identifier/ { if (index($0, "\"" id "\"")) hit = 1; next }
		ins && hit && /[Oo]ption[[:space:]]+"[Ii]gnore"[[:space:]]+"true"/ { ign = 1 }
		END { exit !ok }
	' "$_f" 2>/dev/null
}
_ignored_holders() { # '?DRM' entries: conf-ignored AND disconnected AND no X name — unactionable by construction
	# (AMD boot 2026-09-21 after the Intel phase: DVI-D-1 disconnected with a
	# stale encoder binding and Option "ignore" in the conf; counted as a
	# mismatch it failed every apply → the bounded repair off->on'ed BOTH
	# outputs at every event, twice per boot, the 2nd cycle caused only by
	# this. The conf is regenerated pre-X from live truth, so the match
	# follows the topology; anything not exactly this stays LOUD.)
	# RESIDUAL (ADR-002, watch): if such a connector really holds a CRTC,
	# RandR still cannot free it and this stays a note; the CRTC truth is
	# visible per connector in diag-dump (crtc=...).
	local f drm y
	for f in "$SYSFS"/card*-*/enabled; do
		[ -f "$f" ] || continue
		[ "$(cat "$f" 2>/dev/null)" = "enabled" ] || continue
		drm=$(basename "$(dirname "$f")")
		drm=${drm#card*-}
		[ "$(cat "$(dirname "$f")/status" 2>/dev/null)" = "disconnected" ] || continue
		_x_name_for_drm "$drm" >/dev/null 2>&1 && continue # has an X handle: normal unplanned path frees it
		y=$(printf '%s' "$drm" | sed -E 's/-[A-Za-z]-/-/')
		if _ignored_by_conf "$drm" || _ignored_by_conf "$y"; then
			printf '?%s\n' "$drm"
		fi
	done
}
_actionable_unplanned() { # _unplanned_enabled minus the conf-ignored '?' class
	local _raw _ign _it _out=""
	_raw=$(_unplanned_enabled)
	[ -n "$_raw" ] || return 0
	_ign=$(_ignored_holders)
	for _it in $_raw; do
		case "$_it" in
		'?'*)
			case " $_ign " in *" $_it "*) continue ;; esac
			;;
		esac
		_out="$_out$_it"$'\n'
	done
	printf '%s' "$_out"
}
STATE_DIR="${CRT_DUAL_STATE_DIR:-/tmp/crt-dual}"
_write_desktop_state() { # single writer of the analog desktop name (the model reads it)
	local analog mode line rate
	analog=$(bash "$HERE/display-detect.sh" --list 2>/dev/null | awk -F'\t' '$2 == "analog" { print $3; exit }')
	[ -n "$analog" ] || return 0
	mode=$(_cur_mode "$analog")
	[ -n "$mode" ] || return 0
	line=$(_x | sed -n "/^$analog connected/,/^[^ ]/p" | awk -v m="$mode" '$1 == m { print; exit }')
	rate=$(printf '%s\n' "$line" | awk '{ for (i = 2; i <= NF; i++) if ($i ~ /\*/) { gsub(/[*+]/, "", $i); print $i; exit } }')
	printf '%s\n' "${mode}${rate:+ $rate}" >"$STATE_DIR/crt-desktop-mode" 2>/dev/null || true
}

plan=$(bash "$HERE/display-model.sh") || exit 1
[ "${1:-}" = "--plan" ] && { printf '%s\n' "$plan"; exit 0; }
mode="${1:-dry}"

# reality vs plan
mismatch=""
while IFS=$'\t' read -r name f1 f2 f3 f4 f5; do
	[ "$name" = "SCREEN" ] && continue
	cm=$(_cur_mode "$name")
	if [ "$f1" = "on" ]; then
		[ "$cm" = "$f2" ] || mismatch="$mismatch $name:mode($cm!=$f2)"
		[ "$(_cur_prim "$name")" = "${f3:-}" ] || mismatch="$mismatch $name:primary"
		[ "$(_cur_pos "$name")" = "${f4:-0x0}" ] || mismatch="$mismatch $name:pos"
		[ "$(_enabled "$name")" = "enabled" ] || mismatch="$mismatch $name:kernel"
	else
		[ -z "$cm" ] || mismatch="$mismatch $name:should-be-off"
		[ "$(_enabled "$name")" = "disabled" ] || mismatch="$mismatch $name:kernel-on"
	fi
done <<<"$plan"
want_screen=$(printf '%s\n' "$plan" | awk -F'\t' '$1 == "SCREEN" { print $2 }')
if [ "$want_screen" != "none" ]; then
	[ "$(_screen)" = "$want_screen" ] || mismatch="$mismatch screen($(_screen)!=$want_screen)"
fi
# a CRTC outside the plan is a mismatch even in the read-only verdict (the
# stale class: a gone output can keep one — the daemon's settle must see it).
# NOTES, never mismatches (kernel truth, crtc-owner.sh):
#  - a connector the generated conf deliberately IGNORES, disconnected,
#    with an encoder attached and no X output has no RandR handle
#    (2026-09-21 churn: the bounded repair off->on'ed BOTH outputs);
#  - a disconnected connector whose encoder holds NO CRTC is an attach
#    only — nothing RandR could free (2026-09-22 tester report: a phantom
#    `unplanned(DVI-D-1)` failed every apply on a CRT-only box).
# Everything else stays LOUD.
_ignored_conf=$(_ignored_holders)
_attach_only=$(_encoder_only_holders)
# the same connector can be in both classes (conf-ignored AND no CRTC):
# name it once, in the conf-ignored line
_attach_list=""
for _c in $_attach_only; do
	case " $_ignored_conf " in
	*" $_c "* | *"?$_c "*) continue ;;
	esac
	_attach_list="$_attach_list $_c"
done
_note=""
[ -n "$_ignored_conf" ] && _note="conf-ignored, not actionable:$(printf '%s' "$_ignored_conf" | tr '\n' ',')"
[ -n "$_attach_list" ] && _note="${_note:+$_note }encoder-only attach (no CRTC), not actionable:${_attach_list# }"
_unplanned=$(_actionable_unplanned)
[ -n "$_unplanned" ] && mismatch="$mismatch unplanned($(printf '%s' "$_unplanned" | tr '\n' ','))"

if [ -z "$mismatch" ]; then
	echo "display-apply: reality matches the plan (zero writes)"
	[ -n "$_note" ] && echo "display-apply: note: $_note"
	exit 0
fi

# build ONE batch: planned outputs + --off for every other output holding a
# CRTC (connected leftovers from _all_x AND stale disconnected ones from the
# kernel truth — the 2026-09-19 morning class)
cmd=(xrandr)
while IFS=$'\t' read -r name f1 f2 f3 f4 f5; do
	[ "$name" = "SCREEN" ] && continue
	if [ "$f1" = "on" ]; then
		cmd+=(--output "$name" --mode "$f2")
		[ "$f3" = "primary" ] && cmd+=(--primary)
		cmd+=(--pos "${f4:-0x0}")
		[ "$f5" != "-" ] && cmd+=(--scale-from "$f5")
	else
		cmd+=(--output "$name" --off)
	fi
done <<<"$plan"
_off_seen=""
for x in $(_all_x) $(_unplanned_enabled | grep -v '^?'); do
	[ -n "$x" ] || continue
	case " $_off_seen " in *" $x "*) continue ;; esac
	_planned "$x" && continue
	_off_seen="$_off_seen $x"
	cmd+=(--output "$x" --off)
done

if [ "$mode" != "--apply" ]; then
	echo "display-apply: MISMATCH$mismatch"
	[ -n "$_note" ] && echo "display-apply: note: $_note"
	printf 'display-apply: would run: %s\n' "${cmd[*]}"
	exit 1
fi

# ensure every planned mode exists on its output (conf modeline re-add on loss)
while IFS=$'\t' read -r name f1 f2 _f3 _f4 _f5; do
	[ "$name" = "SCREEN" ] && continue
	[ "$f1" = "on" ] || continue
	_ensure_mode "$name" "$f2" || exit 1
done <<<"$plan"

_err=$("${cmd[@]}" 2>&1) || {
	echo "display-apply: batch FAILED: $_err" >&2
	exit 1
}

# verify (kernel truth included); one bounded repair on mismatch
verify() {
	local bad="" cm un
	while IFS=$'\t' read -r name f1 f2 _f3 _f4 _f5; do
		[ "$name" = "SCREEN" ] && continue
		cm=$(_cur_mode "$name")
		if [ "$f1" = "on" ]; then
			[ -n "$cm" ] && [ "$(_enabled "$name")" = "enabled" ] || bad="$bad $name"
		else
			[ -z "$cm" ] && [ "$(_enabled "$name")" = "disabled" ] || bad="$bad $name"
		fi
	done <<<"$plan"
	if [ -n "$want_screen" ] && [ "$want_screen" != "none" ] && [ "$(_screen)" != "$want_screen" ]; then
		bad="$bad screen"
	fi
	un=$(_actionable_unplanned)
	if [ -n "$un" ]; then
		bad="$bad unplanned($(printf '%s' "$un" | tr '\n' ','))"
	fi
	[ -z "$bad" ]
}
if verify; then
	_write_desktop_state
	echo "display-apply: applied and verified"
	exit 0
fi
# repair: explicit off->on for the planned "on" outputs, then the batch again
for name in $(printf '%s\n' "$plan" | awk -F'\t' '$1 != "SCREEN" && $2 == "on" { print $1 }'); do
	xrandr --output "$name" --off 2>/dev/null || true
done
_err=$("${cmd[@]}" 2>&1) || {
	echo "display-apply: repair batch FAILED: $_err" >&2
	exit 1
}
if verify; then
	_write_desktop_state
	echo "display-apply: applied and verified (after one repair)"
	exit 0
fi
echo "display-apply: LOUD FAILURE — state does not match the plan after batch+repair$mismatch" >&2
exit 1
