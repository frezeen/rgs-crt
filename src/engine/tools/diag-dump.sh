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

set -u

export DISPLAY="${DISPLAY:-:0}"
# RGS-15KHZ-EXT (2026-09-10, tester-report H9): the tree is FLATTENED
# (src/engine/tools + src/engine/lib), so the engine root is ONE level up
# from tools/ and the libs sit at lib/.
PACKAGE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

sep() {
	echo ""
	echo "════ $1 ═════════════════════════════════════"
}

sep "VERSIONS"
echo "  CRT-DUAL: $(cat /userdata/system/crt-dual.version 2>/dev/null || echo 'unknown')"
echo "  Date:     $(date '+%F %T')"

sep "GPU (full lspci lines)"
if command -v lspci >/dev/null 2>&1; then
	lspci 2>/dev/null | grep -iE "VGA|3D|Display controller" | sed 's/^/  /'
else
	echo "  lspci not available"
fi
if [ -r "$PACKAGE_DIR/lib/gpu-lib.sh" ]; then
	source "$PACKAGE_DIR/lib/gpu-lib.sh" 2>/dev/null
fi
# CRTC ownership truth (kernel `enabled` = encoder attached, not CRTC —
# the dimension every reconcile verdict uses; crtc-owner.sh, modetest).
if [ -r "$PACKAGE_DIR/display/crtc-owner.sh" ]; then
	source "$PACKAGE_DIR/display/crtc-owner.sh" 2>/dev/null
fi
if command -v detect_gpu >/dev/null 2>&1; then
	detect_gpu 2>/dev/null
	echo "  GPU_VENDOR=${GPU_VENDOR:-unknown}  GPU_MODEL=${GPU_MODEL:-unknown}"
else
	echo "  gpu-lib.sh not available"
fi

sep "GPU DRIVER + MESA (bounded, versions only)"
_drv=""
case "${GPU_VENDOR:-unknown}" in
	amd) _drv="amdgpu" ;;
	intel) _drv="i915" ;;
	nvidia) _drv="nvidia" ;;
esac
if [ -n "$_drv" ] && command -v modinfo >/dev/null 2>&1; then
	_dver=$(modinfo -F version "$_drv" 2>/dev/null || true) # why-or-true: module absent/unreadable -> fallback below
	[ -n "$_dver" ] && echo "  driver $_drv version: $_dver" || echo "  driver $_drv version: unavailable (module not loaded?)"
else
	echo "  driver version: unavailable (unknown vendor or no modinfo)"
fi
if command -v glxinfo >/dev/null 2>&1; then
	_gl=$(timeout 5 glxinfo -B 2>/dev/null | grep -E "OpenGL version|OpenGL renderer" || true) # why-or-true: no X -> empty -> fallback below
	[ -n "$_gl" ] && printf '%s\n' "$_gl" | sed 's/^/  /' || echo "  glxinfo: not available (X down?)"
else
	echo "  glxinfo: not installed"
fi

sep "XORG (recent errors)"
if [ -r /var/log/Xorg.0.log ]; then
	_xerr=$(grep -iE "\(EE\)|error|fail" /var/log/Xorg.0.log 2>/dev/null | tail -15)
	[ -n "$_xerr" ] && printf '%s\n' "$_xerr" | sed 's/^/  /' || echo "  no errors found"
else
	echo "  /var/log/Xorg.0.log not present"
fi

sep "DMESG DISPLAY (kernel drm/i915/amdgpu — full channel, bounded)"
_dm=$(dmesg 2>/dev/null | grep -iE "drm|i915|amdgpu|radeon|nvidia|nouveau" | tail -200 || true) # why-or-true: dmesg unreadable/empty -> fallback below
[ -n "$_dm" ] && printf '%s\n' "$_dm" | sed 's/^/  /' || echo "  dmesg unavailable or no display lines"

sep "XRANDR (FULL — all outputs, disconnected included)"
_xr=$(xrandr --current 2>/dev/null) || true
[ -n "$_xr" ] && printf '%s\n' "$_xr" | sed 's/^/  /' || echo "  xrandr not available (X down or wrong DISPLAY)"

sep "XRANDR VERBOSE (full — Transform: is the scaling truth)"
_xrv=$(timeout 10 xrandr --verbose 2>/dev/null || true) # why-or-true: X down -> empty -> fallback below
[ -n "$_xrv" ] && printf '%s\n' "$_xrv" | sed 's/^/  /' || echo "  xrandr --verbose not available (X down or wrong DISPLAY)"

sep "XRANDR MONITORS (--listmonitors)"
_xlm=$(timeout 10 xrandr --listmonitors 2>/dev/null || true) # why-or-true: X down -> empty -> fallback below
[ -n "$_xlm" ] && printf '%s\n' "$_xlm" | sed 's/^/  /' || echo "  xrandr --listmonitors not available (X down or wrong DISPLAY)"

sep "ROTATION (per-output, from --verbose)"
if [ -n "${_xrv:-}" ]; then
	_rot=$(printf '%s\n' "$_xrv" | grep -E " connected " || true) # why-or-true: zero connected outputs -> fallback below
	[ -n "$_rot" ] && printf '%s\n' "$_rot" | sed 's/^/  /' || echo "  no connected outputs in --verbose"
else
	echo "  unknown (--verbose unavailable)"
fi

sep "EDID PER OUTPUT (sysfs on amd/intel; xrandr --prop on nvidia)"
# --prop is GLITCH-class (force re-probe, measured 2026-08-12) and it
# re-probes EVERY output (a single --prop reads as several tube blips —
# verified visually at boot). On amd/intel the sysfs edid is the same DDC
# block, glitch-free; --prop is only needed on nvidia (sysfs edid 0 bytes).
if [ "${GPU_VENDOR:-}" != "amd" ] && [ "${GPU_VENDOR:-}" != "intel" ]; then
	_prop=$(xrandr --prop 2>/dev/null | grep -iE "^[A-Za-z0-9-]+ (connected|disconnected)|EDID:") || true
	[ -n "$_prop" ] && printf '%s\n' "$_prop" | sed 's/^/  /' || echo "  no EDID exposed"
else
	for _e in /sys/class/drm/card*/edid; do
		[ -s "$_e" ] && echo "  $(basename "$(dirname "$_e")"): EDID $(wc -c <"$_e") bytes (sysfs)"
	done
fi

sep "SYSFS /sys/class/drm (connector status + enabled + crtc owner)"
found=0
for d in /sys/class/drm/card*-*/; do
	[ -f "$d/status" ] || continue
	_cn=$(basename "$d")
	_cn=${_cn#card*-}
	_en=$(cat "$d/enabled" 2>/dev/null || true)
	_cr="?"
	command -v crtc_of >/dev/null 2>&1 && _cr=$(crtc_of "$_cn")
	[ -z "$_cr" ] && _cr=none
	echo "  $(basename "$d"): $(cat "$d/status" 2>/dev/null)  enabled=${_en:-?}  crtc=$_cr"
	found=1
done
[ "$found" = 0 ] && echo "  no DRM connectors"

sep "CRTC MAP (modetest -c -e, read-only kernel truth)"
# Guard mirrors display/crtc-owner.sh: CRT_DUAL_MODETEST seam, absent or
# failing tool = unknown (read-only: no forced probes, no writes).
_MT_BIN="${MODETEST:-modetest}"
if command -v "$_MT_BIN" >/dev/null 2>&1; then
	_mt=$(timeout 5 "$_MT_BIN" -c -e 2>/dev/null || true) # why-or-true: no DRM access -> fallback below
	[ -n "$_mt" ] && printf '%s\n' "$_mt" | sed 's/^/  /' || echo "  modetest produced no output (no DRM access?)"
else
	echo "  modetest not installed"
fi

sep "CONNECTORS (display-detect --all: drm class status edid x-name)"
if [ -r "$PACKAGE_DIR/display/display-detect.sh" ]; then
	bash "$PACKAGE_DIR/display/display-detect.sh" --all 2>/dev/null | while IFS=$'\t' read -r _d _c _s _e _x; do
		[ -n "$_d" ] && echo "  $_d  class=$_c  status=$_s  edid=${_e}B  x=$_x"
	done
else
	echo "  display-detect.sh not available"
fi
if [ -f "${CRT_DUAL_STATE_DIR:-/tmp/crt-dual}/detect-state" ]; then
	echo "  state: $(grep -E '^(CRT_OUTS|LCD_OUTS)=' "${CRT_DUAL_STATE_DIR:-/tmp/crt-dual}/detect-state" | tr '\n' ' ')"
fi

sep "99-crt.conf (FULL) + /etc/X11/xorg.conf.d/ listing"
if [ -f /etc/X11/xorg.conf.d/99-crt.conf ]; then
	echo "  PRESENT ($(wc -l </etc/X11/xorg.conf.d/99-crt.conf) lines, full text):"
	if [ -r /etc/X11/xorg.conf.d/99-crt.conf ]; then
		sed 's/^/  /' /etc/X11/xorg.conf.d/99-crt.conf
	else
		echo "  UNREADABLE by this user (run as root)"
	fi
else
	echo "  ABSENT -> stock X11 (no 15kHz X11)"
fi
echo "  --- ls -la /etc/X11/xorg.conf.d/ ---"
if [ -d /etc/X11/xorg.conf.d ]; then
	ls -la /etc/X11/xorg.conf.d/ 2>/dev/null | sed 's/^/  /' || echo "  listing failed"
else
	echo "  directory absent"
fi

sep "SWITCHRES.INI (/etc/switchres.ini, full text)"
if [ -f /etc/switchres.ini ]; then
	if [ -r /etc/switchres.ini ]; then
		sed 's/^/  /' /etc/switchres.ini
	else
		echo "  PRESENT but UNREADABLE by this user (run as root)"
	fi
else
	echo "  ABSENT (no switchres config on this box)"
fi

sep "crt-dual.* KEYS (batocera.conf)"
_cfg=$(grep -E "^crt-dual\." /userdata/system/batocera.conf 2>/dev/null) || true
[ -n "$_cfg" ] && printf '%s\n' "$_cfg" | sed 's/^/  /' || echo "  no crt-dual.* keys"

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
