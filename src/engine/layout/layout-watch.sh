#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
# Copyright (C) 2026 FreZeeN
# Part of crt-dual — https://github.com/frezeen
# layout-watch.sh — CRT-DUAL thin watcher (v2, T14)
#
# THIN ARBITER: every wake-up source is a dumb bell; the single decision
# is delegated to SR-OWNER via want-file+flock (ADR 001 A, charter §1-§4).
# Deleted: state machine ~400 lines (light-retry/restore/pending-fix),
# fingerprint bookkeeping, separate udev actor merged. Owner now owns
# mode generation + application (display-lib converge-or-apply with
# verification and primary/ES handover, T13.1). This file only emits
# requests over the IPC channel — zero direct xrandr writes.
#
# Emitters (charter §2, all file/process reads, zero display contact in
# steady state except the 2s X poll on NVIDIA — glitch-free there):
#   sysfs flip (_sysfs_fp), X state (_xrandr_query_all), udev-poke,
#   manual trigger, desktop-mode change, ES pid change, game-guard clear,
#   boot first pass.
#
# Guards: game active (/tmp/crt-dual/profile or /tmp/crt-dual-mode) → sleep
# (owner yields, display owned by gameStart/gameStop).
#
# Convergence contract (race fix 2026-09-01): sr-owner's apply is
# deliberately retry-by-next-request ("fingerprint NOT updated, next check
# retries", sr-owner.sh layout_apply_if_changed). The thin watcher must
# therefore RE-EMIT a failed request every poll until it succeeds — AMD boot
# 2026-09-01 01:44:17 proved the old single-shot was a black-screen absorber:
# boot-first-pass fired 2ms inside the stock standalone's setOutput batch, the
# fused RandR state failed converge (rc=1), the failure died in `|| true` and
# nothing ever retried → dual booted fully black. The retry lands after stock
# settles (~4s) and converges by construction.
#
# /tmp state files — single-writer per charter §4 (header mandatory):
#   /tmp/crt-dual-mode                  selector at gameStart; watcher+diag read; gameStop+crash-clean clean
#   $CRT_DUAL_STATE_DIR/detect-state    detect_outputs (via owner) writes; watcher/selector read
#   $CRT_DUAL_STATE_DIR/probe-ok        crt_probe (via owner) writes+drops; detect_outputs reads
#   $CRT_DUAL_STATE_DIR/crt-desktop-mode _save_crt_desktop_mode (via owner) writes; watcher reads
#   $CRT_DUAL_STATE_DIR/layout-fp       owner (layout_apply_if_changed) writes (debug)
#   $CRT_DUAL_STATE_DIR/layout-fp-sysfs watcher writes+reads (flip detection, kept for debug)
#   $CRT_DUAL_STATE_DIR/hotplug-trigger hotplug.sh writes; watcher consumes (then udevadm trigger for AMD dce_v6)
#   $CRT_DUAL_STATE_DIR/udev-poke       udev rule writes; watcher consumes (mute wake-up)
#   $CRT_DUAL_STATE_DIR/want            watcher/game clients write; owner reads
#   $CRT_DUAL_STATE_DIR/want.lock       flock target for owner IPC
#   $CRT_DUAL_STATE_DIR/layout.lock     flock target held by owner apply
set -uo pipefail
export DISPLAY="${DISPLAY:-:0}"
: "${CRT_DUAL_STATE_DIR:=/tmp/crt-dual}"
MODE_FILE="${CRT_DUAL_MODE_FILE:-/tmp/crt-dual-mode}"
PROFILE_STATE="$CRT_DUAL_STATE_DIR/profile"
WANT_FILE="$CRT_DUAL_STATE_DIR/want"
WANT_LOCK="$WANT_FILE.lock"
LOG="${CRT_DUAL_WATCH_LOG:-/userdata/system/logs/layout-watch.log}"
POLL_SEC="${CRT_DUAL_LAYOUT_POLL_SEC:-2}"
MANUAL_HOTPLUG_FILE="${CRT_DUAL_STATE_DIR}/hotplug-trigger"
PKG_ROOT="${CRT_DUAL_PKG_ROOT:-/userdata/system/crt-dual}"
mkdir -p "$(dirname "$LOG")" 2>/dev/null || true
log() { echo "WATCH-THIN [$(date +%H:%M:%S.%3N)]: $*" | tee -a "$LOG" 2>/dev/null || true; }
# libs for adapter trampolines (_sysfs_fp, _xrandr_query_all if available)
for _lib in "$PKG_ROOT/src/lib/gpu-lib.sh" "$PKG_ROOT/src/lib/display-lib.sh" "$(dirname "$0")/../lib/gpu-lib.sh" "$(dirname "$0")/../lib/display-lib.sh"; do [ -r "$_lib" ] && source "$_lib" 2>/dev/null || true; done
command -v detect_gpu >/dev/null 2>&1 && detect_gpu 2>/dev/null || true
_request_owner() {
	mkdir -p "$(dirname "$WANT_FILE")" 2>/dev/null || true
	printf '%s\n' "dual" >"$WANT_FILE" 2>/dev/null || true
	# One path only: busy lock = NOT converged = retry (the old unlocked
	# `|| bash sr-owner` fallback was a double-writer behind flock, and
	# its trailing `|| true` pinned rc=0 so nothing ever retried — the
	# silent-swallow that ate the 2026-09-01 boot failure).
# Settle window (2026-09-03, AMD CRT-replug): retry-on-rc covers a FAILED
# apply, not a CONVERGED one that stock breaks afterwards (standalone
# --right-of lands ~1s after the es-pid event, no new emitter fires).
# `_settle_polls` re-probes read-only for 3 polls after every request.
	flock -n "$WANT_LOCK" bash "$PKG_ROOT/src/owner/sr-owner.sh" --apply
}
log "watcher-thin started (v2, owner stateless, want-file+flock) — POLL $POLL_SEC sec gpu=$GPU_VENDOR"
_first_pass=1
_pending_retry=0
_settle_polls=0
_prev_sysfp=""; _prev_xstate=""; _prev_desktop=""; _prev_espid=""
# family-gate: X poll glitches AMD dce_v6 (measured 2026-08-13), glitch-free on NVIDIA
# where it is HOTPLUG HEART (gpu-display-facts §2). AMD/Intel = sysfs/udev only.
_watch_iters="${CRT_DUAL_WATCH_ITERS:-0}"
while true; do
	if [ -n "${CRT_DUAL_WATCH_ITERS:-}" ]; then _watch_iters=$((_watch_iters - 1)); [ "$_watch_iters" -le 0 ] && break; fi
	if [ -f "$MODE_FILE" ] || [ -f "$PROFILE_STATE" ]; then _prev_game="active"; sleep "$POLL_SEC"; continue; fi
	_game_ended=0; [ "${_prev_game:-idle}" = "active" ] && _game_ended=1; _prev_game="idle"
	_fired=0; _reason=""
	if [ -f "$CRT_DUAL_STATE_DIR/udev-poke" ]; then rm -f "$CRT_DUAL_STATE_DIR/udev-poke" 2>/dev/null || true; _fired=1; _reason="${_reason} udev-poke"; fi
	if [ -f "$MANUAL_HOTPLUG_FILE" ]; then rm -f "$MANUAL_HOTPLUG_FILE" 2>/dev/null || true; _fired=1; _reason="${_reason} manual-trigger"; command udevadm trigger --action=change --subsystem-match=drm 2>/dev/null || true; fi
	_cur_sysfp=""; if command -v _sysfp_raw >/dev/null 2>&1; then _cur_sysfp=$(_sysfp_raw 2>/dev/null); else for _f in /sys/class/drm/card*-*/status; do [ -f "$_f" ] || continue; _cur_sysfp="$_cur_sysfp $(basename "$(dirname "$_f")"):$(cat "$_f" 2>/dev/null)"; done; _cur_sysfp=$(echo "$_cur_sysfp" | tr ' ' '\n' | sort | tr '\n' ' ' | sed 's/^ //'); fi
	if [ "$_cur_sysfp" != "$_prev_sysfp" ]; then [ -n "$_prev_sysfp" ] && _fired=1; _reason="${_reason} sysfs-flip"; _prev_sysfp="$_cur_sysfp"; fi
	if [ "$GPU_VENDOR" = "nvidia" ]; then
		_cur_xstate=""; if command -v _xrandr_query_all >/dev/null 2>&1; then _cur_xstate=$(_xrandr_query_all 2>/dev/null); else _cur_xstate=$(DISPLAY=:0 xrandr --query 2>/dev/null | awk '/ connected| disconnected/ {printf "%s:%s ", $1, $2}'); fi
		if [ "$_cur_xstate" != "$_prev_xstate" ]; then [ -n "$_prev_xstate" ] && _fired=1; _reason="${_reason} xstate"; _prev_xstate="$_cur_xstate"; fi
	fi
	_cur_desktop=$(cat "$CRT_DUAL_STATE_DIR/crt-desktop-mode" 2>/dev/null || true)
	if [ "$_cur_desktop" != "$_prev_desktop" ]; then [ -n "$_prev_desktop" ] && _fired=1; _reason="${_reason} desktop-mode"; _prev_desktop="$_cur_desktop"; fi
	_cur_espid=$(pgrep -f 'dbus-run-session.*emulationstation' 2>/dev/null | head -1 || true)
	if [ "$_cur_espid" != "$_prev_espid" ]; then [ -n "$_prev_espid" ] && _fired=1; _reason="${_reason} es-pid"; _prev_espid="$_cur_espid"; fi
	if [ "$_game_ended" = "1" ]; then _fired=1; _reason="${_reason} game-ended"; fi
	if [ "$_pending_retry" = "1" ]; then _fired=1; _reason="${_reason} retry"; fi
	if [ "$_first_pass" = "1" ]; then _first_pass=0; _fired=1; _reason="${_reason} boot-first-pass"; fi
	# Settle window (2026-09-03, AMD CRT-replug): our apply can CONVERGE
	# and stock's standalone loop still rewrite --right-of AFTER it (ES
	# restart passes land ~1s after the es-pid event) with no new emitter
	# to catch it — retry-on-rc is blind to post-success sabotage. So for
	# 3 polls after every request, re-probe convergence READ-ONLY via
	# `sr-owner --check` (detect-state + `xrandr --current`, R class only —
	# never --query/--verbose/--prop, the dce_v6 GLITCH classes) and
	# re-request only when broken. Zero writes when converged (the check
	# is the signal), zero contact when the window expires, never during
	# a game (guard above). NVIDIA excluded: its 2s X poll already sees
	# stock's rewrites as xstate events (certified tour) — that path is
	# byte-identical to before.
	if [ "$_settle_polls" -gt 0 ] && [ "${GPU_VENDOR:-}" != "nvidia" ]; then
		_settle_polls=$((_settle_polls - 1))
		if ! bash "$PKG_ROOT/src/owner/sr-owner.sh" --check 2>/dev/null; then
			_fired=1; _reason="${_reason} settle-recheck"
		fi
	fi
	if [ "$_fired" = "1" ]; then log "emitter${_reason} → request owner"; _request_owner; _pending_retry=$?; if [ "${GPU_VENDOR:-}" != "nvidia" ]; then _settle_polls=3; fi; fi
	sleep "$POLL_SEC"
done
