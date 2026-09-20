#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
# Copyright (C) 2026 FreZeeN
# Part of crt-dual — https://github.com/frezeen
# apply_profile.sh — CRT-DUAL profile engine: apply a profile at gameStart.
#
# gameStart hook (synchronous; the sitecustomize RAM patch hoists it
# BEFORE configgen resolves the generator): pre-clean stale blocks → inject marked
# blocks → turn the non-target display OFF → verify → configgen carries
# the keys to the emulator.
#
# The heavy lifting (spec parse, block injection, configs provision,
# binary swap) is in merge.py (bash glue + python merge).
# This wrapper owns the DISPLAY switch (via the display layer's public
# function, NEVER raw xrandr — ) and the crash level-1
# pre-clean orchestration.
#
# Usage: apply_profile.sh <profile-name> [<system>]
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
	echo "usage: apply_profile.sh <profile-name> [<system>]" >&2
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

# ── 3. Display switch — thin sender over the SR-OWNER want-file (ADR 001) ──
# RGS-15KHZ-EXT (single-topology pass-through, 2026-09-13): the per-launch
# engine display work (the two-step primary/positions dance) is needed ONLY
# in dual topology, where the stock flow cannot choose the primary. In any
# single-display topology (CRT-only / LCD-only / none) the stock flow owns
# the launch end to end: the boot ES apply lands the desktop, the patched
# launcher's channel owns the game raster AND the gameStop restore (the
# interlaced fallback lives in the hunks). Measured live (megadrive,
# CRT-only 2026-09-13): the per-launch applies were no-op confirmations on
# states the readbacks proved already correct. Stand down for the launch
# cycle; the keys and the guard still run (steps 1-4). The BOOT apply (zz)
# and any hotplug re-entry keep the full engine — the gate reads
# detect-state each launch and follows the topology.
TARGET_DISPLAY="$(python3 "$PKG_ROOT/src/selector/spec-target.py" "$PROFILE_DIR" 2>/dev/null || echo crt)"
TARGET_DISPLAY="${TARGET_DISPLAY:-crt}"
# ── 3. Display hand-over (ADR-002, 2026-09-19) ──
# ONE verb: the reconciler preps the session target (dual: the non-target
# off, the target verified against the kernel with one bounded repair;
# single-display: nothing to prep — stock owns the flow). No fallback
# path: the reconciler is the only display owner.
if [ -r "$PKG_ROOT/src/display/display-reconcile.sh" ]; then
	bash "$PKG_ROOT/src/display/display-reconcile.sh" --session-start "$TARGET_DISPLAY" 2>&1 | sed 's/^/  /' \
		|| log "WARN: session-start failed (display not prep'd — game runs anyway)"
else
	log "FAIL: display-reconcile.sh missing — display not prep'd (game runs anyway)"
fi
# ── 4. RGS-15KHZ-EXT (stock raster channel): the profile declares
# per-game rasters as <system>.videomode keys (bare = preset-scaled into
# arcade_15, dotted = exact); the PATCHED stock launcher (the
# resolution-patch duty's hunks) announces + generates them natively and
# stock setMode applies the mode inside its own resolution block — no
# want file, no configgen patch, no stomp (the key IS the stock value).
# Here: nothing to do — the marker is the contract.
touch /tmp/crt-dual-mode
log "game-active guard written (/tmp/crt-dual-mode)"
# Session suppression (2026-09-19 evening): hold the stock checker's
# one-shot skip while this session owns the display — a hotplug whose
# checker run lands mid-launch would clobber the solo-prep (target
# blanked, rig evidence logs/rig-chain-boot-crt-20260919-040*.txt) or
# tear down the running game. Self-terminating when the guard clears;
# best-effort (never blocks the launch).
if [ -r "$PKG_ROOT/src/layout/session-nohotplug.sh" ]; then
	setsid bash "$PKG_ROOT/src/layout/session-nohotplug.sh" >/dev/null 2>&1 &
	disown 2>/dev/null || true
fi
log "profile '$NAME' applied (display=$TARGET_DISPLAY)"
exit 0
