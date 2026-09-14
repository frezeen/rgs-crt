#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
# Copyright (C) 2026 FreZeeN
# Part of crt-dual — https://github.com/frezeen
# generic.sh — GPU adapter, fallback family (vendor unknown / pre-detection).
#
# Part of the gpu-adapters contract (2026-08-23): shared code asks the
# ADAPTER for family truth; this file is the conservative historical
# behavior — raw sysfs channels — used when no specific family matches.
# Each adapter declares its ONE oracle per question in its header.
#
# Impls (called through display-lib trampolines):
#   _impl_status <xout>            -> "connected"|"disconnected"|""
#   _impl_edid <xout>              -> 0|1 (EDID evidence, own --prop policy)
#   _impl_drm_offset               -> echo DRM index offset vs X (0)
#   _impl_crt_active_truth <xout>  -> 0|1 extra truth when the mode NAME
#                                     did not match a 15kHz class name

_impl_status() {
	cat "$CRT_DUAL_SYSFS"/card*-"$(_drm_connector "$1")"/status 2>/dev/null | head -1
}

_impl_edid() {
	_sysfs_edid_present "$1" && return 0
	# sysfs DDC trustworthy on real families (any readable edid) -> skip
	# the GLITCH-class --prop probe (measured 2026-08-12 dce_v6).
	if [ -z "$_EDID_PROPS_CACHE" ] && ! _sysfs_has_any_edid; then
		_EDID_PROPS_CACHE=$(xrandr --display "${DISPLAY:-:0}" --prop 2>/dev/null)
	fi
	[ -n "$_EDID_PROPS_CACHE" ] && _output_has_edid "$_EDID_PROPS_CACHE" "$1"
}

_impl_drm_offset() {
	echo 0
}

_impl_crt_active_truth() {
	return 1 # the NAME match is the whole truth on generic families
}



_impl_fingerprint() {
	_sysfp_raw # conservative default: sysfs channel
}

_impl_desktop_mode_name() {
	# conservative: the conf name as written (modesetting-shaped families
	# keep it verbatim — the safe presentation is the suffixed one).
	echo "640x480i"
}
