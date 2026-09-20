#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
# Copyright (C) 2026 FreZeeN
# Part of crt-dual — https://github.com/frezeen
# gpu-lib.sh — CRT-DUAL GPU Detection Library
# Single source for GPU detection, dotclock, Xorg config
# Source: source /path/to/gpu-lib.sh
#
# Exported variables:
#   GPU_VENDOR    — nvidia|amd|intel|unknown
#   GPU_MODEL     — GPU model string
#
# Shell contract: safe under `set -u` and `set -o pipefail`; the caller
# enables those options (the hooks/service do).

# One lspci line per process — NEVER inside a per-output loop
# (GPU detection is a one-time, sourced lib call).
_gpu_line() {
	lspci -nn 2>/dev/null | grep -iE "VGA|3D|Display controller" | head -1
}

# GPU model string from the lspci line (detect_gpu's model field).
_gpu_model() {
	echo "$1" | sed 's/.*controller //' | sed 's/\[[^]]*\]//g' | xargs
}

detect_gpu() {
	local gpu_line
	gpu_line=$(_gpu_line)

	GPU_MODEL=$(_gpu_model "$gpu_line")
	[ -z "$GPU_MODEL" ] && GPU_MODEL=$(echo "$gpu_line" | awk -F'[][]' '{print $(NF-1)}')

	if echo "$gpu_line" | grep -qi "NVIDIA"; then
		GPU_VENDOR="nvidia"
	# \b word-boundary: "ATI" is a substring of "Intel CorporatiON" —
	# without the boundary every Intel GPU was classified as amd (live bug:
	# Intel UHD 630 HP 800 G5 detected as amd, diag 2026-08-09).
	elif echo "$gpu_line" | grep -qiE "\b(AMD|ATI)\b"; then
		GPU_VENDOR="amd"
	elif echo "$gpu_line" | grep -qi "Intel"; then
		GPU_VENDOR="intel"
	else
		GPU_VENDOR="unknown"
	fi
}

# RGS-15KHZ-EXT (dotclock, 2026-09-20): check_dotclock REMOVED — the
# GPU-class whitelist (Maxwell regex + /etc/ati0dot.txt) is deleted with
# the ati0dot list. The floor is MEASURED at boot (the S30z hook,
# KMS-native: mode set + WAIT_VBLANK) and written into both switchres
# inis fresh every boot; the manual knob (rgs-15khz.dotclock_min) wins.
# ONE truth source, no tables (owner order).

# Correct X name from DRM name (e.g. DVI-I-1 -> DVI-I-0)
# REMOVED 2026-08-12 (audit finding M2): zero callers — the DRM->X
# mapping now lives in display-lib.sh _drm_to_x (single source, both
# directions). Kept out so the two mappings cannot diverge.

get_xorg_configs() {
	# Generates the appropriate Xorg.conf.d files for the detected GPU.
	# X11_CONF_DIR is a test seam (tests/run.sh redirects it to a temp
	# dir); the live path is /etc/X11/xorg.conf.d.
	local X11_CONF_DIR="${X11_CONF_DIR:-/etc/X11/xorg.conf.d}"
	mkdir -p "$X11_CONF_DIR"

	case "$GPU_VENDOR" in
	nvidia)
		# NVIDIA handled by crt-x11-generator.sh (99-crt.conf)
		;;
	amd)
		# Batocera 43.1 ships NO amdgpu xorg DDX — verified 2026-08-11 on
		# the AMD R9 270X box: /overlay/base/usr/lib/xorg/modules/drivers/
		# holds only ati, modesetting, nouveau, nvidia*, radeon. The stock
		# 20-amdgpu.conf OutputClass (MatchDriver amdgpu -> Driver "amdgpu")
		# therefore kills X on ANY AMD card: "Failed to load module amdgpu
		# ... no screens found" (Xorg.0.log, same box).
		# Mirror the official CRT Script v43 (lines 4664-4686): back up +
		# remove the stock AMD OutputClasses and force the modesetting DDX
		# for both kernel drivers (amdgpu and radeon). TearFree/VRR stay
		# OFF (official v43 rationale: a shadow-framebuffer blit path would
		# block direct KMS pageflips and cause microstutter in MAME/RA).
		for _stock in 20-amdgpu.conf 20-radeon.conf; do
			_driver="${_stock#20-}"
			_driver="${_driver%.conf}" # 20-amdgpu.conf -> amdgpu
			# Content guard (update-hardening 2026-08-12): neutralize ONLY a
			# file that IS the stock AMD OutputClass (Section "OutputClass" +
			# MatchDriver <driver>). A future Batocera reusing the filename
			# with a different meaning is LEFT UNTOUCHED — the new stock
			# infrastructure stays intact for fixing, and the box keeps the
			# new behavior (a warning is logged instead of a deletion).
			if [ -f "$X11_CONF_DIR/$_stock" ]; then
				if grep -q 'Section "OutputClass"' "$X11_CONF_DIR/$_stock" &&
					grep -q "MatchDriver \"$_driver\"" "$X11_CONF_DIR/$_stock"; then
					if [ ! -f "$X11_CONF_DIR/$_stock.bak" ]; then
						cp -a "$X11_CONF_DIR/$_stock" "$X11_CONF_DIR/$_stock.bak"
					fi
					rm -f "$X11_CONF_DIR/$_stock"
				else
					echo "  get_xorg_configs: $X11_CONF_DIR/$_stock is not the stock AMD OutputClass (new Batocera?) — LEFT UNTOUCHED" >&2
				fi
			fi
		done
		cat >"$X11_CONF_DIR/20-modesetting.conf" <<'XEOF'
Section "OutputClass"
    Identifier "AMD via modesetting (amdgpu)"
    MatchDriver "amdgpu"
    Driver "modesetting"
    Option "TearFree" "false"
    Option "VariableRefresh" "false"
EndSection
Section "OutputClass"
    Identifier "AMD via modesetting (radeon)"
    MatchDriver "radeon"
    Driver "modesetting"
    Option "TearFree" "false"
EndSection
XEOF
		;;
	intel | unknown)
		cat >"$X11_CONF_DIR/20-modesetting.conf" <<'XEOF'
Section "OutputClass"
    Identifier "Generic modesetting"
    Driver "modesetting"
    Option "TearFree" "false"
    Option "VariableRefresh" "false"
EndSection
XEOF
		;;
	esac
}
