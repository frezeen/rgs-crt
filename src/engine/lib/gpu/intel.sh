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

# Impls: shared sysfs-family base (audit 2026-09-18 — the three sysfs
# families were byte-identical after comment stripping; family evidence
# stays in this header, the mechanism lives in sysfs-family.sh once).
# Family note (kept): 480i certified on UHD 630, 2026-08-11.
# This adapter overrides nothing.
source "${BASH_SOURCE[0]%/*}/sysfs-family.sh"
