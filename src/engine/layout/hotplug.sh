#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
# Copyright (C) 2026 FreZeeN
# Part of crt-dual — https://github.com/frezeen
# hotplug.sh — CRT-DUAL: MANUAL hotplug re-apply (user-invoked).
#
# Signals the running layout watcher to re-detect + force-apply the
# layout NOW. The deterministic fix after plugging/unplugging a display
# by hand, for GPUs whose auto-detect is compromised (AMD dce_v6 analog:
# the only fast flip is the glitching forced probe; every passive surface
# is blind/garbage — see docs/RUNTIME-HOTPLUG.md and the plan 6b hotplug rework).
#
# Usage (from the box, via SSH):
#   bash /userdata/system/crt-dual/src/layout/hotplug.sh
#
# The watcher picks up the trigger within POLL_SEC (2s) and applies. The
# watcher must be running (boot service starts it). Idle-only: if a game
# owns the display, the watcher defers the trigger until gameStop.
#
# This is a non-destructive signal: it only creates a marker file that
# the watcher consumes and clears — it does not touch the display itself,
# so it is safe to run at any time.

STATE_DIR="${CRT_DUAL_STATE_DIR:-/tmp/crt-dual}"
mkdir -p "$STATE_DIR"

TRIGGER="$STATE_DIR/hotplug-trigger"
touch "$TRIGGER" || {
	echo "ERROR: cannot write $TRIGGER (is the state dir writable?)" >&2
	exit 1
}
echo "hotplug trigger sent to $TRIGGER — watcher will apply within ~2s"

exit 0
