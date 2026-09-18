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

# Impls: shared sysfs-family base (audit 2026-09-18 — the three sysfs
# families were byte-identical after comment stripping; family evidence
# stays in this header, the mechanism lives in sysfs-family.sh once).
# This adapter overrides nothing.
source "${BASH_SOURCE[0]%/*}/sysfs-family.sh"
