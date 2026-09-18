#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
# Copyright (C) 2026 FreZeeN
# Part of crt-dual — https://github.com/frezeen
# dotclock-probe.sh — measure the REAL dotclock limit of the video chain
# (GPU + encoder + convertitor) and CACHE it for the game consumers.
#
# When it runs: from dotclock-ensure — the first CRT game launch
# (synchronous, before the emulator starts; owner architecture
# 2026-09-16). NEVER at boot: ES boots clean at 480i, /etc is untouched,
# no background work. LCD-only boxes: inert (CRT gate below).
#
# What it persists: the state cache $PKG/state/dotclock (value + GPU
# fingerprint) — NOT batocera.conf, NOT /etc/switchres.ini (read-only
# base + measurement math: floor 0 by invariant — the layer never writes
# it). The RA config-dir override is materialized from the state by the
# service's dotclock-decide (single writer), invoked here best-effort.
#
# Method (never try-and-fail at runtime — the probe IS the one-time
# measurement):
#   1. The CRT path from the display layer's own classification.
#   2. The DESKTOP mode (working by definition) is the safe anchor — the
#      probe never starts from an unverified mode.
#   3. Step UP from the lowest representative native mode (low
#      geometries -> 15kHz always, NEVER 31kHz): the chain limit is the
#      lowest mode that actually lights, so the first success ends the
#      walk — one mode change on a capable chain.
#   4. Each candidate: generate the modeline through the stock
#      switchres CLI (the same engine the runtime uses), xrandr
#      newmode/addmode/mode, then VERIFY THE EFFECTIVE mode via
#      `xrandr --current` — the xrandr return code lies (kernel refuses,
#      xrandr returns 0; old-box measured), and --current is the
#      glitch-free read (--query re-probes the DAC and blips the tube).
#   5. The lowest mode that actually lights = the chain limit.
#   6. Persist the cache + restore the desktop (the CRT is never left on
#      a test mode) — unless a game owns the display (see the guard).
#
# Game guard (manual runs; at gameStart the emulator starts AFTER this
# probe by construction): the walk changes modes on the CRT, so a running
# emulator defers the measurement, a launch mid-walk aborts it (nothing
# persisted), and the desktop restore is skipped while a game owns the
# display. The launcher itself is NOT part of the guard: at the first
# game launch this probe runs INSIDE the launcher's gameStart hook.
# Missing pgrep = no check.
#
# Re-run by hand: bash dotclock-probe.sh — skips when the cache already
# matches this hardware (delete $PKG/state/dotclock to re-measure; never
# during a game — it changes modes on the CRT).
set -u

PKG="${CRT_DUAL_PKG_ROOT:-/userdata/system/crt-dual}"
CONF="${RGS15_CONF:-/userdata/system/batocera.conf}"
XRANDR="${RGS15_XRANDR:-xrandr}"
PGREP="${RGS15_PGREP:-pgrep}"
export DISPLAY="${DISPLAY:-:0}"

log() { echo "DOTCLOCK-PROBE [$(date +%FT%T)]: $*"; }

dotclock_fpr() { # the video hardware identity (DRIVER:PCI_ID per card) —
	# same shape as the service's (the cache validity + swap detection).
	# The digit globs NEVER match connector dirs (card0-DP-1): a display
	# plug/unplug must not change the fingerprint.
	local _f="" _u _root="${RGS15_DRM_SYS:-/sys/class/drm}"
	for _u in "$_root"/card[0-9]/device/uevent "$_root"/card[0-9][0-9]/device/uevent; do
		[ -f "$_u" ] || continue
		_f="$_f|$(sed -n 's/^DRIVER=//p' "$_u" | head -1):$(sed -n 's/^PCI_ID=//p' "$_u" | head -1)"
	done
	printf '%s' "$_f"
}

game_running() { # a running EMULATOR defers/aborts the walk. The launcher
	# is deliberately NOT matched: at the first game launch this probe
	# runs inside the launcher's gameStart hook (before the emulator).
	command -v "$PGREP" >/dev/null 2>&1 || return 1
	"$PGREP" -f 'retroarch|mame|ppsspp' >/dev/null 2>&1
}

current_mode() { # the ACTIVE mode name of one output, from --current
	# (the cached RandR state — glitch-free, unlike --query)
	"$XRANDR" --current 2>/dev/null | awk -v out="$1" '
		$1 == out && $2 == "connected" { grab = 1; next }
		/^[A-Za-z]/ { grab = 0 }
		grab && /\*/ { print $1; exit }
	'
}

# Manual knob / off -> the user owns the floor: skip (the service's
# decide/ensure gate this too; the check lives here so a manual run is
# equally safe).
_knob="$(grep -E '^rgs-15khz\.dotclock_min[[:space:]]*=' "$CONF" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '[:space:]"')"
if [ -n "$_knob" ]; then
	log "rgs-15khz.dotclock_min set by hand ('$_knob') — skip (the knob owns the floor)"
	exit 0
fi

# Already measured for THIS hardware -> the cache answers (delete the
# state file to re-measure; a changed fingerprint invalidates it).
_state="${RGS15_STATE:-$PKG/state/dotclock}"
if [ -f "$_state" ] && [ "$(sed -n 's/^fpr=//p' "$_state" | head -1)" = "$(dotclock_fpr)" ]; then
	log "already measured for this hardware ($(sed -n 's/^value=//p' "$_state" | head -1)MHz cached) — skip (delete $_state to re-measure)"
	exit 0
fi

# Display layer (classification + restore primitives).
for _lib in "$PKG/src/lib/gpu-lib.sh" "$PKG/src/lib/display-lib.sh"; do
	# shellcheck disable=SC1090  # dynamic package path
	[ -r "$_lib" ] && source "$_lib" 2>/dev/null
done
command -v detect_outputs >/dev/null 2>&1 && detect_outputs 2>/dev/null || true
crt="$(sed -n 's/^CRT_OUT=//p' "${CRT_DUAL_STATE_DIR:-/tmp/crt-dual}/detect-state" 2>/dev/null | head -1)"
[ -z "$crt" ] && crt="${CRT_OUT:-${CRT_PRESUMED_OUT:-}}"
[ -z "$crt" ] && crt="${CRT_OUTS:-}"
if [ -z "$crt" ]; then
	log "no CRT classified — skip (LCD-only: the machinery is inert, nothing exists)"
	exit 0
fi

# Never cycle the tube while an emulator is up (manual runs): defer
# (nothing is persisted; the next CRT game launch retries).
if game_running; then
	log "an emulator is running — measurement deferred (the next CRT game launch retries)"
	exit 1
fi

SR_BIN="$(command -v switchres || echo /usr/bin/switchres)"
# Measurement math on the SHIPPED ini directly: /etc is stock (floor 0)
# by invariant — the layer never writes it (PR rule; the desktop and this
# probe both rely on it, and the decided floor lives only in the RA
# config-dir override). Seam: RGS15_SR_INI (tests).
SR_INI="${RGS15_SR_INI:-/etc/switchres.ini}"

# Test set: name:W:H:R — native geometries of the main systems, LOWEST
# dotclock FIRST: the chain limit is the lowest mode that lights, so the
# first success ends the walk (one mode change on a capable chain).
TESTS="224x224:224:224:60 256x224:256:224:60 256x240:256:240:60 320x240:320:240:60"

modeline_dotclock() { # first field after the quoted label
	printf '%s\n' "$1" | cut -d'"' -f3- | awk '{print $1}'
}

best_dc=""
best_name=""
_busy=""
for t in $TESTS; do
	name="RGS15P_${t%%:*}"
	rest="${t#*:}"
	W="${rest%%:*}"; rest="${rest#*:}"
	H="${rest%%:*}"; rest="${rest#*:}"
	R="${rest%%:*}"
	R="${R%%:*}"
	# A launch in the way aborts the walk (the desktop is restored below
	# only when no game owns the display; nothing is persisted).
	if game_running; then
		log "an emulator started — measurement abandoned"
		_busy=1
		break
	fi
	modeline="$("$SR_BIN" "$W" "$H" "$R" -c -i "$SR_INI" 2>/dev/null | grep "Modeline" | head -1 | sed 's/^Switchres: //')"
	if [ -z "$modeline" ]; then
		log "$W x $H @ $R: switchres produced no modeline — skip"
		continue
	fi
	timings="$(printf '%s\n' "$modeline" | cut -d'"' -f3-)"
	dc="$(modeline_dotclock "$modeline")"

	"$XRANDR" --output "$crt" --newmode "$name" $timings 2>/dev/null || true # an existing name fails the newmode; addmode re-uses it
	"$XRANDR" --output "$crt" --addmode "$crt" "$name" 2>/dev/null || true
	"$XRANDR" --output "$crt" --mode "$name" 2>/dev/null || true
	cur="$(current_mode "$crt")"
	if [ "$cur" = "$name" ]; then
		log "$W x $H @ $R — dotclock ${dc}MHz — ACTIVE (chain-limit candidate)"
		best_dc="$dc"
		best_name="${W}x${H}@${R}"
		break
	else
		log "$W x $H @ $R — dotclock ${dc}MHz — refused (effective mode: ${cur:-none})"
	fi
done

# Restore the desktop (never leave the CRT on a test mode) — the
# applier is SR-OWNER (want-file): the want file already says dual (boot
# topology); sr-owner applies it and re-verifies. A GAME that took over
# the display owns the mode: restoring here would fight it, so the
# restore is skipped in that case (the test modes are still dropped
# from the pool). The test modes are removed from the pool best-effort.
for t in $TESTS; do
	"$XRANDR" --output "$crt" --delmode "$crt" "RGS15P_${t%%:*}" 2>/dev/null || true
done
if game_running; then
	log "desktop restore skipped — a game owns the display"
elif [ -x "$PKG/src/owner/sr-owner.sh" ]; then
	bash "$PKG/src/owner/sr-owner.sh" >/dev/null 2>&1 || true # want=dual — the watcher's own applier
fi
"$XRANDR" --output "$crt" --rmmode "$name" 2>/dev/null || true # last test mode, best-effort cleanup

if [ -n "$_busy" ]; then
	log "measurement abandoned (nothing persisted; the next CRT game launch retries)"
	exit 1
fi

if [ -z "$best_dc" ]; then
	log "no test mode lit — chain limit below the lowest tested; nothing persisted (games run the library default = safe widen; set rgs-15khz.dotclock_min by hand to pin a floor)"
	exit 1
fi

value="$(awk "BEGIN{printf \"%.1f\", $best_dc}")"
mkdir -p "$(dirname "$_state")" 2>/dev/null || true
{
	printf 'value=%s\n' "$value"
	printf 'fpr=%s\n' "$(dotclock_fpr)"
} >"$_state" 2>/dev/null || log "WARN: could not persist the cache to $_state (the next CRT game launch re-measures)"
log "CHAIN LIMIT = ${value}MHz (mode $best_name) -> cached in $_state (this hardware)"
log "games with native dotclock >= ${value}MHz run NATIVE pure; below -> SwitchRes dynamic super width (never black)."
# Materialize the fresh measurement into the RA floor now (the service's
# dotclock-decide is the single writer; best-effort — the ensure caller
# re-decides anyway and the next boot re-heals).
_zz="${RGS15_SVC:-/userdata/system/services/zz_rgs_15khz}"
[ -x "$_zz" ] && bash "$_zz" dotclock-decide >/dev/null 2>&1 || true
exit 0
