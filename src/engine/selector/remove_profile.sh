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
# Usage: remove_profile.sh <profile-name> [<system>]
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
	echo "usage: remove_profile.sh <profile-name> [<system>]" >&2
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

log() { echo "CRT-DUAL-REMOVE [$(date +%H:%M:%S.%3N)]: $*" >&2; }

log "removing profile '$NAME'"

# ── 1. Merge remove (blocks + configs + binaries) — idempotent ──
if ! python3 "$MERGE" remove "$PROFILE_DIR" "$NAME" "$TARGET_ROOT" "$BACKUP_ROOT" "$SYSTEM"; then
	log "FAILED to remove '$NAME'"
	exit 1
fi

# ── 2. GameStop restore — the WATCHER owns it (owner order 2026-09-13) ──
# RGS-15KHZ-EXT (reconciler-owned restore, ADR-002): this hook NEVER applies.
# Stock already restored the launch display (the patched launcher's
# interlaced fallback for the tube — measured live megadrive 2026-09-13:
# `setMode: interlaced fallback 640x480 -> 640x480i` landed before any
# engine step); the watcher's game-ended emitter then re-applies the dual
# within one poll (POLL_SEC=2) when the topology is dual. Per-launch
# engine work here = the keys above + the guard clear only, in ANY
# topology. The wake bell below (and the reconciler's game-ended emitter) is
# the guard branch) is what makes this correct: pre-fix it was dead
# (_game_ended could never fire) and the hook carried a redundant direct
# converge that ran double with the watcher's own.
# Guard clear MUST stay here (the crash-clean contract + the watcher's
# yield release — the game-ended emitter needs the guard GONE to fire).
# Inline read by design: the hooks tolerate the package libs being absent
# (remove_profile is exercised that way by seam test_remove_single_call).
_lcd_out="$(sed -n 's/^LCD_OUT=//p' "${CRT_DUAL_STATE_DIR:-/tmp/crt-dual}/detect-state" 2>/dev/null | head -1)"
_crt_out="$(sed -n 's/^CRT_OUT=//p' "${CRT_DUAL_STATE_DIR:-/tmp/crt-dual}/detect-state" 2>/dev/null | head -1)"
rm -f /tmp/crt-dual-mode "${CRT_DUAL_STATE_DIR:-/tmp/crt-dual}/profile" /tmp/crt-dual/profile "${CRT_DUAL_NOHOTPLUG_FILE:-/tmp/no-hotplug}" 2>/dev/null || true
# Wake the single applier (2026-09-19): a session shorter than the 2 s
# watcher poll leaves `game-ended` unseen, and the solo-prep's `enabled`
# change is invisible to the status-only sysfs fingerprint — the restore
# would never fire (dry chains: the post-hook settle never converged).
# The poke is the same wake bell udev uses; the watcher consumes it as a
# pure bell (converge only, never a forced re-probe).
: >"${CRT_DUAL_STATE_DIR:-/tmp/crt-dual}/udev-poke" 2>/dev/null || true
if [ -z "$_lcd_out" ] || [ -z "$_crt_out" ]; then
	log "stand-down: single-display topology — the patched launcher restored the desktop (boot + hotplug keep the engine)"
else
	log "dual topology — the watcher re-applies the dual layout (guard clear + poke)"
fi
log "profile '$NAME' removed (keys + guard cleared; restore = watcher)"
exit 0
