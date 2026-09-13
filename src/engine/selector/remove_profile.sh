#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
# Copyright (C) 2026 FreZeeN
# Part of crt-dual — https://github.com/frezeen
# remove_profile.sh — CRT-DUAL profile engine: remove a profile at gameStop.
#
# gameStop: remove marked blocks (idempotent, exit 0 when
# nothing active) → restore provided configs + swapped binaries → restore
# the display state (the display the profile targeted stays on — desktop
# returns to it ).
#
# Heavy lifting in merge.py (bash glue + python merge ).
#
# Usage: remove_profile.sh <profile-name>
# Exit:  0 = clean (block removed or nothing active), 1 = fatal error
#
# Env (test seams): CRT_DUAL_PKG_ROOT / CRT_DUAL_TARGET_ROOT /
# CRT_DUAL_BACKUP_ROOT — same as apply_profile.sh.

set -uo pipefail

PKG_ROOT="${CRT_DUAL_PKG_ROOT:-/userdata/system/crt-dual}"
TARGET_ROOT="${CRT_DUAL_TARGET_ROOT:-/userdata/system}"
BACKUP_ROOT="${CRT_DUAL_BACKUP_ROOT:-$PKG_ROOT/backups}"
PROFILES_ROOT="$PKG_ROOT/profiles"
MERGE="$PKG_ROOT/src/selector/merge.py"
LIB="$PKG_ROOT/src/lib/display-lib.sh"

[ $# -ge 1 ] || {
	echo "usage: remove_profile.sh <profile-name>" >&2
	exit 1
}
NAME="$1"
SYSTEM="${2:-}" # system that was launched (active-block filter for the
# batocera restore/removal — merge.py remove mirrors the apply filter; a
# key of a block never applied to this game is never touched)
PROFILE_DIR="$PROFILES_ROOT/$NAME"

[ -d "$PROFILE_DIR" ] || {
	echo "CRT-DUAL-REMOVE: profile '$NAME' not found — nothing to do" >&2
	exit 0
}
[ -f "$MERGE" ] || {
	echo "CRT-DUAL-REMOVE: merge engine missing: $MERGE" >&2
	exit 1
}

[ -r "$LIB" ] && source "$LIB" 2>/dev/null
# gpu-lib too: detect_gpu is the display-lib prerequisite (GPU_VENDOR/
# GPU_DOTCLOCK) — without it the --prop fallback gate opened (2026-08-12:
# 3 G per gameStart from selector/apply/remove).
[ -r "$PKG_ROOT/src/lib/gpu-lib.sh" ] && source "$PKG_ROOT/src/lib/gpu-lib.sh" 2>/dev/null
command -v detect_gpu >/dev/null 2>&1 && detect_gpu 2>/dev/null

log() { echo "CRT-DUAL-REMOVE [$(date +%H:%M:%S.%3N)]: $*" >&2; }

log "removing profile '$NAME'"

# ── 1. Merge remove (blocks + configs + binaries) — idempotent ──
if ! python3 "$MERGE" remove "$PROFILE_DIR" "$NAME" "$TARGET_ROOT" "$BACKUP_ROOT" "$SYSTEM"; then
	log "FAILED to remove '$NAME'"
	exit 1
fi

# ── 2. Restore desktop via SR-OWNER (thin sender over the want-file) ──
# Owner YIELDS during games; on gameStop it restores dual (want=dual).
# Thin sender: write want + flock → sr-owner (no direct xrandr, no fallback).
WANT_FILE="${CRT_DUAL_STATE_DIR:-/tmp/crt-dual}/want"
WANT_LOCK="$WANT_FILE.lock"
mkdir -p "$(dirname "$WANT_FILE")" 2>/dev/null || true
printf '%s\n' "dual" >"$WANT_FILE" 2>/dev/null || true
# Game guard must be cleared BEFORE sr-owner — otherwise owner sees
# /tmp/crt-dual/profile (still present via first_script) or /tmp/crt-dual-mode
# and yields (regression 2026-08-25 31-stop: want=dual but guard active → dual never restored, screen 1920x1080 extended not 640x480 clone).
rm -f /tmp/crt-dual-mode "${CRT_DUAL_STATE_DIR:-/tmp/crt-dual}/profile" /tmp/crt-dual/profile 2>/dev/null || true
# Topology is frozen while the game guard is up (watcher sleeps during a
# session) — passing --no-detect lets sr-owner reuse the last detect-state
# instead of re-classifying (~1.2s saved; measured 2026-08-28).
# RGS-15KHZ-EXT (single call, loud failure): ONE sr-owner attempt, no silent
# retry chain, no swallowed rc — the old "|| sr-owner again || true" doubled
# every gameStop restore (two identical want=dual passes, 2026-09-10 01:40,
# display-trace) and hid the not-converged rc the design leaves to the
# watcher, whose job is to RE-EMIT a failed request every poll. A busy lock
# (rc from flock, sr-owner never ran) is the same watcher-covered case.
_rc=0
if command -v flock >/dev/null 2>&1; then
	flock -n "$WANT_LOCK" bash "$PKG_ROOT/src/owner/sr-owner.sh" --apply --no-detect 2>/dev/null || _rc=$?
else
	bash "$PKG_ROOT/src/owner/sr-owner.sh" --apply --no-detect 2>/dev/null || _rc=$?
fi
[ "$_rc" -eq 0 ] || log "sr-owner dual restore rc=$_rc — layout not converged here; the watcher re-emits want=dual"
log "profile '$NAME' removed (via sr-owner dual restore)"
exit 0
