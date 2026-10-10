#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
# Copyright (C) 2026 FreZeeN
# Part of crt-dual — https://github.com/frezeen
# display-reconcile.sh — the ONE writer (ADR-002). Event loop:
# guard aware (a session owns the display), coalesced wake bells
# (poke / manual trigger / DRM status flip / ES pid / game-ended), then
# reconcile = detect -> model -> apply-if-needed -> verify. A correct
# state is ZERO writes. After an apply a short settle window re-checks
# read-only: stock rewrites ~1 s after an ES restart land with no new
# event and must be caught (the old watcher's lesson, kept as a
# post-condition, not a branch).
#
# Usage:
#   display-reconcile.sh --check    read-only verdict (rc 0 = reality == plan)
#   display-reconcile.sh --once     one reconcile pass (yield during a session)
#   display-reconcile.sh --daemon   the loop
set -uo pipefail
export DISPLAY="${DISPLAY:-:0}" # the daemon is setsid-detached: every xrandr call needs it explicitly
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_DIR="${CRT_DUAL_STATE_DIR:-/tmp/crt-dual}"
MODE_FILE="${CRT_DUAL_MODE_FILE:-/tmp/crt-dual-mode}"
PROFILE_FILE="${CRT_DUAL_PROFILE_FILE:-/tmp/crt-dual/profile}"
# Poll interval: the gameStop bell (udev-poke) is only seen at a loop wake,
# so this bounds the visible "desktop comes back late" gap after a game
# exit (owner-observed ~1 s FullHD flash at 2 s, 2026-09-20). 0.5 s keeps
# the wake quick; the per-iteration work is cheap status reads.
POLL="${CRT_DUAL_RECONCILE_POLL:-0.5}"
LOG="${CRT_DUAL_RECONCILE_LOG:-/userdata/system/logs/display-reconcile.log}"
ITERS="${CRT_DUAL_RECONCILE_ITERS:-0}" # 0 = forever (tests set a finite count)
log() { echo "RECONCILE [$(date +%H:%M:%S)]: $*" | tee -a "$LOG" 2>/dev/null || true; }
_x() { timeout 5 env DISPLAY="${DISPLAY:-:0}" xrandr --current 2>/dev/null; }

_session_active() { [ -f "$MODE_FILE" ] || [ -f "$PROFILE_FILE" ]; }

# ── Deadlock breaker probes (root cause, measured 2026-10-10) ────────────
# emulatorlauncher (ES's child, one per session) returns only when it sees
# EOF on the game's stdout/stderr pipes. When the game's gamescope dies, the
# processes UNDER it — gamescopereaper and the winedevice workers — are
# reparented to init and SURVIVE, still holding the write ends. Proven from
# the fd table: emulatorlauncher held pipe:[180915] read; gamescopereaper
# held that same pipe write. EOF never arrives, emulatorlauncher never
# returns, ES never runs gameStop, and the guard stays up for good: the dual
# never returns and the frontend never reappears.
#
# The signature is ORPHANHOOD, not an emulator list: "my parent is dead and
# I am not" (PPID 1) while emulatorlauncher still waits is exactly this
# deadlock, and it says nothing about which emulator ran — so it does not
# rot as emulators are added.
#
# Both probes are seamed so the breaker's LOGIC is testable without real
# orphans (the house style: seams for live paths).
_emu_alive() { # rc 0 while the session's emulatorlauncher waits
	if [ -n "${CRT_DUAL_EMU_ALIVE_CMD:-}" ]; then
		bash -c "$CRT_DUAL_EMU_ALIVE_CMD"
		return $?
	fi
	# -f (full cmdline), NOT -x (process name): "emulatorlauncher" is 16
	# characters and comm is truncated to 15, so `pgrep -x emulatorlauncher`
	# NEVER matches — measured on the box the first time this ran, where the
	# breaker sat silent with the orphan right there. This is the same test
	# the box's own batocera-es-swissknife uses (check_emurun).
	pgrep -f -n emulatorlauncher >/dev/null 2>&1
}
_dead_orphans() { # pids of orphaned pipe-holders, one per line
	if [ -n "${CRT_DUAL_ORPHANS_CMD:-}" ]; then
		bash -c "$CRT_DUAL_ORPHANS_CMD"
		return 0
	fi
	ps -eo pid=,ppid=,comm= 2>/dev/null \
		| awk '$2=="1" && $3 ~ /^(gamescope|gamescopereaper|wine|winedevice|wineserver|xenia)/ {print $1}'
}

SYSFS="${CRT_DUAL_SYSFS:-/sys/class/drm}"
_target_active() { # $1 = X output -> active mode AND kernel-enabled (the truth pair)
	local tm td en
	tm=$(_x | sed -n "/^$1 connected/,/^[^ ]/p" | awk '$0 ~ /\*/ { print $1; exit }')
	td=$(bash "$HERE/display-detect.sh" --list 2>/dev/null | awk -F'\t' -v x="$1" '$3 == x { print $1; exit }')
	en=$(cat "$SYSFS/card0-$td/enabled" 2>/dev/null)
	if [ -n "$tm" ] && [ -n "$td" ] && [ "$en" = "enabled" ]; then
		return 0
	fi
	log "target-active($1): mode='${tm:-}' drm='${td:-}' enabled='${en:-}'"
	return 1
}

_topology() { # crt/lcd X names, from the detect module (single source)
	local out
	out=$(bash "$HERE/display-detect.sh" --check 2>/dev/null) || return 1
	printf '%s' "$out"
}

_write_detect_state() { # compatible state for the selector/apply_profile readers
	local out crt lcd
	out=$(_topology) || return 1
	crt=$(printf '%s' "$out" | sed -n 's/.*crt=\([^ ]*\).*/\1/p')
	lcd=$(printf '%s' "$out" | sed -n 's/.*lcd=\([^ ]*\).*/\1/p')
	{
		printf 'CRT_OUTS=%s\n' "$crt"
		printf 'CRT_PRESUMED_OUTS=\n'
		printf 'LCD_OUTS=%s\n' "$lcd"
		printf 'CRT_OUT=%s\n' "$crt"
		printf 'CRT_PRESUMED_OUT=\n'
		printf 'LCD_OUT=%s\n' "$lcd"
	} >"$STATE_DIR/detect-state.tmp" 2>/dev/null && mv "$STATE_DIR/detect-state.tmp" "$STATE_DIR/detect-state" 2>/dev/null || true
}

_session_start() { # $1 = crt|lcd — hand the display to the game (stock owns the raster)
	local target="$1" out crt lcd other tname rc=0 _err
	case "$target" in crt | lcd) ;; *) echo "display-reconcile: --session-start needs crt|lcd" >&2; return 2 ;; esac
	_reconcile_lock || { echo "display-reconcile: session-start: lock busy" >&2; return 1; }
	out=$(_topology) || { echo "display-reconcile: session-start: detect failed" >&2; _reconcile_unlock; return 1; }
	crt=$(printf '%s' "$out" | sed -n 's/.*crt=\([^ ]*\).*/\1/p')
	lcd=$(printf '%s' "$out" | sed -n 's/.*lcd=\([^ ]*\).*/\1/p')
	_write_detect_state
	if [ -z "$crt" ] || [ -z "$lcd" ]; then
		log "session-start: single-display topology (crt=${crt:-none} lcd=${lcd:-none}) — nothing to prep, stock owns the launch"
		_reconcile_unlock
		return 0
	fi
	if [ "$target" = "crt" ]; then
		other="$lcd"
		tname="$crt"
		_err=$(xrandr --output "$other" --off 2>&1) || { log "session-start: $other off FAILED: $_err"; rc=1; }
	else
		other="$crt"
		tname="$lcd"
		# two calls (AMD R9 270X, measured): off both, then a clean takeover —
		# the dual mirror leaves a stale transform on the panel and a single
		# --primary is a silent no-op in that state.
		_err=$(xrandr --output "$crt" --off --output "$lcd" --off 2>&1) || { log "session-start: outputs off FAILED: $_err"; rc=1; }
		if [ "$rc" = "0" ]; then
			_err=$(xrandr --output "$lcd" --primary --auto 2>&1) || { log "session-start: $lcd takeover FAILED: $_err"; rc=1; }
		fi
	fi
	if [ "$rc" = "0" ] && _target_active "$tname"; then
		log "session-start: $target session prepped ($other off, target active)"
		_reconcile_unlock
		return 0
	fi
	if [ "$rc" = "0" ]; then
		log "session-start: target $target not active after prep — one repair"
		xrandr --output "$tname" --off 2>/dev/null || true
		xrandr --output "$tname" --primary --auto 2>/dev/null || true # the off frees the CRTC, the takeover re-programs (measured two-step)
		if _target_active "$tname"; then
			log "session-start: $target session prepped (after one repair)"
			_reconcile_unlock
			return 0
		fi
	fi
	log "session-start: LOUD FAILURE — $target not active after prep+repair"
	_reconcile_unlock
	return 1
}

_sysfp() { # DRM status fingerprint (no display contact)
	local f out=""
	for f in /sys/class/drm/card*-*/status; do
		[ -f "$f" ] || continue
		out="$out $(basename "$(dirname "$f")"):$(cat "$f" 2>/dev/null)"
	done
	printf '%s' "$out" | tr ' ' '\n' | sort | tr '\n' ' '
}

_reconcile() {
	_reconcile_lock || return 1
	if _session_active; then # the guard may have gone up while we waited for the lock
		log "session started while waiting — yield (the game owns the display)"
		_reconcile_unlock
		return 0
	fi
	_write_detect_state
	local out rc
	out=$(bash "$HERE/display-apply.sh" --apply 2>&1)
	rc=$?
	if [ "$rc" = "0" ]; then
		# Follow the screen, then repaint. Two owner-observed effects on
		# the same apply: (1) ES keeps its old window geometry after a mode
		# change — a 1920x1080 window on a 640x480 screen makes the menu
		# never appear and the engine's solo-prep contract time out (rig
		# DUAL-LCD cells, 2026-09-20); (2) it also keeps a stale GL frame
		# until some input arrives. Resize to the screen and jiggle the
		# mouse 2px: both are the harmless equivalents of the owner's
		# manual fix.
		if command -v xdotool >/dev/null 2>&1; then
			_wid=$(DISPLAY="${DISPLAY:-:0}" xdotool search --class emulationstation 2>/dev/null | head -1)
			if [ -n "$_wid" ]; then
				_sw=$(DISPLAY="${DISPLAY:-:0}" xrandr --current 2>/dev/null \
					| sed -n 's/.*current \([0-9][0-9]*\) x \([0-9][0-9]*\).*/\1x\2/p' | head -1)
				_ww=$(DISPLAY="${DISPLAY:-:0}" xdotool getwindowgeometry "$_wid" 2>/dev/null \
					| sed -n 's/.*Geometry: //p')
				if [ -n "$_sw" ] && [ -n "$_ww" ] && [ "$_ww" != "$_sw" ]; then
					DISPLAY="${DISPLAY:-:0}" xdotool windowsize "$_wid" $_sw 2>/dev/null || true
					log "apply: ES window $_ww -> $_sw (followed the screen)"
				fi
			fi
			DISPLAY="${DISPLAY:-:0}" xdotool mousemove_relative -- 2 0 2>/dev/null || true
			DISPLAY="${DISPLAY:-:0}" xdotool mousemove_relative -- -2 0 2>/dev/null || true
		fi
		_reconcile_unlock
		return 0
	fi
	_reconcile_unlock
	log "apply NOT verified: $(printf '%s' "$out" | tail -2 | tr '\n' ' ')"
	return 1
}
RECONCILE_LOCK_FILE="$STATE_DIR/reconcile.lock"
_reconcile_lock() {
	command -v flock >/dev/null 2>&1 || return 0
	exec 9>"$RECONCILE_LOCK_FILE" 2>/dev/null || return 0
	flock -w 5 9 2>/dev/null || return 1
}
_reconcile_unlock() {
	command -v flock >/dev/null 2>&1 || return 0
	flock -u 9 2>/dev/null || true
	exec 9>&- 2>/dev/null || true
}

case "${1:---check}" in
--check)
	if bash "$HERE/display-apply.sh" >/dev/null 2>&1; then
		echo "display-reconcile: reality matches the plan"
		exit 0
	fi
	bash "$HERE/display-apply.sh" >&2
	exit 1
	;;
--once)
	if _session_active; then
		log "session active — yield (the game owns the display)"
		exit 0
	fi
	# Exit WITH the verdict: zz_crt_dual's WARN branch exists exactly for
	# this rc. Without the explicit exit, the trailing `exit 0` made
	# "Boot layout applied" a false green (2026-09-22 tester report: a
	# LOUD FAILURE line was followed by "applied").
	_reconcile
	exit $?
	;;
--session-start)
	_session_start "${2:-}"
	exit $?
	;;
--daemon)
	log "reconcile loop started (poll ${POLL}s, state $STATE_DIR)"
	prev_fp=""
	prev_es=""
	prev_game="idle"
	_dead_hits=0
	_first=1
	settle=0
	i=0
	while true; do
		i=$((i + 1))
		if [ "$ITERS" -gt 0 ] && [ "$i" -gt "$ITERS" ]; then break; fi

		# ── Deadlock breaker (root cause, measured 2026-10-10) ─────────
		# emulatorlauncher (ES's child, one per session) returns only when
		# it sees EOF on the game's stdout/stderr pipes. When the game's
		# gamescope dies, the processes UNDER it — gamescopereaper and the
		# winedevice workers — are reparented to init and SURVIVE, still
		# holding the write ends. Proven from the fd table: emulatorlauncher
		# held pipe:[180915] read; gamescopereaper held the same pipe write.
		# EOF never arrives, so emulatorlauncher never returns, ES never
		# runs gameStop, and the session guard stays up for good: the dual
		# never returns and the frontend never reappears.
		#
		# The signature is ORPHANHOOD, not an emulator list: a wrapper whose
		# parent is gone (PPID 1) while emulatorlauncher is still alive IS
		# this deadlock — and it is emulator-agnostic, which is why it will
		# not rot as emulators are added. Killing the orphans closes the
		# pipes and the whole chain unwinds BY ITSELF: emulatorlauncher
		# exits normally, ES runs gameStop, the guard clears. We therefore
		# do NOT touch emulatorlauncher — killing it would skip the gameStop
		# that is the point of the exercise.
		#
		# Evaluated BEFORE the session short-circuit below: while a session
		# is stuck the guard is UP, so a check placed after it would never
		# run — the exact mistake this replaces.
		#
		# Two consecutive polls: a wrapper that is merely mid-exit is left
		# alone; only one that stays orphaned is a deadlock.
		if _emu_alive; then
			_dead_orp="$(_dead_orphans | tr '\n' ' ')"
			if [ -n "${_dead_orp// /}" ]; then
				_dead_hits=$((_dead_hits + 1))
			else
				_dead_hits=0
			fi
			if [ "$_dead_hits" -ge 2 ]; then
				log "deadlock breaker: emulatorlauncher is waiting on pipes an orphaned wrapper still holds (${_dead_orp% }) — closing them"
				_kill_set="$_dead_orp"
				# one level of descendants: the winedevice workers live under
				# the reaper and hold pipes of their own (55 fds, measured).
				for _dp in $_dead_orp; do
					_kids="$(ps -eo pid=,ppid= 2>/dev/null | awk -v p="$_dp" '$2==p {print $1}' | tr '\n' ' ')"
					_kill_set="$_kill_set $_kids"
				done
				# shellcheck disable=SC2086 # a pid list is the point
				kill $_kill_set 2>/dev/null || true
				sleep 1
				# shellcheck disable=SC2086 # wine helpers ignore SIGTERM
				kill -9 $_kill_set 2>/dev/null || true
				_dead_hits=0
			fi
		else
			_dead_hits=0
		fi

		if _session_active; then
			prev_game="active"
			sleep "$POLL"
			continue
		fi
		fired=""
		[ "$_first" = "1" ] && {
			_first=0
			fired="$fired boot-first-pass"
		}
		[ "$prev_game" = "active" ] && fired="$fired game-ended"
		prev_game="idle"
		if [ -f "$STATE_DIR/udev-poke" ]; then
			rm -f "$STATE_DIR/udev-poke" 2>/dev/null || true
			fired="$fired poke"
		fi
		if [ -f "$STATE_DIR/hotplug-trigger" ]; then
			rm -f "$STATE_DIR/hotplug-trigger" 2>/dev/null || true
			fired="$fired manual"
			udevadm trigger --action=change --subsystem-match=drm 2>/dev/null || true
		fi
		fp=$(_sysfp)
		if [ "$fp" != "$prev_fp" ]; then
			[ -n "$prev_fp" ] && fired="$fired sysfs"
			prev_fp="$fp"
		fi
		es=$(pgrep -f 'dbus-run-session.*emulationstation' 2>/dev/null | head -1 || true)
		if [ "$es" != "$prev_es" ]; then
			[ -n "$prev_es" ] && fired="$fired es-pid"
			prev_es="$es"
		fi
		if [ -n "$fired" ]; then
			log "event:$fired → reconcile"
			_reconcile && settle=3 || true
		elif [ "$settle" -gt 0 ]; then
			settle=$((settle - 1))
			if ! bash "$HERE/display-apply.sh" >/dev/null 2>&1; then
				log "settle-recheck: broken after a converged apply → reconcile"
				_reconcile && settle=3 || true
			fi
		fi
		sleep "$POLL"
	done
	;;
*)
	echo "usage: display-reconcile.sh [--check|--once|--daemon|--session-start crt|lcd]" >&2
	exit 2
	;;
esac
exit 0
