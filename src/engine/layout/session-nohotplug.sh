#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
# Copyright (C) 2026 FreZeeN
# Part of crt-dual — https://github.com/frezeen
# session-nohotplug.sh — hold the stock checker's one-shot skip
# (/tmp/no-hotplug) fresh while a CRT-DUAL session owns the display, then
# clean it up.
#
# WHY (2026-09-19 evening, handoff clobber): the STOCK checker restarts ES on
# kernel hotplugs (ENV{HOTPLUG}=="1"); its display loop clobbered a solo-prep
# handed over at gameStart (target blanked mid-launch — rig evidence
# logs/rig-chain-boot-crt-20260919-040*.txt) and an ES restart tears down a
# running game. The checker honours /tmp/no-hotplug as a ONE-SHOT skip: a
# hotplug whose checker run lands DURING the session is caught here even when
# the event arrived before the guard went up (the usual launch-after-hotplug
# race). Self-terminating: exits and removes the file when the guard clears;
# started best-effort by apply_profile.sh at gameStart.
MODE_FILE="${CRT_DUAL_MODE_FILE:-/tmp/crt-dual-mode}"
PROFILE_FILE="${CRT_DUAL_PROFILE_FILE:-/tmp/crt-dual/profile}"
NOHOTPLUG_FILE="${CRT_DUAL_NOHOTPLUG_FILE:-/tmp/no-hotplug}"
touched=0
while [ -f "$MODE_FILE" ] || [ -f "$PROFILE_FILE" ]; do
	[ -f "$NOHOTPLUG_FILE" ] || : >"$NOHOTPLUG_FILE" 2>/dev/null
	[ -f "$NOHOTPLUG_FILE" ] && touched=1
	sleep 0.5
done
[ "$touched" = "1" ] && rm -f "$NOHOTPLUG_FILE" 2>/dev/null || true
exit 0
