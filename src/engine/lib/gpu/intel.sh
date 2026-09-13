#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
# Copyright (C) 2026 FreZeeN
# Part of crt-dual — https://github.com/frezeen
# intel.sh — GPU adapter, Intel UHD/i915-class kernel driver.
#
# ORACLES: sysfs status for DIGITAL ports — with the roles INVERTED vs
# NVIDIA: here xrandr "connected" can be the PHANTOM (a Monitor section
# keeps a gone port listed; verified 2026-08-11 friend's UHD 630: LCD
# detached, sysfs said disconnected, X still listed it connected -> the
# dual layout was applied against a ghost). The kernel channel is truth.
# True 480i on this stack requires the amxcs i915 patch (vermagic-tied;
# credit in README) — mode NAMING stays standard, so the desktop interlace
# matches by name like generic families.
# Hotplug transport = DRM uevents. Forced probes are tolerated on this
# stack (glitch-free like NVIDIA) but rarely needed: uevents carry the
# hotplug already.

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
	return 1 # the NAME match is the whole truth (patched i915 keeps names)
}

_impl_probe_periodic() {
	echo 1 # glitch-free family like NVIDIA
}

_impl_hotplug_poll() {
	: # uevent-driven family: no polling transport
}

_impl_fingerprint() {
	_sysfp_raw # sysfs truth channel
}

_impl_xorg_driver() { echo modesetting; }
_impl_tearfree() { echo true; }   # stock pageflip path unaffected (verified UHD 630)
_impl_monitor_variant() { echo "m640+m320"; }

_impl_desktop_mode_name() {
	# modesetting family: conf names verbatim (480i certified on UHD 630,
	# 2026-08-11). Same identity contract as amd.sh.
	echo "640x480i"
}
