#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
# Copyright (C) 2026 FreZeeN
# Part of crt-dual — https://github.com/frezeen
# display-detect.sh — dynamic topology discovery (ADR-002), universal.
#
# The kernel's contracts are the only input (identical on AMD/Intel/NVIDIA):
#   connected + readable EDID (>0 bytes)  -> PANEL (digital, DDC present)
#   connected + synthetic EDID            -> ANALOG (CRT behind a converter
#       that fabricates its own EDID — the active DP>VGA adapter class;
#       see _edid_is_synthetic)
#   connected + ANALOG-input EDID that declares sub-25 kHz timing or range
#                                         -> ANALOG (a real VGA display's
#       own block: a DDC-capable CRT/TV, or one passed through a converter)
#   connected + digital-input EDID + DPCD branch "Analog VGA" -> ANALOG
#       (the block cannot belong to a display behind an analog output:
#       it is the adapter's fabrication — DPCD 0x0005 downstream port
#       type, read via the DRM aux chardev; _dpcd_branch_analog)
#   connected + no EDID                   -> ANALOG (CRT over a DAC / no DDC)
# No connector name, resolution or machine fact is hardcoded. The X output
# name is derived by matching the DRM name against `xrandr --current`
# (X drops the [A-Z] slot: HDMI-A-1 -> HDMI-1); the exact name is tried
# first, so DP-1/DVI-I-1/VGA-1 map to themselves with the same rule.
#
# Usage:
#   display-detect.sh --check   topology line (requires X): crt=<X> lcd=<X> state=<dual|crt|lcd|none>
#   display-detect.sh --list    one line per CONNECTED connector:
#                               <drm-name>\t<analog|panel>\t<x-name-or-empty>
# Policy: one analog and one panel are kept (first in sysfs order);
# extra panels are reported by --list and ignored by --check.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_SYSFS="${CRT_DUAL_SYSFS:-/sys/class/drm}"
ENV_DISPLAY="${DISPLAY:-:0}"
_XOUT=""
_GPU_OFF=""

_x_outputs() { # cached xrandr --current (zero writes, R class)
	if [ -z "$_XOUT" ]; then
		_XOUT=$(timeout 5 env DISPLAY="$ENV_DISPLAY" xrandr --current 2>/dev/null) || _XOUT=""
	fi
	printf '%s\n' "$_XOUT"
}

_x_name_of() { # $1 = DRM connector -> X output name (no per-machine table)
	local drm="$1" cand
	for cand in "$drm" "$(_pure_x_name "$drm")"; do
		if _x_outputs | awk -v o="$cand" '$1 == o { found = 1 } END { exit !found }'; then
			printf '%s\n' "$cand"
			return 0
		fi
	done
	return 1
}

_edid_bytes() { # sysfs attribute: st_size is 0 while the payload is readable
	wc -c <"$1" 2>/dev/null | tr -d ' ' || echo 0
}

_edid_is_synthetic() { # $1 = EDID file -> 0 = fabricated sink block (the
	# converter/dongle class), 1 = real display or not clearly synthetic
	# (conservative: stays panel). THREE independent signals must ALL hold
	# (ADR-002 §Known gaps; live RTK7450 DP>VGA adapter on the Intel box,
	# 2026-09-20 — the real-panel fixture fails two of them):
	#   1. no 0xFC (monitor name) and no 0xFD (range limits) descriptor in
	#      the base block — every real display names itself;
	#   2. no extension block (byte 0x7E = 0) — real HDMI/DP displays ship
	#      a CTA-861 extension;
	#   3. the base image size (cm) contradicts the first DTD's (mm) by
	#      more than 2x on BOTH axes — a real display reports its own size
	#      twice, consistently.
	local f="$1"
	local -a b
	read -r -a b <<<"$(od -An -tu1 -v "$f" 2>/dev/null | tr '\n' ' ')"
	[ "${#b[@]}" -ge 128 ] || return 1
	[ "${b[126]}" = "0" ] || return 1
	# Descriptor slots: a display descriptor is 00 00 00 <tag> 00 (tag at
	# +3), a DTD has a nonzero pixel clock in bytes 0-1, all-zero is
	# padding. The first version checked byte 0 (and then +2) — both missed
	# EVERY real name/range descriptor; fixed 2026-09-20 against the real
	# panel fixture (PHL 274E5: DTD serial name range).
	local off t
	for off in 54 72 90 108; do
		if [ "${b[off]}" = "0" ] && [ "${b[off + 1]}" = "0" ] && [ "${b[off + 2]}" = "0" ]; then
			t="${b[off + 3]}"
			if [ "$t" = "252" ] || [ "$t" = "253" ]; then return 1; fi
		fi
	done
	local bh="${b[21]}" bv="${b[22]}" dh dv
	dh=$((b[66] | ((b[68] >> 4) << 8)))
	dv=$((b[67] | ((b[68] & 15) << 8)))
	[ "$bh" -gt 0 ] && [ "$bv" -gt 0 ] && [ "$dh" -gt 0 ] && [ "$dv" -gt 0 ] || return 1
	local mh=$((bh * 10)) mv=$((bv * 10))
	[ "$mh" -gt $((2 * dh)) ] || [ "$dh" -gt $((2 * mh)) ] || return 1
	[ "$mv" -gt $((2 * dv)) ] || [ "$dv" -gt $((2 * mv)) ] || return 1
	return 0
}

_edid_input_analog() { # $1 = EDID file -> 0 when byte 0x14 says ANALOG input
	# (bit 7 clear). A real digital display can never report this: on a
	# digital port an analog-input EDID is a VGA display's own block,
	# passed through a converter (or a DDC-capable CRT on an analog port).
	local v
	v=$(od -An -tu1 -j 20 -N 1 -v "$1" 2>/dev/null | tr -d ' ')
	[ -n "$v" ] && [ $(( v & 0x80 )) -eq 0 ]
}

_edid_sub25khz() { # $1 = EDID file -> 0 when the EDID declares a sub-25 kHz
	# timing or a range whose minimum is below 25 kHz. No LCD panel is
	# driven at 15 kHz: this is the 15 kHz CAPABILITY fact (the engine's
	# desktop criterion), not a CRT/LCD taxonomy — a 31 kHz CRT declares
	# neither and is served by the panel path like an LCD. Scans the base
	# block + the CTA extension's DTD/descriptor area.
	local f="$1"
	local -a b
	read -r -a b <<<"$(od -An -tu1 -v "$f" 2>/dev/null | tr '\n' ' ')"
	[ "${#b[@]}" -ge 128 ] || return 1
	local offs="54 72 90 108" o clk ha hb ht
	if [ "${b[126]:-0}" -gt 0 ] && [ "${#b[@]}" -ge 256 ]; then
		o=$(( 128 + ${b[130]:-0} ))
		while [ "$o" -le 236 ]; do
			offs="$offs $o"
			o=$((o + 18))
		done
	fi
	for o in $offs; do
		if [ "${b[o]:-x}" = "0" ] && [ "${b[o + 1]:-x}" = "0" ] && [ "${b[o + 2]:-x}" = "0" ]; then
			# display descriptor: range limits with min hsync < 25 kHz?
			[ "${b[o + 3]:-0}" = "253" ] && [ "${b[o + 7]:-99}" -lt 25 ] && return 0
			continue
		fi
		clk=$(( ${b[o]:-0} | (${b[o + 1]:-0} << 8) ))
		[ "$clk" -gt 0 ] || continue
		ha=$(( ${b[o + 2]:-0} | ((${b[o + 4]:-0} >> 4) << 8) ))
		hb=$(( ${b[o + 3]:-0} | ((${b[o + 4]:-0} & 15) << 8) ))
		ht=$(( ha + hb ))
		[ "$ht" -gt 0 ] && [ $(( clk * 10 / ht )) -lt 25 ] && return 0
	done
	return 1
}

_dpcd_branch_analog() { # $1 = DRM connector -> 0 when the DPCD branch block
	# says the sink is a protocol converter to Analog VGA: DPCD 0x0005
	# bit0 = downstream port present, bits 2:1 = 01 Analog VGA. Read
	# through the DRM aux chardev (offset = register, dd = pread). Any
	# absence or failure falls through (NVIDIA: no chardev; a real
	# monitor: no branch device; a DP hub: type DisplayPort -> panel).
	local dir="$ENV_SYSFS/card0-$1" a node b
	node=""
	for a in "$dir"/drm_dp_aux*; do
		[ -e "$a" ] || continue
		node="${CRT_DUAL_AUX_DIR:-/dev}/$(basename "$a")"
		break
	done
	[ -n "$node" ] && [ -r "$node" ] || return 1
	b=$(timeout 2 dd if="$node" bs=1 skip=5 count=1 2>/dev/null | od -An -tu1 2>/dev/null | tr -d ' ')
	[ -n "$b" ] || return 1
	[ $(( b & 1 )) -eq 1 ] && [ $(( (b >> 1) & 3 )) -eq 1 ]
}

_analog_capable() { # kernel connector-type token in the DRM name (universal)
	case "$1" in
	VGA-* | DVI-I-* | DVI-A-*) return 0 ;;
	esac
	# A digital port whose sink is a protocol converter to Analog VGA
	# (DPCD 0x0005 branch, RTD2166 class) is analog-capable in the same
	# sense: its fabricated EDID hides what really sits behind it, so the
	# user declaration below must be able to reach it (2026-09-20).
	_dpcd_branch_analog "$1" && return 0
	return 1
}

_analog_lcd_declared() { # $1 = DRM name -> 0 when the user declared this
	# port (or all of them) as carrying an LCD:
	#   crt-dual.analog_lcd=1          -> every analog-capable port
	#   crt-dual.analog_lcd=DP-1,DP-2  -> those ports only
	# WHY a list: behind a VGA converter the adapter's fabricated EDID is
	# identical for a CRT and for a panel — only the user can say which.
	local v
	v=$(_knob 'crt-dual\.analog_lcd') || return 1
	[ "$v" = "1" ] && return 0
	case ",$v," in
	*",$1,"*) return 0 ;;
	*",$(_pure_x_name "$1"),"*) return 0 ;;
	esac
	return 1
}

_knob() { # $1 = batocera.conf key -> LAST occurrence value (settings APPEND), trimmed
	local conf="${CRT_DUAL_BATOCERA_CONF:-/userdata/system/batocera.conf}"
	[ -r "$conf" ] || return 1
	local v
	v=$(sed -n "s/^$1[[:space:]]*=[[:space:]]*//p" "$conf" 2>/dev/null | tail -1 | tr -d ' "[:space:]')
	[ -n "$v" ] && printf '%s\n' "$v"
}

_declared_crt_matches() { # $1 = DRM name: user declaration crt-dual.crt_output (DRM or X name)
	local v
	v=$(_knob 'crt-dual\.crt_output') || return 1
	[ "$v" = "$1" ] && return 0
	[ "$v" = "$(_pure_x_name "$1")" ] && return 0
	return 1
}

_classify() { # $1 = DRM connector, $2 = EDID path, $3 = status -> analog|panel
	# User declarations win (the documented knobs, LAST occurrence):
	#   crt-dual.crt_output=<port>  -> that port is a confirmed CRT
	#   crt-dual.analog_lcd=1|<list> -> analog ports (or the listed ones)
	#                                  carry an LCD
	_declared_crt_matches "$1" && { echo analog; return 0; }
	if _analog_capable "$1" && _analog_lcd_declared "$1"; then
		echo panel
		return 0
	fi
	# Definitive (the adapter declares itself): the sink's DPCD branch
	# block says it is a protocol converter to Analog VGA. It is used as
	# PROOF OF FABRICATION below (a digital-input EDID cannot belong to a
	# display behind an analog output); an analog-input EDID is the real
	# display's own block and is judged by its content instead.
	# (2026-09-20, live RTD2166-class adapter.)
	# Convention (incident-decided): a readable EDID means a monitor with
	# DDC -> panel, UNLESS the EDID is fabricated (converter class) -> CRT
	# candidate, or it is a real VGA display's own block (ANALOG input)
	# that declares sub-25 kHz capability -> CRT candidate; NO EDID on a
	# connected port means a CRT candidate on ANY type (a converter/VGA
	# CRT on DP++ is real — Intel UHD 630); a disconnected port is a
	# candidate only when its type is analog-capable (the presumed analog).
	if [ "$(_edid_bytes "$2")" -gt 0 ]; then
		if _edid_is_synthetic "$2"; then
			# fabricated block (no name/range, no extension, size lie)
			echo analog
		elif _edid_input_analog "$2"; then
			# the VGA display's OWN block (pass-through adapter, or a
			# DDC-capable display on an analog port): 15 kHz capability
			# decides — a VGA LCD or a 31 kHz+ CRT keeps the panel path
			if _edid_sub25khz "$2"; then
				echo analog
			else
				echo panel
			fi
		elif [ "$3" = "connected" ] && _dpcd_branch_analog "$1"; then
			# digital-input EDID on a port whose DPCD branch says the
			# output is Analog VGA: a VGA display cannot report a digital
			# input, so this block is the ADAPTER's fabrication -> the
			# no-DDC class (a tube in practice)
			echo analog
		else
			echo panel
		fi
		return 0
	fi
	if [ "$3" = "connected" ]; then
		echo analog
		return 0
	fi
	_analog_capable "$1" && echo analog || echo panel
}

_gpu_offset() { # DRM index vs X index (family fact: NVIDIA -1, others identity), cached
	local v off
	if [ -n "$_GPU_OFF" ]; then
		printf '%s\n' "$_GPU_OFF"
		return 0
	fi
	v="${GPU_VENDOR:-}"
	if [ -z "$v" ] && [ -r "$HERE/../lib/gpu-lib.sh" ]; then
		# shellcheck disable=SC1090
		. "$HERE/../lib/gpu-lib.sh" 2>/dev/null
		command -v detect_gpu >/dev/null 2>&1 && detect_gpu 2>/dev/null
		v="${GPU_VENDOR:-}"
	fi
	case "$v" in
	nvidia) off=1 ;;
	*) off=0 ;;
	esac
	_GPU_OFF="$off"
	printf '%s\n' "$off"
}

_pure_x_name() { # DRM name -> X name by the naming rule (pre-X safe)
	local drm="$1" type idx
	case "$drm" in
	HDMI-A-*)
		type="HDMI"
		idx="${drm#HDMI-A-}"
		;;
	*)
		type="${drm%-*}"
		idx="${drm##*-}"
		;;
	esac
	printf '%s-%s\n' "$type" "$((idx - $(_gpu_offset)))"
}

detect_connectors() { # connected connectors only, deterministic order
	local f st drm cls x
	for f in "$ENV_SYSFS"/card*-*/status; do
		[ -f "$f" ] || continue
		st=$(cat "$f" 2>/dev/null)
		[ "$st" = "connected" ] || continue
		drm=$(basename "$(dirname "$f")")
		drm=${drm#card*-}
		cls=$(_classify "$drm" "${f%/status}/edid" "$st")
		x=$(_x_name_of "$drm") || x=""
		printf '%s\t%s\t%s\n' "$drm" "$cls" "$x"
	done | sort
}

detect_all_connectors() { # every connector: drm, class, status, edid-bytes, X name (pure rule pre-X)
	local f st drm cls edid x
	for f in "$ENV_SYSFS"/card*-*/status; do
		[ -f "$f" ] || continue
		st=$(cat "$f" 2>/dev/null)
		drm=$(basename "$(dirname "$f")")
		drm=${drm#card*-}
		edid=$(_edid_bytes "${f%/status}/edid")
		cls=$(_classify "$drm" "${f%/status}/edid" "$st")
		x=$(_x_name_of "$drm") || x=$(_pure_x_name "$drm")
		printf '%s\t%s\t%s\t%s\t%s\n' "$drm" "$cls" "$st" "$edid" "$x"
	done | sort
}

detect_state() { # canonical topology line; fails loud when X cannot confirm a name
	local crt="" lcd="" d c x bad=0
	local rows
	rows=$(detect_connectors)
	if [ -z "$rows" ]; then
		printf 'crt= lcd= state=none\n'
		return 0
	fi
	while IFS=$'\t' read -r d c x; do
		[ -n "$d" ] || continue
		if [ -z "$x" ]; then
			echo "display-detect: connected connector '$d' has no X output (X down or not listed)" >&2
			bad=1
			continue
		fi
		case "$c" in
		analog) [ -z "$crt" ] && crt="$x" ;;
		panel) [ -z "$lcd" ] && lcd="$x" ;;
		esac
	done <<<"$rows"
	[ "$bad" = "0" ] || return 1
	local state=none
	if [ -n "$crt" ] && [ -n "$lcd" ]; then state=dual
	elif [ -n "$crt" ]; then state=crt
	elif [ -n "$lcd" ]; then state=lcd
	fi
	printf 'crt=%s lcd=%s state=%s\n' "$crt" "$lcd" "$state"
}

case "${1:---check}" in
--check) detect_state ;;
--list) detect_connectors ;;
--all) detect_all_connectors ;;
*) echo "usage: display-detect.sh [--check|--list|--all]" >&2; exit 2 ;;
esac
