#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
# Copyright (C) 2026 FreZeeN
# Part of crt-dual — https://github.com/frezeen
# nvidia.sh — GPU adapter, NVIDIA proprietary driver.
#
# ONE ORACLE: X. X says whether a port is
# populated, X carries the EDID, X shows the active timing. Sysfs is
# NEVER consulted on this family and does not exist for this adapter:
# EDIDs read 0 bytes even for LCDs, connector status LATCHES after an
# unplug on BOTH connector classes (measured 2026-08-21/23 GTX 970),
# and there are no DRM uevents. If this oracle is ever caught lying,
# the fix lives HERE and nowhere else.
#
# Family facts encoded here:
#   - analog replugs are only visible through the force-requery family
#     (--query): the watcher's fixed-cadence udevadm trigger + the 2s
#     poll below are the hotplug transport (glitch-free on this stack).
#   - clone = GPU SCALING: a scaled output keeps its native starred mode
#     while the Screen/header stay at the source size — per-output mode
#     fields cannot distinguish a stale clone; the Screen size can.
#   - the desktop interlace lands under the bare name "640x480" and
#     aliased modelines cannot attach to the analog port (ModePool
#     shadowing, BadMatch) — active-truth beats naming here.
#   - DRM connector index = X index + 1.

_impl_status() {
	# X --current token, ALWAYS (analog AND digital). Kept fresh by the
	# watcher's --query loop; --current serves the cached GETCONNECTOR.
	# RC-STABLE: echoes the token or nothing, always rc 0 — callers assign
	# plainly under set -e.
	local _v
	_v=$(_xrandr_connected "$1")
	if [ "$_v" = "1" ]; then
		echo connected
	elif [ "$_v" = "0" ]; then
		echo disconnected
	fi
	return 0
}

_impl_edid() {
	# Oracle = xrandr --prop, fetched once per detect cycle.
	if [ -z "$_EDID_PROPS_CACHE" ]; then
		_EDID_PROPS_CACHE=$(xrandr --display "${DISPLAY:-:0}" --prop 2>/dev/null)
	fi
	[ -n "$_EDID_PROPS_CACHE" ] && _output_has_edid "$_EDID_PROPS_CACHE" "$1"
}

_impl_drm_offset() {
	echo 1
}

_impl_crt_active_truth() {
	# The bare "640x480" name shadows our interlace alias here, so the
	# shared NAME match can never fire for the CRT desktop mode. The
	# Interlace flag of the ACTIVE mode is the family truth (--verbose
	# is glitch-free on this stack — dce_v6 blips are AMD-only).
	xrandr --display "${DISPLAY:-:0}" --verbose 2>/dev/null | awk -v o="$1" '
		/ connected | disconnected / { f = ($0 ~ o" ") ; next }
		f && /\*current/ && /Interlace/ { found=1 ; exit }
		END { exit (found ? 0 : 1) }
	'
}



_impl_fingerprint() {
	# X-side connector tokens — the family truth channel (sysfs NEVER).
	xrandr --display "${DISPLAY:-:0}" --current 2>/dev/null | awk '/ connected| disconnected/ {printf "%s:%s\n", $1, $2}' | sort | tr '\n' ' '
	echo
}


_impl_desktop_mode_name() {
	# Family fact (verified 2026-08-28, GTX 970, randr12 docs + live GTX 970):
	# the persistent conf Modeline "640x480i" is presented on the analog
	# port by its BARE name with the Interlace flag — "640x480" 13.038MHz,
	# the only 60Hz 640x480 attached (DefaultModes False keeps the VESA
	# pool off). The suffixed runtime name is impossible on this driver
	# (RRAddOutputMode BadMatch for resolution-shaped names, measured even
	# with an unused timing). --rate disambiguates the replug-synthesized
	# @75 (lesson 2026-08-10).
	echo "640x480"
}
