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

# SESSION SUPPRESSION (2026-09-19 evening, handoff clobber): the STOCK checker
# (udev 80-switch-screen, ENV{HOTPLUG}=="1") restarts ES ~2 s after the same
# event; its display loop clobbers a just-handed-over solo-prep (gameStart
# right after a hotplug: target blanked — logs/rig-chain-boot-crt-20260919-040*.txt)
# and the ES restart tears down a running game. The checker honours
# /tmp/no-hotplug as a ONE-SHOT skip (its own lines 91-96): set it only for a
# real hotplug (HOTPLUG=1 — the exact condition the stock rule matches;
# synthetic triggers never wake the checker, so they must not leave a stale
# file) and only while our session guard is up. session-nohotplug.sh keeps
# the file fresh for the whole session (a checker run whose delay lands
# mid-launch is caught even when the event arrived before the guard); the
# poke below still goes out so the watch converges after the game.
MODE_FILE="${CRT_DUAL_MODE_FILE:-/tmp/crt-dual-mode}"
PROFILE_FILE="${CRT_DUAL_PROFILE_FILE:-/tmp/crt-dual/profile}"
NOHOTPLUG_FILE="${CRT_DUAL_NOHOTPLUG_FILE:-/tmp/no-hotplug}"
if [ "${HOTPLUG:-0}" = "1" ] && { [ -f "$MODE_FILE" ] || [ -f "$PROFILE_FILE" ]; }; then
	: >"$NOHOTPLUG_FILE" 2>/dev/null || true
fi
# Distinct marker from the MANUAL hotplug-trigger: the watcher treats this
# as a pure wake-up bell (converge only, NEVER a forced udevadm trigger).
# Reusing hotplug-trigger would self-perpetuate: the watcher's manual
# handler runs udevadm trigger -> new uevent -> this poke -> new trigger
# (storm verified live 2026-08-23 12:49, ~4s cadence).
: >"$STATE_DIR/udev-poke" 2>/dev/null || true

exit 0
