#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
# Copyright (C) 2026 FreZeeN
# Part of crt-dual — https://github.com/frezeen
# first_script.sh — CRT-DUAL: stock USER_SCRIPTS hook (gameStart/gameStop)
#
# The ONLY hook point, synchronous. Timing note: stock Batocera runs
# gameStart AFTER the generator is resolved (names, not line refs:
# get_generator -> callExternalScripts). For per-game EMULATOR selection
# the RAM monkey-patch (sitecustomize.py) hoists this hook BEFORE
# Emulator() reads batocera.conf; at that point emulator/core ($3/$4) are
# still unknown (empty) — exactly what the selector decides. It:
#
# gameStart: hotplug re-check -> selector-core (gate decision) ->
# apply_profile.sh (marked blocks + display switch + batocera
# keys) -> configgen reads them and picks the emulator
# gameStop:  remove_profile.sh (blocks removed, display restored)
#
# Installed at /userdata/system/scripts/first_script.sh (USER_SCRIPTS).
# Single writer of /tmp/crt-dual/profile : this script
# writes the state file ONLY when a profile was actually applied.
#
# Exit code: always 0 for the emulator (a profile failure must not block
# the game launch — fallback is stock behavior).

export DISPLAY="${DISPLAY:-:0}"

PKG_ROOT="/userdata/system/crt-dual"
ENGINE_DIR="$PKG_ROOT/src/selector"
STATE_FILE="/tmp/crt-dual/profile"
STATE_DIR="/tmp/crt-dual"
# The state file lives in /tmp/crt-dual/ (single source of
# truth, single writer). The dir is NOT the display layer's /tmp/crt-dual-*
# (hyphenated) namespace — it must exist for the `>` write to succeed
# (observed on box 2026-08-10: gameStart applied the profile but the state
# write failed, leaving gameStop without a profile to remove).
mkdir -p "$STATE_DIR"

log() { echo "CRT-DUAL-HOOK [$(date +%H:%M:%S.%3N)]: $*" >&2; }

# Display: the reconciler (ADR-002) is the only display owner — this hook
# does the keys/profile work and hands the session over via apply_profile.

case "$1" in
gameStart)
	exec 1>&2 # RGS-15KHZ-EXT — same rule as gameStop (see block there)
	log "gameStart ($2, core=${3:-unknown})"

	# dotclock floor: measured at BOOT by the S30z hook (pre-X,
	# KMS-native: mode set + WAIT_VBLANK = the behavioural oracle), which
	# writes BOTH switchres inis fresh every boot (volatile /etc write,
	# no overlay save). Nothing runs at game launch: an emulator can
	# never be disturbed by a mode walk (owner directive 2026-09-20).

	# Selector decision (gate display × profiles — the picker appears only
	# when a real choice exists; empty output = stock default, no profile).
	_CHOICE="$(bash "$ENGINE_DIR/selector-core.sh" 2>/dev/null)"

	if [ -n "$_CHOICE" ]; then
		log "profile chosen: $_CHOICE"
		if bash "$ENGINE_DIR/apply_profile.sh" "$_CHOICE" "$2"; then
			echo "$_CHOICE" >"$STATE_FILE" # single writer log "profile $_CHOICE active"
		else
			log "WARN: apply_profile failed for $_CHOICE — running stock (fallback)"
		fi
	else
		log "no profile — stock behavior"
	fi
	;;

gameStop)
	# RGS-15KHZ-EXT BEGIN (stdout->stderr, both hooks). ES pipes the game command's stdout
	# through head -300 ("head -300" x2 in the emulationstation binary,
	# es_launch_stdout.log capped at exactly 300 lines — observed 2026-09-06
	# RGS 43.41). When the cap falls inside gameStop the pipe read-end dies:
	# merge.py's buffered shutdown flush then fails with EPIPE ("Exception
	# ignored ... TextIOWrapper <stdout>", rc 120 — reproduced on this box),
	# remove_profile.sh reports a FAILED that never happened AND skips its
	# step 2 (want=dual + guard clean) -> dual desktop silently lost on
	# emukill-quit. Rebinding our stdout to stderr (es_launch_stderr.log is
	# a direct file, no cap, no race) makes the exit code truthful and keeps
	# merge.py's status lines readable. The picker is unaffected: its stdout
	# is a command-substitution pipe (selector-core.sh), not fd 1.
	exec 1>&2

	log "gameStop ($2)"

	_PREV="$(cat "$STATE_FILE" 2>/dev/null)"
	if [ -n "$_PREV" ] && [ -d "$ENGINE_DIR" ]; then
		log "removing profile $_PREV (system=$2)"
		bash "$ENGINE_DIR/remove_profile.sh" "$_PREV" "$2" || log "WARN: remove_profile failed for $_PREV"
	else
		# no profile active — restore the desktop layout (CRT-only gameStop
		# fallback when the state file was lost, e.g. crash + manual exit)
		command -v restore_after_game >/dev/null 2>&1 && restore_after_game >/dev/null 2>&1 || true # best-effort; see apply
	fi
	rm -f "$STATE_FILE"
	log "gameStop done"
	;;

*)
	echo "usage: $0 {gameStart|gameStop}" >&2
	exit 1
	;;
esac

exit 0
