#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
# Copyright (C) 2026 FreZeeN
# Part of crt-dual — https://github.com/frezeen
# crt-x11-generator.sh — CRT-DUAL CRT X11 Config Generator
#
# Generates /etc/X11/xorg.conf.d/99-crt.conf with 15kHz modelines.
# GPU detection via gpu-lib.sh + display-lib.sh.
# NVIDIA: vendor-specific options in the Device section below.
# AMD: the boot service calls get_xorg_configs() (gpu-lib.sh) which
# neutralises the stock amdgpu/radeon OutputClass (Batocera 43.1 ships no
# amdgpu xorg DDX) and forces the modesetting DDX — official CRT Script
# v43 lines 4664-4686. The 99-crt.conf Device also pins modesetting.
# stdout (status) is redirected to the log by the caller.
#
# Usage: ./crt-x11-generator.sh [--force]

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PACKAGE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

echo "=== CRT-DUAL CRT X11 Config Generator ==="

# GPU detection via common library
source "$PACKAGE_DIR/lib/gpu-lib.sh" 2>/dev/null || true # package libs mandatory below (set -u fails loud if absent)
source "$PACKAGE_DIR/lib/display-lib.sh" 2>/dev/null || true
detect_gpu
# RGS-15KHZ-EXT (dotclock): the check_dotclock call REMOVED with the
# whitelist — the floor is measured at the first CRT game launch and
# feeds the GAME consumers only (RA config-dir override). The DESKTOP
# modelines below are ALWAYS floor-free (PR rule: 480i is the boot mode
# by definition; /etc/switchres.ini stays stock and is never written),
# so this generator never calls the duty and no floor can bake into the
# conf.

echo "GPU: $GPU_VENDOR ($GPU_MODEL)"
echo "Note: X11 config generated for the detected GPU. The runtime applier (sr-owner.sh) uses"
echo "standard cross-GPU RandR commands — AMD/Intel work without NVIDIA workarounds."

# ──────────────────────────────────────────────
# Output detection
# ──────────────────────────────────────────────
# NOTE: on NVIDIA the DRM names (DVI-I-1) do NOT match the X11 names
# (DVI-I-0). xrandr is used when available, otherwise an exhaustive
# list of possible output names (the same approach as the official
# CRT Script).

echo ""
echo "--- Output detection ---"

# Classification centralized in display-lib.sh (detect_outputs).
# NO hardcoded port name: by TYPE (analog->CRT 15kHz,
# digital->native LCD 31kHz+). detect_outputs reads xrandr if DISPLAY is
# available, otherwise leaves CRT_OUTS/LCD_OUTS empty (handled downstream).
detect_outputs
echo "  -> CRT (15kHz): ${CRT_OUTS:-none}"
echo "  -> LCD (native): ${LCD_OUTS:-none}"

# Effective CRT outputs = CONFIRMED + PRESUMED (last resort). The
# presumption applies ONLY to analog (VGA/DVI-I): a digital can never be
# a CRT. The 15kHz modeline is thus available on the analog output even
# when "disconnected" (VGA no-EDID) -> the probe can drive it.
CRT_ALL="$(crt_all)"
echo "  -> effective CRT (confirmed+presumed): ${CRT_ALL:-none}"

# All X output names of one class from the kernel connector list: the
# "universal" cushions below (CRT sections in LCD-only, LCD sections in
# CRT-only) come from here — fully dynamic, no hardcoded ports, one
# DRM->X mapping source (_drm_to_x).
_all_outputs_of_class() { # $1 = analog|digital
	local _acc="" _p _o _x
	for _p in /sys/class/drm/card*-*; do
		[ -e "$_p" ] || continue
		_o="$(basename "$_p" | sed 's/^card[0-9]*-//')"
		_x=$(_drm_to_x "$_o" 2>/dev/null)
		if [ "$1" = "analog" ]; then
			_output_is_analog "$_x" 2>/dev/null && _acc="$_acc $_x"
		else
			_output_is_analog "$_x" 2>/dev/null || _acc="$_acc $_x"
		fi
	done
	echo "$_acc" | sed 's/^ //'
}

# Universal 99 cushion: when booting LCD-only (no CRT detected, CRT_ALL empty)
# the X config would otherwise have no CRT Monitor section, so a later hotplug
# has no modeline/Disable ready and must rely on runtime xrandr + videoMode race.
# Instead, generate the CRT sections for EVERY analog candidate from sysfs
# (DVI-I*, VGA*) — fully dynamic, no hardcoded DVI-I-1, no batocera.conf key.
# X ignores a disconnected analog Monitor (no phantom), but when the CRT is
# hotplugged the modeline/DefaultModes are already there.
if [ -z "$CRT_OUTS" ]; then
	# LCD-only (no confirmed CRT): generate CRT sections for EVERY analog
	# candidate so hotplug has the modeline — primary stays on LCD.
	CRT_ALL="$(_all_outputs_of_class analog)"
	[ -n "$CRT_ALL" ] && echo "  -> universal CRT (LCD-only, all analog): $CRT_ALL"
fi

# NVIDIA_MON_OPTS and PRIMARY_MON depend only on the output names (not on
# the modelines) — computed here. The Monitor sections (with $M640/$M320)
# are generated AFTER the Modeline section, where the variables exist.
NVIDIA_MON_OPTS=""
if [ "$GPU_VENDOR" = "nvidia" ]; then
	for out in $CRT_ALL; do
		NVIDIA_MON_OPTS+="$(printf '    Option "monitor-%s" "%s"' "$out" "$out")"$'\n'
	done
	for out in $LCD_OUTS; do
		NVIDIA_MON_OPTS+="$(printf '    Option "monitor-%s" "%s"' "$out" "$out")"$'\n'
	done
fi

# Screen0 primary monitor: the first CONFIRMED CRT, otherwise the
# first LCD (so Xorg always has a valid display to initialize).
# On LCD-only (no confirmed CRT) the universal CRT sections are still
# generated for hotplug, but primary stays on LCD — otherwise X would
# boot with a disconnected DVI-I-1 as primary and videoMode would see
# an empty currentResolution (the 31k race).
if [ -n "$CRT_OUTS" ]; then
	PRIMARY_MON=$(echo "$CRT_OUTS" | awk '{print $1}')
else
	PRIMARY_MON=$(echo "$LCD_OUTS" | awk '{print $1}')
fi

# ──────────────────────────────────────────────
# Modeline — ONE 480i + ONE 240p, ONLY from SwitchRes, ALWAYS native
# ──────────────────────────────────────────────
# Single source: switchres with a floor-neutral copy of the system ini
# (floor forced to 0 — the desktop never follows the decided floor, PR
# rule; the source is still /etc/switchres.ini, not a package ini: same
# monitor preset, same math).
# Mode name: "640x480i" — the UNIQUE official Batocera interlace name
# (batocera-and-crt wiki: --newmode "640x480i" 13.10 ... interlace). Unique
# = no collision with the kernel-synthesized "640x480" (54MHz DoubleScan,
# 60kHz hsync — destructive on a 15kHz tube; verified 2026-08-12 AMD R9
# 270X: the analog re-probe re-adds it and the shared name made
# --mode "640x480" nondeterministic — the tube went black at boot).
# batocera-resolution setMode 640x480i.60 -> xrandr --mode 640x480i
# (es.resolution and the profiles' global.videomode use the "i" name).
# NO hardcoded fallback (no custom modeline): if switchres
# fails, abort WITHOUT touching the existing conf.
# Tube refresh: crt-dual.refresh in batocera.conf (50 = PAL TV,
# default 60 = NTSC). The initial modeline stays ALWAYS 480i
# (640x480 interlaced) — only the vertical frequency changes.

# Dynamic CRT refresh (the crt-dual.refresh key, shared with the game profiles)
CRT_DUAL_REFRESH="$(grep -E '^crt-dual\.refresh[[:space:]]*=' /userdata/system/batocera.conf 2>/dev/null | tail -1 | cut -d= -f2- | tr -d '[:space:]')"
if ! [[ "$CRT_DUAL_REFRESH" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
	CRT_DUAL_REFRESH=60
fi

echo "CRT refresh: ${CRT_DUAL_REFRESH}Hz (crt-dual.refresh in batocera.conf)"

echo ""
echo "--- Modeline ---"

# Floor-neutral BY INVARIANT: /etc/switchres.ini is stock (floor 0) and
# NOTHING in this layer ever writes it (the PR rule) — the desktop calc
# reads it directly, same as the official script. The decided floor feeds
# the GAME consumers only (RA config-dir override). Seam (source ini):
# RGS15_SYS_SWITCHRES (default = live path, used by tests/seams).
SR_INI="${RGS15_SYS_SWITCHRES:-/etc/switchres.ini}"
# (seam above is the one source)
# Switchres API bridge (data-plane): timings from the STOCK
# libswitchres.so via ctypes — no CLI shell-out, no stdout parsing beyond
# the Modeline shape. The helper computes ONLY (screen=dummy); the conf
# write below stays our single source of persistent canonical names.
SR_API="$PACKAGE_DIR/api/switchres_api.py"

M640=""
M320=""
if [ -r "$SR_API" ] && [ -f "$SR_INI" ]; then
	M640=$("$SR_API" calc 640 480 "$CRT_DUAL_REFRESH" --ini "$SR_INI" | sed -E 's/Modeline "[^"]*"/Modeline "640x480i"/')
	M320=$("$SR_API" calc 320 240 "$CRT_DUAL_REFRESH" --ini "$SR_INI" | sed -E 's/Modeline "[^"]*"/Modeline "320x240"/')
fi

if [ -z "$M640" ] || [ -z "$M320" ]; then
	echo "❌ switchres API produced no modelines (helper: $SR_API, ini: $SR_INI)"
	echo "   99-crt.conf NOT modified — better an old conf than a custom modeline."
	exit 1
fi

echo "  640x480 (480i): $M640"
echo "  320x240 (240p): $M320"

# ──────────────────────────────────────────────
# Monitor sections PER OUTPUT (Identifier = output name) -> auto-attach Xorg
# on ALL drivers (core RandR 1.2+, no Device-specific option):
#   analog  -> 15kHz section (640x480/320x240 modelines + sync range)
#   digital -> native EDID section (31kHz+)
# NO digital output is forced to 15kHz: an LCD cannot sync at 15kHz ->
# black screen. NO "everything on CRT".
#
# CONNECTED DIGITAL PORTS (pre-X, PASSO 4): nature UNCERTAIN — LCD with
# EDID not yet read by the kernel, or CRT behind a converter (both
# sysfs-connected without EDID). A CRT section (15kHz modeline +
# DefaultModes False) on an LCD suppresses the native modes (X does not
# re-probe EDID) -> LCD out of sync (verified HP 800 G5 2026-08-09).
# Therefore: SAFE section (Identifier only) -> X re-probes EDID at startup
# (native LCD preserved); if it is a CRT, the modes are generated by the
# runtime applier (SR-OWNER -> switchres). The CRT section
# stays for analogs (certain CRT) and for DISCONNECTED ports (candidates —
# no EDID to suppress).
# ──────────────────────────────────────────────

# Sysfs (kernel) state of the connector from the X name — delegated to
# _sysfs_status() in display-lib.sh (single DRM->X mapping, NVIDIA index+1).

# NOTE: the printf is inside $(...) -> command substitution STRIPS trailing
# newlines. Sections are written with a LEADING newline (\n before Section)
# and NO trailing newline: between sections the next one's leading \n
# remains (verified live: 'EndSectionSection' = Xorg parse error -> no
# screens found -> black screen).
CRT_MON_SECTIONS=""
for out in $CRT_ALL; do
	# A CONFIRMED CRT gets the full 15kHz section on ANY connector. The
	# old name-based gate (dvi-i|vga|crt + sysfs connected) gave a bare
	# section to a confirmed CRT on a connected DIGITAL port (Intel DP++
	# VGA: connector "DP-2", no EDID) -> no interlace modeline in X ->
	# the 480i set failed (ENOENT), the runtime fell back to 240p, and
	# the modelines ended up on DISCONNECTED candidate ports. Verified
	# with an Intel UHD 630: CRT on DP-2 with an
	# empty Monitor section while DP-3 (empty port) carried the 480i
	# mode. Confirmed ports are no-EDID or user-declared (crt-dual.
	# crt_output), so no LCD EDID is suppressed.
	_is_confirmed=0
	for _c in $CRT_OUTS; do
		[ "$out" = "$_c" ] && _is_confirmed=1
	done
	# LCD-only boot: CRT_OUTS empty → universal CRT is hotplug-only (Modeline in pool, not active). Presumed must not light at boot, but mode must be in pool for later hotplug.
	if [ -z "$CRT_OUTS" ] && [ -n "$CRT_ALL" ]; then
		_is_confirmed=0
		if _output_is_analog "$out"; then
			# Full 15kHz pool (M640/M320) but no Enable — X has the mode, hotplug can --addmode/--mode, but DVI stays off at boot (LCD 1920 native).
			if [ "$GPU_VENDOR" = "nvidia" ]; then
				CRT_MON_SECTIONS+="$(printf '\nSection "Monitor"\n    Identifier  "%s"\n    VendorName  "CRT-DUAL"\n    HorizSync   15-17\n    VertRefresh 30-62\n    %s\n    Option "DPMS" "False"\n    Option "DefaultModes" "False"\nEndSection' "$out" "$M640")"
			else
				CRT_MON_SECTIONS+="$(printf '\nSection "Monitor"\n    Identifier  "%s"\n    VendorName  "CRT-DUAL"\n    HorizSync   15-17\n    VertRefresh 30-62\n    %s\n    %s\n    Option "DPMS" "False"\n    Option "DefaultModes" "False"\nEndSection' "$out" "$M640" "$M320")"
			fi
			continue
		fi
	fi
	if [ "$_is_confirmed" = "0" ] && ! _output_is_analog "$out"; then
		# NON-ANALOG, non-confirmed — CONNECTED or DISCONNECTED: SAFE
		# section (Identifier + DefaultModes False only).
		#
		# connected: nature UNCERTAIN (LCD with EDID not yet read, or CRT
		# behind a converter). A CRT section (15kHz modelines + HorizSync
		# 15-17) on an LCD SUPPRESSES the native EDID modes (X does not
		# re-probe EDID on a Monitor section) -> LCD out of sync
		# (verified HP 800 G5 2026-08-09).
		#
		# disconnected: the port is empty NOW but a real LCD may be
		# plugged in at runtime (verified 2026-08-11 friend's Intel UHD
		# 630: DP-1 disconnected at boot -> got the 15kHz candidate
		# section -> when the CS270 was plugged, X had only 640x480/
		# 320x240 for it -> LCD black). Same suppression: NO HorizSync,
		# NO modelines -> X re-probes EDID on connect and the native
		# modes appear. A CRT plugged here later is driven by the
		# runtime applier (SR-OWNER --newmode/--mode), which does not
		# depend on pre-defined X modelines. Also: no "Enable" -> X
		# leaves a disconnected port off (no phantom head; verified
		# 2026-08-11: Screen 1280x480 = ES 640x480 + empty DP-3).
		#
		# DefaultModes False: no builtin VESA modes (640x480/1024x768/
		# 800x600 = 31kHz+) on EDID-less ports — the stock Batocera
		# checker/docked used them to put 31kHz on the CRT-converter
		# (640x480@59.94, "crooked" on SCART TV). A real LCD's EDID modes
		# remain (DefaultModes only touches the default modes).
		CRT_MON_SECTIONS+="$(printf '\nSection "Monitor"\n    Identifier  "%s"\n    Option "DefaultModes" "False"\nEndSection' "$out")"
	else
		# CONFIRMED CRT or ANALOG port: full 15kHz section, enabled.
		# Modeline policy (verified on a GTX 970):
		# - AMD/Intel: modesetting DDX exports conf modelines to RandR —
		#   plain names attach directly. Both modelines embedded as before.
		# - NVIDIA: embed ONLY the 480i Modeline (NOT the 240p — its name
		#   stays FREE for the runtime's fresh creation) AND pair it with
		#   the Display-subsection "Modes" request + MetaModes (built
		#   below). Per NVIDIA README (Programming Modes): pool modes are
		#   advertised to RandR ONLY when requested — unrequested conf
		#   modelines are ModePool-shadowed (addmode BadMatch, reproduced
		#   live). With the request in place: X STARTS in the final clone
		#   layout (CRT 480i primary + LCD native ViewPortIn-scaled), tube
		#   lit from birth, CRT-only included (no 'no screens found').
		if [ "$GPU_VENDOR" = "nvidia" ]; then
			# Modeline on EVERY analog output, confirmed OR presumed (2026-08-24):
			# the hotplug path NEEDS the 480i already in X's mode pool. The old
			# rule (modeline only on confirmed, "one name one owner") assumed
			# runtime fresh-name creation would serve presumed ports - but
			# sr_init_disp REFUSES an output whose mode list is empty (verified
			# live GTX 970: lcd-only boot -> empty pool -> create failed -> tube
			# could never light). Select-first owns the certified name anyway:
			# a conf-provided mode is SELECTED by the runtime, never re-created,
			# so there is no shadow conflict left.
			CRT_MON_SECTIONS+="$(printf '\nSection "Monitor"\n    Identifier  "%s"\n    VendorName  "CRT-DUAL"\n    HorizSync   15-17\n    VertRefresh 30-62\n    %s\n    Option "Enable" "true"\n    Option "DPMS" "False"\n    Option "DefaultModes" "False"\nEndSection' "$out" "$M640")"
		else
			CRT_MON_SECTIONS+="$(printf '\nSection "Monitor"\n    Identifier  "%s"\n    VendorName  "CRT-DUAL"\n    HorizSync   15-17\n    VertRefresh 30-62\n    %s\n    %s\n    Option "Enable" "true"\n    Option "DPMS" "False"\n    Option "DefaultModes" "False"\nEndSection' "$out" "$M640" "$M320")"
		fi
	fi
done

if [ -z "$LCD_OUTS" ]; then
	# CRT-only (no LCD detected): generate LCD sections for EVERY digital
	# candidate so hotplug LCD later has the EDID Monitor ready — fully
	# dynamic via sysfs analog check, no hardcoded HDMI-1.
	LCD_OUTS="$(_all_outputs_of_class digital)"
	[ -n "$LCD_OUTS" ] && echo "  -> universal LCD (CRT-only, all digital): $LCD_OUTS"
fi
LCD_MON_SECTIONS=""
for out in $LCD_OUTS; do
	# NO forced-enable option here (fix 2026-08-23, R9 270X): on the
	# modesetting DDX a forced enable creates a PHANTOM head — X reports
	# the port connected with no cable, so hotplug transitions never
	# reach X (plug absorbed -> LCD black; unplug absorbed -> stale ES
	# geometry; verified live: xrandr 'connected' minutes after the
	# cable was pulled). Digital ports have real HPD: X follows them
	# natively, and the watcher sees the layout change it exists for.
	# The kernel uevent path is healthy (udevadm monitor captured the
	# card0 change event) — only the conf masked it. NVIDIA DDX does not
	# consume this option (no-op there); the analog CRT keeps its Enable
	# because dce_v6 has no HPD truth on the shared encoder.
	LCD_MON_SECTIONS+="$(printf '\nSection "Monitor"\n    Identifier  "%s"\n    VendorName  "CRT-DUAL"\n    HorizSync   30-140\n    VertRefresh 40-120\n    Option "DPMS" "True"\nEndSection' "$out")"
done

# ──────────────────────────────────────────────
# Disabled (phantom) outputs — per-output Ignore, as the official CRT
# Script does (Batocera-CRT-Script 10-monitor.conf: one Monitor section
# per disabled output with Option "Ignore" "true", Identifier = output
# name). Auto-attach via Identifier: X elides the output from RandR,
# no Device indirection needed. Verified on AMD 2026-08-25: the previous
# Device indirection (Monitor-DP-1 -> Disabled) left DP-1 still enabled
# (X log: Output DP-1 using monitor section DVI-I-1) because the Device
# GPU0 was not the bound GPUDevice on modesetting — the phantom survived.
# Direct per-output Ignore is what the official script ships and what the
# wiki recommends ("highly recommended to disable digital exclusives").
#
# Every connector the GPU exposes but that gets NO Monitor section above
# (roleless empties — disconnected digitals like the empty DP on a
# CRT+LCD box) gets its own Ignore section. No phantom "connected".
#
# The X output names come from the SYSFS connector list via the shared
# reverse mapping (_drm_to_x in display-lib.sh — one mapping source for
# both directions). NOT from xrandr: a running X already hides the
# Disabled outputs, so a regen from xrandr would drop the very options
# that kill the phantoms (self-negating, verified 2026-08-12: the
# regenerated conf lost the Disabled options because the current X no
# longer listed the phantoms). The sysfs always lists every connector
# (kernel truth).
#
# Escape hatch: a user-declared crt-dual.crt_output is a CONFIRMED CRT
# (in CRT_ALL -> has a Monitor section -> never Disabled).
DISABLED_OUTS=""
_all_outs=$(ls -d /sys/class/drm/card*-* 2>/dev/null | sed 's|.*/card[0-9]*-||')
for _o in $_all_outs; do
	_x=$(_drm_to_x "$_o" 2>/dev/null)
	_covered=0
	for _c in $CRT_ALL $LCD_OUTS; do
		[ "$_x" = "$_c" ] && _covered=1
	done
	if [ "$_covered" = "0" ]; then
		DISABLED_OUTS="$DISABLED_OUTS $_x"
		# NVIDIA maps DRM->X with an index-1 offset (DP-1->DP-0, DVI-I-1->
		# DVI-I-0) but the ACTUAL X output may still keep the raw DRM name
		# (observed GTX 970: _drm_to_x DP-1->DP-0 yet xrandr shows DP-1).
		# Disable both variants so the phantom is elided regardless of
		# which naming the driver exposes (universal, any GPU).
		if [ "$_x" != "$_o" ]; then
			DISABLED_OUTS="$DISABLED_OUTS $_o"
		fi
	fi
done
DISABLED_OUTS=$(echo "$DISABLED_OUTS" | sed 's/^ //')
DISABLED_MON_SECTIONS=""
for _o in $DISABLED_OUTS; do
	DISABLED_MON_SECTIONS+="$(printf '\nSection "Monitor"\n    Identifier  "%s"\n    Option "ignore" "true"\nEndSection' "$_o")"
done
if [ -n "$DISABLED_OUTS" ]; then
	echo "  -> disabled (no role): $DISABLED_OUTS"
fi

# ──────────────────────────────────────────────
# 99-crt.conf generation
# ──────────────────────────────────────────────

X11_CONF="${CRT_DUAL_CONF:-/etc/X11/xorg.conf.d/99-crt.conf}"
echo ""
echo "--- $X11_CONF ---"

if [ ! -f "$X11_CONF" ] || [ "${1:-}" = "--force" ]; then
	mkdir -p "$(dirname "$X11_CONF")"

	# TearFree policy for the non-NVIDIA Device section:
	#   amd  -> off  (official CRT Script v43: a shadow-FB blit path blocks
	#          direct KMS pageflips -> microstutter in MAME/RetroArch; the
	#          OutputClass 20-modesetting.conf enforces the same value)
	#   else -> on   (Intel verified with TearFree on, friend's UHD 630 box,
	#          2026-08-11 — stock pageflip path unaffected)
	if [ "$GPU_VENDOR" = "amd" ]; then
		TEARFREE="false"
	else
		TEARFREE="true"
	fi

	cat >"$X11_CONF" <<XEOF
# Generated by crt-x11-generator.sh — CRT-DUAL
# GPU: $GPU_VENDOR $GPU_MODEL
# $(date)

$CRT_MON_SECTIONS$LCD_MON_SECTIONS$DISABLED_MON_SECTIONS
Section "Device"
    Identifier  "GPU0"
XEOF

	# NVIDIA: vendor-specific config — must pin the proprietary driver.
	# Without an explicit Driver "nvidia", the OutputClass "nvidia"
	# (MatchDriver nvidia-drm) is not applied when an explicit Device
	# section exists, and X falls back to modesetting+nouveau (which
	# exposes HDMI-1/DVI-I-1 vs the nvidia driver's HDMI-0/DVI-I-0 and
	# fails pixmap creation in dual with both outputs at +0+0,
	# observed 2026-08-20 on GTX 970 dual: Failed to create pixmap).
	if [ "$GPU_VENDOR" = "nvidia" ]; then
		# ─────────────────────────────────────────────────────
		# NVIDIA startup layout — MetaModes + Modes request (verified on a
		# GTX 970: X's FIRST modeset = the final clone layout,
		# tube lit from birth). Built on CONFIRMED analogs AND presumed ANALOG
		# ports (2026-08-24): the presumed entry is what makes the 480i pool
		# modeline REACHABLE at a later hotplug (the Modes request advertises
		# it; without any CRT the names used to stay free for runtime
		# injection — an assumption disproven live, see the Monitor-section
		# comment above). Digital presumed candidates stay OUT: 480i over a
		# digital port is not a thing and MetaModes entries for absent digital
		# heads are pure phantom risk.
		#   - MetaModes defines the WHOLE layout at X start: CRT 640x480i
		#     primary +0+0; every LCD at its NATIVE mode with ViewPortIn=640x480
		#     (the panel runs native timing and scales our desktop — clone).
		#   - The Display-subsection Modes request is what ADVERTISES the pool
		#     modeline to RandR (unrequested conf modelines stay shadowed —
		#     NVIDIA README, Programming Modes).
		# ─────────────────────────────────────────────────────
		NVIDIA_SCREEN_EXTRAS=""
		_analog_presumed=""
		for _p in ${CRT_PRESUMED_OUTS:-}; do
			_output_is_analog "$_p" && _analog_presumed+=" $_p"
		done
		if [ -n "${CRT_OUTS:-}${_analog_presumed:-}" ]; then
			META=""
			# Presumed analogs stay in the MetaModes as INACTIVE heads
			# (disconnected at boot — X never lights them) because the
			# MetaModes is what makes the 480i modeline REACHABLE in the
			# RandR pool for the later CRT hotplug (verified 2026-08-24
			# GTX 970: without any CRT the pool stays empty and the
			# hotplug apply fails — and again 2026-08-28 when the
			# LCD-only gate dropped them: pool empty, CRT stayed dark,
			# watcher could not recover). LCD-only differs ONLY in the
			# LCD head: no ViewPortIn, the LCD IS the desktop at native
			# resolution (the 640x480 ViewPortIn was the "upscaled 480i"
			# flash seen at boot with es.resolution=auto, 2026-08-28).
			_crt_heads="${CRT_OUTS:-}"
			[ -z "$_crt_heads" ] && _crt_heads="${_analog_presumed:-}"
			for _c in ${_crt_heads:-}; do
				[ -n "$META" ] && META+=", "
				META+="$_c: 640x480i +0+0"
			done
			for _l in ${LCD_OUTS:-}; do
				_native=$(xrandr --current 2>/dev/null |
					sed -n "/^$_l connected/,/^[^ ]/p" |
					grep -E '\*' | head -1 | awk '{print $1}')
				[ -n "$META" ] && META+=", "
				if [ -n "$_native" ]; then
					if [ -n "${CRT_OUTS:-}" ]; then
						# clone: LCD panel runs native timing, scales the 480i desktop
						META+="$_l: $_native {ViewPortIn=640x480, ViewPortOut=$_native+0+0}"
					else
						# LCD-only: the LCD IS the desktop — native, unscaled
						META+="$_l: $_native"
					fi
				else
					if [ -n "${CRT_OUTS:-}" ]; then
						META+="$_l: nvidia-auto-select {ViewPortIn=640x480}"
					else
						META+="$_l: nvidia-auto-select"
					fi
				fi
			done
			# LCD-only: no confirmed CRT head exists — the presumed heads
			# are INACTIVE at boot (disconnected), the LCD is the desktop;
			# the Modes request below keeps the pool advertised.
			NVIDIA_SCREEN_EXTRAS=$(printf '    Option     "MetaModes" "%s"\n    SubSection "Display"\n        Modes "640x480i"\n    EndSubSection\n' "$META")
			echo "  NVIDIA MetaModes: $META"
		fi
		cat >>"$X11_CONF" <<XEOF
    Driver "nvidia"
$NVIDIA_MON_OPTS
    Option "RenderAccel"   "1"
    Option "ModeValidation" "NoVertRefreshCheck, NoHorizSyncCheck, NoMaxSizeCheck, NoMaxPClkCheck, NoVesaModes, NoXServerModes, AllowDpInterlaced, AllowNonEdidModes, NoPredefinedModes, NoExtendedGpuCapabilitiesCheck, NoDisplayPortBandwidthCheck, NoDualLinkDVICheck"
EndSection

Section "Screen"
    Identifier "Screen0"
    Device     "GPU0"
    Monitor    "$PRIMARY_MON"
    Option     "AllowIndirectGLXProtocol" "off"
    Option     "TripleBuffer" "on"
${NVIDIA_SCREEN_EXTRAS}
EndSection

Section "ServerFlags"
    Option "blank time" "0"
    Option "standby time" "0"
    Option "suspend time" "0"
    Option "off time" "0"
    Option "dpms" "false"
    Option "Xinerama" "0"
    Option "AllowEmptyInitialConfiguration" "true"
EndSection
XEOF
	else
		# AMD/Intel: generic config.
		# Screen Device MUST name the real Device Identifier ("GPU0"): the
		# old template carried a dangling device name (Xorg auto-resolved
		# it as "No device specified" -> first device) plus 7
		# ServerFlags-type options X IGNORES on a Screen (Xorg log
		# 2026-09-19: "Option ... is not used" x7). The effective config
		# is unchanged by this cleanup (audit 2026-09-19).
		cat >>"$X11_CONF" <<XEOF
    Driver "modesetting"
    Option "DRI" "3"
    Option "TearFree" "$TEARFREE"
    Option "AccelMethod" "glamor"
    Option "ModeValidation" "NoVesaModes, NoXServerModes, AllowNonEdidModes"
EndSection

Section "Screen"
    Identifier "Screen0"
    Device     "GPU0"
EndSection
XEOF
	fi

	echo "✅ $X11_CONF generated"
else
	echo "⏭️ $X11_CONF already exists (use --force to regenerate)"
fi

# FINAL structural VALIDATION (verified live: glued sections =
# Xorg parse error -> no screens found -> black screen). Only now the conf
# is complete (Device closed by the per-vendor block).
if [ -f "$X11_CONF" ]; then
	if grep -qE 'EndSection[[:space:]]*Section' "$X11_CONF"; then
		echo "❌ VALIDATION FAILED: glued sections (EndSectionSection) in $X11_CONF" >&2
		rm -f "$X11_CONF"
		exit 1
	fi
	if [ "$(grep -c '^Section ' "$X11_CONF")" != "$(grep -c '^EndSection' "$X11_CONF")" ]; then
		echo "❌ VALIDATION FAILED: unbalanced sections (Section=$(grep -c '^Section ' "$X11_CONF") EndSection=$(grep -c '^EndSection' "$X11_CONF")) in $X11_CONF" >&2
		rm -f "$X11_CONF"
		exit 1
	fi
	echo "  ✅ Structural validation: balanced conf, no glued sections"
fi

# ──────────────────────────────────────────────
# 99-crt.conf is REGENERATED, never persisted (design closed
# 2026-08-24): it is generated PRE-X at every boot by
# /etc/init.d/S15crt-dual-gen from current sysfs truth, and regenerated
# here unconditionally as self-correction. A persisted copy is either a
# useless cache (same hardware — regenerated anyway) or inherited POISON
# after a hardware change (wrong-driver conf kept X dead, verified live
# twice 2026-08-24).
# ──────────────────────────────────────────────

echo "  (regenerated at every boot from current truth — never persisted)"

# batocera.conf set-if-different via the stock tool (quiet; removals use
# sed -i because batocera-settings has no delete verb).
_bset() { [ "$(batocera-settings-get "$1" 2>/dev/null || true)" = "$2" ] || batocera-settings-set "$1" "$2" >/dev/null 2>&1 || true; }

# ──────────────────────────────────────────────
# Splash keys — FRESH pre-X state (single writer: this generator, via the
# S15 chain). S28splash reads global.videooutput + splash.screen.resize at
# S28 — BEFORE the boot service's late pass ever runs (boot.log
# 2026-08-30: S15 14:08:58 -> S28 14:08:59 -> S99 14:09:11), so the
# previous late-pass writer lagged one boot behind every topology change:
# a CRT-only boot removed the keys and the FIRST dual boot's splash fell
# to the stock first-connected fallback, whose mpv/DRM scan listed the
# EMPTY analog DVI-I-1 as connected (NVIDIA load-detection phantom on
# empty ports) — the splash rendered into the void (mpv "End of file"
# after 8.5s, nothing visible).
# LCD truth = DIGITAL connector with CONNECTED status: real HPD (immune to
# the NVIDIA analog load-detection that flaps "connected" on empty ports).
# NO EDID gate: on NVIDIA the sysfs edid file is ALWAYS 0 bytes (family
# fact — the EDID lives in xrandr --prop, unavailable pre-X); the sysfs
# modes file carries the EDID mode list all the same. No LCD (CRT-only) removes both keys — stock
# first-connected behavior (single-display boxes have one candidate; the
# tube splash is T21 scope). Written via the stock keys themselves
# (global.videooutput is Batocera's own splash/display steering).
# ──────────────────────────────────────────────
_splash_x=""; _splash_mode=""
for _d in /sys/class/drm/card*-*/; do
	[ -f "${_d}status" ] || continue
	[ "$(cat "${_d}status" 2>/dev/null)" = "connected" ] || continue
	_drm=$(basename "$_d" | sed 's/^card[0-9]*-//')
	_output_is_analog "$_drm" 2>/dev/null && continue
	_mode=$(head -1 "${_d}modes" 2>/dev/null)
	[ -n "$_mode" ] || continue
	_splash_x=$(_drm_to_x "$_drm" 2>/dev/null)
	_splash_mode=$_mode
	break
done
if [ -n "$_splash_x" ] && [ -n "$_splash_mode" ]; then
	_bset global.videooutput "$_splash_x"
	_bset splash.screen.resize "$_splash_mode"
	echo "  splash keys: videooutput=$_splash_x resize=$_splash_mode (fresh pre-X, LCD target)"
elif [ -n "$(batocera-settings-get global.videooutput 2>/dev/null || true)" ] || [ -n "$(batocera-settings-get splash.screen.resize 2>/dev/null || true)" ]; then
	sed -i '/^global\.videooutput=/d' /userdata/system/batocera.conf 2>/dev/null || true
	sed -i '/^splash\.screen\.resize=/d' /userdata/system/batocera.conf 2>/dev/null || true
	echo "  splash keys removed (no LCD — CRT-only: stock first-connected)"
fi

# ──────────────────────────────────────────────
# Second-screen opt-out — STATIC policy (single writer: this generator,
# pre-X, every boot — self-heals ES UI wipes like the splash keys above).
# Stock emulationstation-standalone auto-selects a second output for
# backglass whenever global.videooutput2 is empty AND != "none" (verified
# in the stock source: "If screen2 is empty, take the first one found").
# That extended right-of + backglass + per-screen 640x480i slam fights our
# clone on every hotplug (AMD trace 2026-09-03: 6 stock writes per replug,
# CRT parked outside the 640x480 framebuffer = black tube). "none" is
# stock's own opt-out value (the != "none" gate is theirs): with it the
# loop manages screen1 only and never touches our CRT — no rule masked,
# no binary touched, extend-don't-replace. FAMILY-GATED (2026-09-03 night):
# NVIDIA never wakes the checker on hotplug (no DRM uevents), so there
# `none` only removes 2 harmless boot writes while coinciding with boot
# glitches unseen in 3 months — NVIDIA keeps certified auto (key removed),
# AMD/Intel keep the opt-out. Uninstall restores pre-install.
# ──────────────────────────────────────────────
if [ "${GPU_VENDOR:-}" = "nvidia" ]; then
	if [ -n "$(batocera-settings-get global.videooutput2 2>/dev/null || true)" ]; then
		sed -i '/^global\.videooutput2=/d' /userdata/system/batocera.conf 2>/dev/null || true
		echo "  second-screen policy: nvidia keeps stock auto (key removed)"
	fi
else
	_bset global.videooutput2 none
	echo "  second-screen policy: global.videooutput2=none (stock manages screen1 only)"
fi

echo "=== COMPLETED ==="
echo "killall X (or reboot) to apply."
