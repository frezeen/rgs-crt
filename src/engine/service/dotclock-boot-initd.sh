#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
# Copyright (C) 2026 FreZeeN
# Part of crt-dual — https://github.com/frezeen
# S30z-crt-dual-measure — the dotclock measurement slot (crt-dual).
#
# WHERE: between the stock splash (S30splashscreencontrol, blocking ~9s)
# and X/ES (S31emulationstation) — the ONE boot window where the display
# is free: the splash has released the DRM master, X is not up yet, the
# stock resolution logic (Checker/Standalone) has not run, no emulator
# exists. Verified timeline 2026-09-20: S30 done -> this hook -> S31.
# The retired gameStart probe existed precisely because no such window
# was found; this slot IS the window.
#
# WHAT: dotclock-measure.py (KMS-native: takes the DRM master, sets each
# candidate mode, WAIT_VBLANK = the behavioural oracle, restores the
# pre-measurement state), then the service writes the floor into BOTH
# switchres inis (RA config-dir override + /etc/switchres.ini) FRESH at
# every boot — volatile, no overlay save, never a stale value.
#
# BOUNDED and LOUD: any failure logs and writes floor 0 (the stock
# default) — a hung measurement can never hang the boot (timeout belt),
# and a failed measurement can never leave a stale floor behind.
set -u
# The init runner (rcS) forks scripts with a minimal environment: make the
# tool paths independent of whatever PATH init hands us.
PATH="${PATH:-/usr/bin:/bin:/usr/sbin:/sbin}"
export PATH
LOG_DIR="${RGS15_LOGS_DIR:-/userdata/system/logs}"
LOG="$LOG_DIR/dotclock-measure.log"
PKG="${RGS15_PKG:-/userdata/system/crt-dual}"
SVC="${RGS15_SVC:-/userdata/system/services/zz_rgs_15khz}"
MEASURE="${RGS15_MEASURE:-$PKG/src/service/dotclock-measure.py}"

log() { echo "DOTCLOCK-BOOT [$(date '+%F %T')]: $*" >>"$LOG" 2>/dev/null || true; }

mkdir -p "$LOG_DIR" 2>/dev/null || true
# This hook owns its log: truncate at START so it always shows THIS boot's
# walk. (The service's TRUNCATE_LIST must NOT list it — the service starts
# at S99, AFTER this hook, and would erase the boot's evidence.)
: >"$LOG" 2>/dev/null || true
log "hook entered (pre-X window)"

# Manual knob (a number or "off") = the user owns the floor: skip the
# measurement entirely (fast boot; the service writer applies the knob).
_conf="${RGS15_CONF:-/userdata/system/batocera.conf}"
_knob="$(grep -E '^rgs-15khz\.dotclock_min[[:space:]]*=' "$_conf" 2>/dev/null | tail -1 | cut -d= -f2- | tr -d '[:space:]"\r')"
if [ -n "$_knob" ]; then
	log "manual knob rgs-15khz.dotclock_min=$_knob — measurement skipped (the knob owns the floor)"
	RGS15_LOG="$LOG" bash "$SVC" dotclock-write "" >>"$LOG" 2>&1 || log "WARN: dotclock-write returned non-zero"
	exit 0
fi

if [ ! -f "$MEASURE" ]; then
	log "measure tool missing ($MEASURE) — floor written as stock 0"
	RGS15_LOG="$LOG" bash "$SVC" dotclock-write "" >>"$LOG" 2>&1 || log "WARN: dotclock-write returned non-zero"
	exit 0
fi

log "measuring the chain (pre-X window, bounded)"
FLOOR=""
_rc=0
# The belt must cover ONE failing rung: the kernel pays 4x10 s flip_done
# waits on the CRTC the failing set left behind (measured 2026-09-20).
if command -v timeout >/dev/null 2>&1; then
	FLOOR="$(timeout "${RGS15_MEASURE_TIMEOUT:-120}" python3 "$MEASURE" 2>>"$LOG")" || _rc=$?
else
	FLOOR="$(python3 "$MEASURE" 2>>"$LOG")" || _rc=$?
fi
log "measure rc=$_rc floor='${FLOOR:-<none>}'"
[ "$_rc" -eq 0 ] || FLOOR=""
RGS15_LOG="$LOG" bash "$SVC" dotclock-write "${FLOOR:-}" >>"$LOG" 2>&1 || log "WARN: dotclock-write returned non-zero"
exit 0
