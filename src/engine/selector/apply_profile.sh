#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
# Copyright (C) 2026 FreZeeN
# Part of crt-dual — https://github.com/frezeen
# apply_profile.sh — CRT-DUAL profile engine: apply a profile at gameStart.
#
# gameStart hook (synchronous, runs BEFORE configgen — verified
# emulatorlauncher.py:165-166): pre-clean stale blocks → inject marked
# blocks → turn the non-target display OFF → verify → configgen carries
# the keys to the emulator.
#
# The heavy lifting (spec parse, block injection, configs provision,
# binary swap) is in merge.py (bash glue + python merge).
# This wrapper owns the DISPLAY switch (via the display layer's public
# function, NEVER raw xrandr — ) and the crash level-1
# pre-clean orchestration.
#
# Usage: apply_profile.sh <profile-name>
# Exit:  0 = applied, 1 = spec/fatal error, 2 = applied + rolled back
#
# Env (test seams, dry-run harness):
# CRT_DUAL_PKG_ROOT   package root (default /userdata/system/crt-dual)
# CRT_DUAL_TARGET_ROOT  where config files live (default /userdata/system)
# CRT_DUAL_BACKUP_ROOT  persistent stock backups (default $PKG_ROOT/backups)

set -uo pipefail

PKG_ROOT="${CRT_DUAL_PKG_ROOT:-/userdata/system/crt-dual}"
TARGET_ROOT="${CRT_DUAL_TARGET_ROOT:-/userdata/system}"
BACKUP_ROOT="${CRT_DUAL_BACKUP_ROOT:-$PKG_ROOT/backups}"
PROFILES_ROOT="$PKG_ROOT/profiles"
MERGE="$PKG_ROOT/src/selector/merge.py"
LIB="$PKG_ROOT/src/lib/display-lib.sh"

[ $# -ge 1 ] || {
	echo "usage: apply_profile.sh <profile-name>" >&2
	exit 1
}
NAME="$1"
SYSTEM="${2:-}" # system being launched ({mame} block filter; empty = legacy full apply)
PROFILE_DIR="$PROFILES_ROOT/$NAME"

[ -d "$PROFILE_DIR" ] || {
	echo "CRT-DUAL-APPLY: profile '$NAME' not found in $PROFILES_ROOT" >&2
	exit 1
}
[ -f "$MERGE" ] || {
	echo "CRT-DUAL-APPLY: merge engine missing: $MERGE" >&2
	exit 1
}

# Display layer: BOTH libs — gpu-lib (detect_gpu -> GPU_VENDOR/
# GPU_DOTCLOCK) is the display-lib prerequisite; without it the --prop
# fallback gate opened (2026-08-12: 3 G per gameStart).
[ -r "$LIB" ] && source "$LIB" 2>/dev/null
[ -r "$PKG_ROOT/src/lib/gpu-lib.sh" ] && source "$PKG_ROOT/src/lib/gpu-lib.sh" 2>/dev/null
command -v detect_gpu >/dev/null 2>&1 && detect_gpu 2>/dev/null

log() { echo "CRT-DUAL-APPLY [$(date +%H:%M:%S.%3N)]: $*" >&2; }

# ── 1. Crash level 1: pre-clean stale blocks / half-applied state ──
# merge.py apply does the pre-clean itself (idempotent, no-op when clean).
log "applying profile '$NAME'"

# ── 2. Merge (blocks + configs + binaries), with rollback on failure ──
if ! python3 "$MERGE" apply "$PROFILE_DIR" "$NAME" "$TARGET_ROOT" "$BACKUP_ROOT" "$SYSTEM"; then
	log "FAILED to apply '$NAME' — rolling back"
	python3 "$MERGE" remove "$PROFILE_DIR" "$NAME" "$TARGET_ROOT" "$BACKUP_ROOT" >/dev/null 2>&1 || true # best-effort rollback; absence is the clean state
	exit 2
fi

# ── 3. Display switch — v2 thin sender over the SR-OWNER want-file (ADR 001) ──
# Target display from spec, then delegate to SR-OWNER via want-file + flock.
# The owner owns the display (two-step, primary, positions); this client is
# ~10 lines, no direct xrandr, no fallback branch (zero debt).
TARGET_DISPLAY="$(
	python3 - "$PROFILE_DIR" "$PKG_ROOT" <<'PYEOF' 2>/dev/null || echo crt
import sys
from pathlib import Path
sys.path.insert(0, sys.argv[2] + "/src/selector")
try:
    import merge
    label, desc, dt, *_ = merge.parse_spec(Path(sys.argv[1]))
    print(dt)
except Exception:
    print("crt")
PYEOF
)"
TARGET_DISPLAY="${TARGET_DISPLAY:-crt}"
WANT_FILE="${CRT_DUAL_STATE_DIR:-/tmp/crt-dual}/want"
WANT_LOCK="$WANT_FILE.lock"
mkdir -p "$(dirname "$WANT_FILE")" 2>/dev/null || true
printf '%s\n' "$TARGET_DISPLAY" >"$WANT_FILE" 2>/dev/null || true
# Clear stale guard from previous cycle before sr-owner — otherwise sr-owner yields (no HDMI off) and game stays dual 480i not native (seen 15:46:39 guard active)
rm -f /tmp/crt-dual-mode "$CRT_DUAL_STATE_DIR/profile" 2>/dev/null || true
if command -v flock >/dev/null 2>&1; then flock -n "$WANT_LOCK" bash "$PKG_ROOT/src/owner/sr-owner.sh" --apply 2>/dev/null || bash "$PKG_ROOT/src/owner/sr-owner.sh" --apply 2>/dev/null || log "WARN: sr-owner apply failed"; else bash "$PKG_ROOT/src/owner/sr-owner.sh" --apply 2>/dev/null || log "WARN: sr-owner apply failed"; fi
# ── 4. RGS-15KHZ-EXT (per-game SwitchRes mode — DEFERRED to launch, EXT-13):
# the profile-declared WxH@R wish lives in /tmp/crt-dual/display (written by
# merge at gameStart). The PHYSICAL switch moved to the videoMode patcher in
# sitecustomize (EXT-13 unit there): applying it here let stock configgen's
# changeMode(global.videomode) stomp back to the desktop mode before spawn
# (measured daytona/sm2 2026-09-09: apply 55.529 -> stomp 55.837), and
# switchres-free emulators inherited the trampled mode. The launcher applies
# exactly once, AFTER the last stock mode write, BEFORE the gameResolution
# read. Here: nothing to do — the marker is the contract.
touch /tmp/crt-dual-mode
log "game-active guard written (/tmp/crt-dual-mode)"
log "profile '$NAME' applied (display=$TARGET_DISPLAY, via sr-owner)"
exit 0
