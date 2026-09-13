#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
# Copyright (C) 2026 FreZeeN
# Part of crt-dual — https://github.com/frezeen
# hotplug-layout.sh — CRT-DUAL: MUTE hotplug poke (consolidate-watcher).
#
# The udev rule fires this on every drm change uevent. It does NOT detect,
# probe, or apply anything: a raced apply here would poison the layout
# fingerprint mid-uevent while X is still reconfiguring. By design there
# is exactly ONE applier: layout-watch.sh.
#
# This script only drops its OWN marker (udev-poke); the watcher's main
# loop consumes it as a pure wake-up bell (idle-only: during a game it
# sits until gameStop, then converges — same deferral the old handler had).
#
# State files:
#   $CRT_DUAL_STATE_DIR/udev-poke   created HERE, consumed+deleted by
#                                   layout-watch.sh (converge only — never
#                                   a forced probe; see the storm note below)

STATE_DIR="${CRT_DUAL_STATE_DIR:-/tmp/crt-dual}"
mkdir -p "$STATE_DIR" 2>/dev/null || true
# Distinct marker from the MANUAL hotplug-trigger: the watcher treats this
# as a pure wake-up bell (converge only, NEVER a forced udevadm trigger).
# Reusing hotplug-trigger would self-perpetuate: the watcher's manual
# handler runs udevadm trigger -> new uevent -> this poke -> new trigger
# (storm verified live 2026-08-23 12:49, ~4s cadence).
: >"$STATE_DIR/udev-poke" 2>/dev/null || true

exit 0
