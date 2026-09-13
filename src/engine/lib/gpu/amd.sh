#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
# Copyright (C) 2026 FreZeeN
# Part of crt-dual — https://github.com/frezeen
# amd.sh — GPU adapter, AMD dce_v6-class kernel driver.
#
# ORACLES: sysfs status for DIGITAL ports (kernel truth — X can phantom-
# stay "connected" with a Monitor section); NO analog presence truth
# exists anywhere on this stack (dce_v6 has no analog HPD — sysfs said
# "disconnected" while the driver drove our 480i modeline, verified
# 2026-08-12 R9 270X). Analog CRTs are therefore confirmed by LIVE
# EVIDENCE only: active 15kHz timing / probe / user override — that part
# lives in the shared cascade; this adapter supplies the channels:
#   - sysfs status raw for every port (digital truth + cross-consumer agreement)
#   - EDID from sysfs DDC first (--prop probe is GLITCH-class here:
#     it blips a lit tube, measured 2026-08-12 — fetched only when no
#     readable sysfs edid exists anywhere)
#   - forced periodic probes FORBIDDEN: they re-probe every connector on
#     the shared encoder and flicker the lit CRT (operator-verified) —
#     hotplug transport = DRM uevents + manual trigger only.

_impl_status() {
	cat "$CRT_DUAL_SYSFS"/card*-"$(_drm_connector "$1")"/status 2>/dev/null | head -1
}

_impl_edid() {
	_sysfs_edid_present "$1" && return 0
	if [ -z "$_EDID_PROPS_CACHE" ] && ! _sysfs_has_any_edid; then
		_EDID_PROPS_CACHE=$(xrandr --display "${DISPLAY:-:0}" --prop 2>/dev/null)
	fi
	[ -n "$_EDID_PROPS_CACHE" ] && _output_has_edid "$_EDID_PROPS_CACHE" "$1"
}

_impl_drm_offset() {
	echo 0
}

_impl_crt_active_truth() {
	return 1 # the NAME match is the whole truth (desktop modes are named)
}

_impl_probe_periodic() {
	echo 0 # glitch discipline: never a periodic forced probe on dce_v6
}

_impl_hotplug_poll() {
	: # uevent-driven family: no polling transport
}

_impl_fingerprint() {
	_sysfp_raw # sysfs truth channel
}

_impl_xorg_driver() { echo modesetting; }
_impl_tearfree() { echo false; }              # direct pageflips (official v43 parity)
_impl_monitor_variant() { echo "m640+m320"; } # modesetting exports conf modelines

_impl_desktop_mode_name() {
	# modesetting keeps conf Modeline names verbatim: the desktop is
	# "640x480i" — the exact name the certified AMD stream requests
	# (owner directive 2026-08-28: il 480i non si tocca). The bare
	# "640x480" here is the kernel-synthesized 54MHz DoubleScan slot
	# (tube-destructive, incident 2026-08-12), never a desktop name.
	echo "640x480i"
}
