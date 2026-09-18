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

# Impls: shared sysfs-family base (audit 2026-09-18 — the three sysfs
# families were byte-identical after comment stripping; family evidence
# stays in this header, the mechanism lives in sysfs-family.sh once).
# Family note (kept): conservative fallback — same sysfs channels.
# This adapter overrides nothing.
source "${BASH_SOURCE[0]%/*}/sysfs-family.sh"
