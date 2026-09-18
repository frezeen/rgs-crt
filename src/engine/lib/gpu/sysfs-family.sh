#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
# Copyright (C) 2026 FreZeeN
# Part of crt-dual — https://github.com/frezeen
# sysfs-family.sh — shared body of the sysfs-truth adapters
# (amd.sh / intel.sh / generic.sh).
#
# Audit 2026-09-18: the three adapter files were byte-identical after
# comment stripping; the family EVIDENCE stays in each adapter header,
# the mechanism lives here once. An adapter may override any `_impl_*`
# after sourcing when a real family divergence appears (today none does).
#
# Oracles (all three families): sysfs status for presence; sysfs DDC
# first, lazy --prop only when NO readable sysfs edid exists anywhere
# (the --prop probe is GLITCH-class on dce_v6); sysfs fingerprint;
# DRM index = X index (offset 0); desktop name verbatim.

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

_impl_fingerprint() {
	_sysfp_raw # sysfs truth channel
}

_impl_desktop_mode_name() {
	# modesetting families keep conf Modeline names verbatim: the desktop
	# is "640x480i" (AMD owner directive 2026-08-28: il 480i non si tocca).
	# The bare "640x480" is the kernel-synthesized 54MHz DoubleScan slot
	# (tube-destructive, incident 2026-08-12) — never a desktop name.
	echo "640x480i"
}
