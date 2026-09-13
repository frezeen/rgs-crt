#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
# Copyright (C) 2026 FreZeeN
# Part of crt-dual — https://github.com/frezeen
# diag-dump.sh — CRT-DUAL: complete diagnostic snapshot in one command.
#
# Produces EVERYTHING needed to diagnose CRT/LCD detection (cascade:
# EDID -> connected -> presumed+probe) WITHOUT asking the user anything —
# self-sufficient logs (share the full output, never excerpts).
#
# Usage:  bash src/tools/diag-dump.sh [> dump.txt]
# Where:  from the package dir, any GPU (NVIDIA/AMD/Intel), X up or down
#         (sysfs paths work pre-X).
#
# Output: stdout, tabulated sections. Share the full file.

export DISPLAY="${DISPLAY:-:0}"
# RGS-15KHZ-EXT (2026-09-10, tester-report H9 — backport entry in STATE):
# the vendored tree is FLATTENED (src/engine/tools + src/engine/lib), so
# the engine root is ONE level up from tools/ and the libs sit at lib/
# (the pre-vendor engine repo had src/tools + src/lib as siblings —
# upstream hunk: PACKAGE_DIR="$(dirname)/../.." + "$PACKAGE_DIR/src/lib/").
# Upstream fix goes here first at the next re-vendor; do not rename paths
# beyond the marked hunks.
PACKAGE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

sep() {
	echo ""
	echo "════ $1 ═════════════════════════════════════"
}

sep "VERSIONS"
echo "  CRT-DUAL: $(cat /userdata/system/crt-dual.version 2>/dev/null || echo 'unknown')"
echo "  Date:     $(date '+%F %T')"

sep "GPU (full lspci lines)"
lspci 2>/dev/null | grep -iE "VGA|3D|Display controller" | sed 's/^/  /' || echo "  lspci not available"
if [ -r "$PACKAGE_DIR/lib/gpu-lib.sh" ]; then
	source "$PACKAGE_DIR/lib/gpu-lib.sh" 2>/dev/null
fi
if command -v detect_gpu >/dev/null 2>&1; then
	detect_gpu 2>/dev/null
	echo "  GPU_VENDOR=$GPU_VENDOR  GPU_MODEL=$GPU_MODEL  GPU_DOTCLOCK=${GPU_DOTCLOCK:-25}"
else
	echo "  gpu-lib.sh not available"
fi

sep "XORG (recent errors)"
if [ -r /var/log/Xorg.0.log ]; then
	grep -iE "\(EE\)|error|fail" /var/log/Xorg.0.log 2>/dev/null | tail -15 | sed 's/^/  /' || echo "  no errors found"
else
	echo "  /var/log/Xorg.0.log not present"
fi

sep "XRANDR (FULL — all outputs, disconnected included)"
xrandr --current 2>/dev/null | sed 's/^/  /' || echo "  xrandr not available (X down or wrong DISPLAY)"

sep "EDID PER OUTPUT (sysfs on amd/intel; xrandr --prop on nvidia)"
# --prop is GLITCH-class (force re-probe, measured 2026-08-12) and it
# re-probes EVERY output (a single --prop reads as several tube blips —
# verified visually at boot). On amd/intel the sysfs edid is the same DDC
# block, glitch-free; --prop is only needed on nvidia (sysfs edid 0 bytes).
if [ "${GPU_VENDOR:-}" != "amd" ] && [ "${GPU_VENDOR:-}" != "intel" ]; then
	xrandr --prop 2>/dev/null | grep -iE "^[A-Za-z0-9-]+ (connected|disconnected)|EDID:" | sed 's/^/  /' || echo "  no EDID exposed"
else
	for _e in /sys/class/drm/card*/edid; do
		[ -s "$_e" ] && echo "  $(basename "$(dirname "$_e")"): EDID $(wc -c <"$_e") bytes (sysfs)"
	done
fi

sep "SYSFS /sys/class/drm (DRM connector status)"
found=0
for d in /sys/class/drm/card*-*/; do
	[ -f "$d/status" ] || continue
	echo "  $(basename "$d"): $(cat "$d/status" 2>/dev/null)"
	found=1
done
[ "$found" = 0 ] && echo "  no DRM connectors"

sep "CLASSIFICATION (display-lib cascade: EDID -> connected -> presumed)"
if [ -r "$PACKAGE_DIR/lib/display-lib.sh" ]; then
	source "$PACKAGE_DIR/lib/display-lib.sh" 2>/dev/null
fi
if command -v detect_outputs >/dev/null 2>&1; then
	detect_outputs 2>/tmp/diag-detect.$$.log
	grep "CRT-DUAL-DETECT" /tmp/diag-detect.$$.log 2>/dev/null | sed 's/^/  /'
	rm -f /tmp/diag-detect.$$.log
	echo "  CRT confirmed:  ${CRT_OUTS:-none}"
	echo "  CRT presumed:   ${CRT_PRESUMED_OUTS:-none}"
	echo "  LCD:            ${LCD_OUTS:-none}"
	echo "--- PROBE presumed outputs (the presumption test) ---"
	crt_probe 2>&1 | sed 's/^/  /'
else
	echo "  display-lib.sh not available"
fi

sep "99-crt.conf (/etc/X11/xorg.conf.d/)"
if [ -f /etc/X11/xorg.conf.d/99-crt.conf ]; then
	echo "  PRESENT ($(wc -l </etc/X11/xorg.conf.d/99-crt.conf) lines)"
	grep -E "^Section|    Identifier|    Modeline|    Driver|    Monitor " /etc/X11/xorg.conf.d/99-crt.conf 2>/dev/null | sed 's/^/  /'
else
	echo "  ABSENT -> stock X11 (no 15kHz X11)"
fi

sep "crt-dual.* KEYS (batocera.conf)"
grep -E "^crt-dual\." /userdata/system/batocera.conf 2>/dev/null | sed 's/^/  /' || echo "  no crt-dual.* keys"

sep "MODE FILE (/tmp/crt-dual-mode)"
if [ -f /tmp/crt-dual-mode ]; then
	echo "  /tmp/crt-dual-mode = $(cat /tmp/crt-dual-mode)"
else
	echo "  absent (no game active)"
fi

sep "ESSENTIAL BINARIES"
loc=$(command -v switchres 2>/dev/null)
if [ -n "$loc" ]; then
	echo "  switchres binary -> $loc"
else
	echo "  switchres binary -> NOT FOUND (not required: mode-setting uses the API bridge)"
fi
# The API bridge is the live path (plan 09): its version probe IS the
# ABI truth a debugger needs.
SR_API="$(cd "$(dirname "${BASH_SOURCE[0]}")/../api" && pwd)/switchres_api.py"
if [ -r "$SR_API" ]; then
	echo "  switchres API   -> $("$SR_API" version 2>/dev/null || echo 'PROBE FAILED')"
else
	echo "  switchres API helper -> MISSING ($SR_API)"
fi

sep "END"
echo "  Complete snapshot — no missing data for debugging."
