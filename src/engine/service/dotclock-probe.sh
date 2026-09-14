#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
# Copyright (C) 2026 FreZeeN
# Part of crt-dual — https://github.com/frezeen
# dotclock-probe.sh — measure the REAL dotclock limit of the video chain
# (GPU + encoder + convertitor) and persist it as
# `rgs-15khz.dotclock_min` in batocera.conf (the knob the zz service's
# dotclock-decide duty consumes). Rewritten for this engine from the old
# box seed (reference/migrate, same method, new plumbing).
#
# Method (never try-and-fail at runtime — the probe IS the one-time
# measurement):
#   1. The CRT path from the display layer's own classification.
#   2. The DESKTOP mode (working by definition) is the safe anchor — the
#      probe never starts from an unverified mode.
#   3. Step DOWN through representative native modes at decreasing
#      dotclocks (low geometries -> 15kHz always, NEVER 31kHz).
#   4. Each candidate: generate the modeline through the stock
#      switchres CLI (the same engine the runtime uses), xrandr
#      newmode/addmode/mode, then VERIFY THE EFFECTIVE mode via
#      `xrandr --query` — the xrandr return code lies (kernel refuses,
#      xrandr returns 0; old-box measured).
#   5. The lowest mode that actually lights = the chain limit.
#   6. Persist + ALWAYS restore the desktop (the CRT is never left on a
#      test mode).
#
# Runs at boot from the zz service ONLY when rgs-15khz.dotclock_min is
# ABSENT (first measurement). Manual value or `off` in batocera.conf =
# the probe skips. Re-run by hand: bash dotclock-probe.sh (never during
# a game — it changes modes on the CRT).
set -u

PKG="${CRT_DUAL_PKG_ROOT:-/userdata/system/crt-dual}"
CONF="${RGS15_CONF:-/userdata/system/batocera.conf}"
export DISPLAY="${DISPLAY:-:0}"

log() { echo "DOTCLOCK-PROBE [$(date +%FT%T)]: $*"; }

# Already measured / manual / off -> skip (the boot duty gates this too;
# the check lives here so a manual run is equally safe).
if grep -qE '^rgs-15khz\.dotclock_min[[:space:]]*=' "$CONF" 2>/dev/null; then
	log "rgs-15khz.dotclock_min already in batocera.conf — skip"
	exit 0
fi

# Display layer (classification + restore primitives).
for _lib in "$PKG/src/lib/gpu-lib.sh" "$PKG/src/lib/display-lib.sh"; do
	# shellcheck disable=SC1090  # dynamic package path
	[ -r "$_lib" ] && source "$_lib" 2>/dev/null
done
command -v detect_outputs >/dev/null 2>&1 && detect_outputs 2>/dev/null || true
crt="$(sed -n 's/^CRT_OUT=//p' "${CRT_DUAL_STATE_DIR:-/tmp/crt-dual}/detect-state" 2>/dev/null | head -1)"
[ -z "$crt" ] && crt="${CRT_OUT:-$CRT_PRESUMED_OUT}"
if [ -z "$crt" ]; then
	log "no CRT classified — skip (safe 25.0 default stays, nothing persisted)"
	exit 0
fi

SR_BIN="$(command -v switchres || echo /usr/bin/switchres)"
SR_INI="/etc/switchres.ini"

# Test set: name:W:H:R — native geometries of the main systems, dotclock
# DESCENDING. 320x240@60 first: it is the widest safe anchor above the
# sub-320 geometries (the VNC-padding class this control exists for).
TESTS="320x240:320:240:60 256x240:256:240:60 256x224:256:224:60 224x224:224:224:60"

modeline_dotclock() { # first field after the quoted label
	printf '%s\n' "$1" | cut -d'"' -f3- | awk '{print $1}'
}

best_dc=""
best_name=""
for t in $TESTS; do
	name="RGS15P_${t%%:*}"
	rest="${t#*:}"
	W="${rest%%:*}"; rest="${rest#*:}"
	H="${rest%%:*}"; rest="${rest#*:}"
	R="${rest%%:*}"
	R="${R%%:*}"
	modeline="$("$SR_BIN" "$W" "$H" "$R" -c -i "$SR_INI" 2>/dev/null | grep "Modeline" | head -1 | sed 's/^Switchres: //')"
	if [ -z "$modeline" ]; then
		log "$W x $H @ $R: switchres produced no modeline — skip"
		continue
	fi
	timings="$(printf '%s\n' "$modeline" | cut -d'"' -f3-)"
	dc="$(modeline_dotclock "$modeline")"

	xrandr --output "$crt" --newmode "$name" $timings 2>/dev/null || true # an existing name fails the newmode; addmode re-uses it
	xrandr --output "$crt" --addmode "$crt" "$name" 2>/dev/null || true
	xrandr --output "$crt" --mode "$name" 2>/dev/null || true
	cur="$(xrandr --query 2>/dev/null | sed -n "/^$crt connected/,/^[^ ]/p" | grep '\*' | awk '{print $1}' | head -1)"
	if [ "$cur" = "$name" ]; then
		log "$W x $H @ $R — dotclock ${dc}MHz — ACTIVE"
		if [ -z "$best_dc" ] || awk "BEGIN{exit !($dc < $best_dc)}"; then
			best_dc="$dc"
			best_name="${W}x${H}@${R}"
		fi
	else
		log "$W x $H @ $R — dotclock ${dc}MHz — refused (effective mode: ${cur:-none})"
	fi
done

# ALWAYS restore the desktop (never leave the CRT on a test mode) — the
# engine v2 applier is SR-OWNER (want-file; apply_dual_layout/
# _crt_set_15khz_direct were REMOVED from display-lib in the v2 move,
# see lib header "v2 PURE"). The want file already says dual (boot
# topology); sr-owner applies it and re-verifies. The test modes are
# removed from the pool best-effort.
for t in $TESTS; do
	xrandr --output "$crt" --delmode "$crt" "RGS15P_${t%%:*}" 2>/dev/null || true
done
if [ -x "$PKG/src/owner/sr-owner.sh" ]; then
	bash "$PKG/src/owner/sr-owner.sh" >/dev/null 2>&1 || true # want=dual — the watcher's own applier
elif command -v _crt_set_15khz_direct >/dev/null 2>&1; then
	_crt_set_15khz_direct "$crt" >/dev/null 2>&1 || true # pre-v2 engine fallback
fi
xrandr --output "$crt" --rmmode "$name" 2>/dev/null || true # last test mode, best-effort cleanup

if [ -z "$best_dc" ]; then
	log "no test mode lit — chain limit below the lowest tested; safe 25.0 stays (nothing persisted — re-run or set rgs-15khz.dotclock_min by hand)"
	exit 1
fi

value="$(awk "BEGIN{printf \"%.1f\", $best_dc}")"
log "CHAIN LIMIT = ${value}MHz (mode $best_name) -> persisting rgs-15khz.dotclock_min=$value"
if command -v batocera-settings-set >/dev/null 2>&1; then
	batocera-settings-set rgs-15khz.dotclock_min "$value" >/dev/null 2>&1 || true
fi
# settings-set relocates appended keys (stock APPENDS); enforce position
# + idempotence: rewrite the key at file end is fine, but ensure exactly
# one line and the value we measured.
if grep -qE '^rgs-15khz\.dotclock_min[[:space:]]*=' "$CONF" 2>/dev/null; then
	sed -i '/^rgs-15khz\.dotclock_min[[:space:]]*=/d' "$CONF" 2>/dev/null || true
fi
printf 'rgs-15khz.dotclock_min=%s\n' "$value" >>"$CONF" 2>/dev/null \
	|| log "WARN: could not persist to $CONF — decide falls back to GPU class"
log "persisted. Games with native dotclock >= ${value}MHz run NATIVE pure; below -> SwitchRes dynamic super width (never black)."
exit 0
