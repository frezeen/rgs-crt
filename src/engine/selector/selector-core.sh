#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
# Copyright (C) 2026 FreZeeN
# Part of crt-dual — https://github.com/frezeen
# selector-core.sh — CRT-DUAL: the profile DECISION, testable headless.
#
# The selector is TWO parts — this
# bash core (pure decision logic, runs in the dry-run harness, NEVER
# renders) and selector-ui.py (pygame thin render+input, only launched
# when a REAL choice exists).
#
# GATE TABLE (the picker appears ONLY when a real choice exists).
# Profiles match displays via their [display] target: only profiles
# whose target is a CONFIRMED display
# participate.
#
#   Displays (CONFIRMED)      Compatible profiles      Picker   Result
#   only CRT                  1 targeting crt          NO       that profile
#   only LCD                  1 targeting lcd          NO       that profile
#   one display               2+ targeting it          YES      picker
#   CRT + LCD (dual)          >=1 crt + >=1 lcd        YES      picker
#   none                      any                      NO       stock default
#
# Compatibility is the CONFIRMED display, never presumed: a presumed
# analog port with an LCD present is an
# empty port, not a second display.
#
# Output: prints the chosen profile name, or empty = stock default
# (no profile — safe default). Also writes /tmp/crt-dual-profile-options
# (candidates + default) for selector-ui.py, and NEVER the state file
# (single writer = first_script.sh only).
#
# Usage: selector-core.sh
# Exit:  0 always (decision made; empty output = stock default)
#
# Env (test seams): CRT_DUAL_PKG_ROOT, CRT_DUAL_TARGET_ROOT,
# CRT_DUAL_UI (path to selector-ui.py; set to "" to force no UI),
# CRT_DUAL_FIXTURE + mock xrandr (dry-run harness, tests/run.sh).
#
# Fallback on pygame init failure = the CORE's default for the display
# present (never "CRT always" — the default must match reality).

set -uo pipefail

PKG_ROOT="${CRT_DUAL_PKG_ROOT:-/userdata/system/crt-dual}"
PROFILES_ROOT="$PKG_ROOT/profiles"
LIB="$PKG_ROOT/src/lib/display-lib.sh"
UI="${CRT_DUAL_UI:-$PKG_ROOT/src/selector/selector-ui.py}"

log() {
	echo "CRT-DUAL-CORE: $*" >&2
	echo "CRT-DUAL-CORE: $*" >>"${CRT_DUAL_LOG_FILE:-/userdata/system/logs/selector-core.log}" 2>/dev/null || true
}

# ── 1. Display detection (CONFIRMED only) ──
# Both libs: gpu-lib (detect_gpu -> GPU_VENDOR/GPU_MODEL) is the
# display-lib prerequisite (2026-08-12: sourcing display-lib alone left
# GPU_VENDOR unset, which opened the --prop fallback gate -> 3 G per
# gameStart).
for _lib in "$PKG_ROOT/src/lib/gpu-lib.sh" "$LIB"; do
	[ -r "$_lib" ] && source "$_lib" 2>/dev/null
done
command -v detect_gpu >/dev/null 2>&1 && detect_gpu 2>/dev/null
command -v detect_outputs >/dev/null 2>&1 && detect_outputs 2>/dev/null || true

# LCD real-check (2026-08-11): an LCD is a REAL display only when the X
# mode list shows native modes (>=800px width). The NVIDIA driver keeps a
# connector "connected" with a stale EDID after an unplug (HPD not
# processed — verified on box: sysfs connected but only 640x480/320x240
# left, EDID modes dropped), while a plugged LCD exposes its native
# modes. A connector with only base modes has no monitor -> not
# confirmed. The Intel DP->VGA converter keeps its VESA modes
# (800x600+), so the CRT-presumption path is untouched. Post-X only
# (xrandr); pre-X (boot service) falls back to the sysfs classification.
if [ -n "${LCD_OUTS:-}" ]; then
	_XR="$(xrandr --current 2>/dev/null)" || _XR=""
	if [ -n "$_XR" ]; then
		_CONFIRMED=""
		for _o in ${LCD_OUTS}; do
			if printf '%s\n' "$_XR" | sed -n "/$_o connected/,/^[A-Z]/p" | grep -qE '^\s+([8-9][0-9]{2}|[1-9][0-9]{3,})x'; then
				_CONFIRMED="$_CONFIRMED $_o"
			else
				log "LCD '$_o' has no native modes in X (unplugged?) — not confirmed"
			fi
		done
		LCD_OUTS="$_CONFIRMED"
	fi
fi

# Confirmed displays only (presumed is not confirmed).
HAS_CRT=0
HAS_LCD=0
[ -n "${CRT_OUTS:-}" ] && HAS_CRT=1
[ -n "${LCD_OUTS:-}" ] && HAS_LCD=1

log "displays: crt=$HAS_CRT lcd=$HAS_LCD (CRT_OUTS='${CRT_OUTS:-}' LCD_OUTS='${LCD_OUTS:-}')"

# ── 2. Profile discovery + [display] target ──
declare -a PROFILES_CRT PROFILES_LCD
PROFILES_CRT=()
PROFILES_LCD=()

if [ -d "$PROFILES_ROOT" ]; then
	for _d in "$PROFILES_ROOT"/*/; do
		[ -d "$_d" ] || continue
		_name="$(basename "$_d")"
		[ -f "$_d/spec.conf" ] || continue
		_target="$(python3 "$PKG_ROOT/src/selector/spec-target.py" "$_d" 2>/dev/null || echo crt)"
		case "$_target" in
		crt) PROFILES_CRT+=("$_name") ;;
		lcd) PROFILES_LCD+=("$_name") ;;
		esac
	done
fi

# ── 3. Gate: display × profiles ──
declare -a CANDIDATES
CANDIDATES=()
if [ "$HAS_CRT" = "1" ]; then
	CANDIDATES+=("${PROFILES_CRT[@]}")
fi
if [ "$HAS_LCD" = "1" ]; then
	CANDIDATES+=("${PROFILES_LCD[@]}")
fi

if [ "${#CANDIDATES[@]}" = "0" ]; then
	log "no compatible profile for the active display — stock default"
	exit 0 # empty output = stock
fi

if [ "${#CANDIDATES[@]}" = "1" ]; then
	log "one compatible profile — applying it, no picker"
	echo "${CANDIDATES[0]}"
	exit 0
fi

# ── 4. Real choice exists → UI (thin render+input), fallback = default ──
# Default = first alphabetical candidate (deterministic, no state file).
DEFAULT="${CANDIDATES[0]}"
for _c in "${CANDIDATES[@]}"; do
	[ "$_c" \< "$DEFAULT" ] && DEFAULT="$_c"
done

{
	echo "# candidates for selector-ui.py (one per line)"
	printf '%s\n' "${CANDIDATES[@]}"
	echo "# default"
	echo "$DEFAULT"
} >/tmp/crt-dual-profile-options 2>/dev/null || true # advisory for the UI; absence = core default

if [ -n "$UI" ] && [ -f "$UI" ]; then
	# tail -1: the UI's stdout is the chosen profile name; pygame used to
	# print its support banner to stdout too, corrupting the capture
	# (diagnosis 2026-08-10) — the last line is always the choice.
	_chosen="$(python3 "$UI" 2>/dev/null | tail -1)"
	# UI returns a candidate name, or empty on timeout/failure
	if [ -n "$_chosen" ]; then
		# validate: only a listed candidate may be applied
		_ok=0
		for _c in "${CANDIDATES[@]}"; do
			[ "$_c" = "$_chosen" ] && _ok=1
		done
		if [ "$_ok" = "1" ]; then
			log "picker chose '$_chosen'"
			echo "$_chosen"
			exit 0
		fi
	fi
	log "picker failed/timeout — default '$DEFAULT' (display present, never 'CRT always')"
else
	log "UI unavailable — default '$DEFAULT' (display present)"
fi

echo "$DEFAULT"
exit 0
