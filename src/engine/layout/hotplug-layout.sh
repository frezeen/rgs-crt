#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
# Copyright (C) 2026 FreZeeN
# Part of crt-dual — https://github.com/frezeen
# hotplug-layout.sh — CRT-DUAL: MUTE hotplug poke (consolidate-watcher).
#
# The udev rule fires this on every drm change uevent. It does NOT detect,
# probe, or apply anything: a raced apply here would poison the layout
# fingerprint mid-uevent while X is still reconfiguring. By design there
# is exactly ONE applier: display-reconcile.sh.
#
# This script only drops its OWN marker (udev-poke); the watcher's main
# loop consumes it as a pure wake-up bell (idle-only: during a game it
# sits until gameStop, then converges — same deferral the old handler had).
#
# State files:
#   $CRT_DUAL_STATE_DIR/udev-poke   created HERE, consumed+deleted by
#                                   display-reconcile.sh (converge only — never
#                                   a forced probe; see the storm note below)

STATE_DIR="${CRT_DUAL_STATE_DIR:-/tmp/crt-dual}"
mkdir -p "$STATE_DIR" 2>/dev/null || true

# STOCK CHECKER SUPPRESSION (2026-09-19 the session clobber; 2026-10-18 the
# measured cost): the STOCK checker (udev 80-switch-screen, ENV{HOTPLUG}=="1")
# restarts ES ~2 s after the same event. Inside a session that clobbers a
# just-handed-over solo-prep and tears down the running game; IDLE it costs a
# WASTED APPLY: the checker's display loop rewrites the boot primary, so our
# batch is undone and a second apply is needed (measured 2026-10-18: an LCD
# plug cost 2 applies — the first cancelled at +2 s — plus an ES restart). The
# checker honours /tmp/no-hotplug as a ONE-SHOT skip (its own lines 91-96): set
# it for EVERY real hotplug (HOTPLUG=1 — the exact condition the stock rule
# matches; a synthetic trigger never carries it and must not leave a stale
# file). session-nohotplug.sh still keeps the skip fresh while a session owns
# the display (a checker run whose delay lands mid-launch); the poke below goes
# out either way, so the watch converges.
NOHOTPLUG_FILE="${CRT_DUAL_NOHOTPLUG_FILE:-/tmp/no-hotplug}"
if [ "${HOTPLUG:-0}" = "1" ]; then
	: >"$NOHOTPLUG_FILE" 2>/dev/null || true
	# Il checker lo CONSUMA a ogni suo giro (rm), e i giri possono essere piu'
	# d'uno per lo stesso gesto: l'helper lo tiene fresco per la finestra, cosi'
	# la soppressione non dipende da una corsa (misurato 2026-10-18: il conteggio
	# dei checker saliva lo stesso).
	# Lo skip NON basta: il checker lo CONSUMA (rm) e due giri dello stesso gesto
	# possono cadere nello stesso istante, cosi' il secondo lo trova gia' rimosso
	# e prosegue (misurato 2026-10-18: il conteggio dei checker saliva lo stesso).
	# Il lock di debounce dello stock invece si CHIEDE (non si consuma) ed e' la
	# riga che precede il quit: e' lui a rendere deterministica la soppressione.
	# Finestra nostra, rimossa da noi: mai stantia.
	_lock="${CRT_DUAL_SWITCH_LOCK:-/var/run/batocera-switch-screen.debounce.lock}"
	if [ -n "$_lock" ]; then
		: >"$_lock" 2>/dev/null || true
		( sleep "${CRT_DUAL_SWITCH_LOCK_SECS:-8}"; rm -f "$_lock" ) >/dev/null 2>&1 &
	fi
	_hold="${CRT_DUAL_NOHOTPLUG_HOLD_SECS:-6}"
	_here="$(cd "$(dirname "$0")" && pwd)"
	if [ "${_hold:-0}" -gt 0 ] 2>/dev/null && [ -f "$_here/session-nohotplug.sh" ]; then
		CRT_DUAL_NOHOTPLUG_HOLD="$_hold" setsid nohup bash "$_here/session-nohotplug.sh" >/dev/null 2>&1 &
	fi
fi
: >"$STATE_DIR/udev-poke" 2>/dev/null || true

exit 0
