#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
# Copyright (C) 2026 FreZeeN
# Part of crt-dual — https://github.com/frezeen
# display-detect.sh — dynamic topology discovery (ADR-002), universal.
#
# The kernel's contracts are the only input (identical on AMD/Intel/NVIDIA):
#   connected + readable EDID (>0 bytes):
#     - fabricated block (converter template; _edid_is_synthetic) -> ANALOG
#     - declares sub-25 kHz timing or range (_edid_sub25khz)      -> ANALOG
#       (a 15 kHz display's own block: a DDC CRT/TV, or one passed
#       through a converter — the converter may rewrite the input byte,
#       so 15 kHz CAPABILITY, not the byte, decides)
#     - otherwise                                                 -> PANEL
#       (a real display's own block: a panel, or one passed through a
#       converter — the converter forwards the display's identity)
#   connected + no EDID                   -> ANALOG (CRT over a DAC / no DDC)
#   disconnected                          -> candidate by connector type
# The DPCD branch block (DPCD 0x0005 downstream type, _dpcd_branch_analog)
# marks a port analog-CAPABLE (a converter to Analog VGA); it never
# overrides a readable display EDID — it is the hook for the user
# declaration and for the disconnected fallback.
#
# Declarations (crt-dual.crt_output / crt-dual.analog_lcd) disambiguate
# only where evidence cannot; _decl_guard suspends a declaration that
# contradicts live evidence, loudly (rule live-evidence).
#
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
_SUSPEND_CRT=""
_SUSPEND_LCD=""
_GUARD_DONE=""

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

_knob() { # $1 = batocera.conf key -> LAST occurrence value (settings APPEND), trimmed
	local conf="${CRT_DUAL_BATOCERA_CONF:-/userdata/system/batocera.conf}"
	[ -r "$conf" ] || return 1
	local v
	v=$(sed -n "s/^$1[[:space:]]*=[[:space:]]*//p" "$conf" 2>/dev/null | tail -1 | tr -d ' "[:space:]')
	[ -n "$v" ] && printf '%s\n' "$v"
}

_raw_crt_declared() { # $1 = DRM name: user declaration crt-dual.crt_output (DRM or X name)
	local v
	v=$(_knob 'crt-dual\.crt_output') || return 1
	[ "$v" = "$1" ] && return 0
	[ "$v" = "$(_pure_x_name "$1")" ] && return 0
	return 1
}

_raw_lcd_declared() { # $1 = DRM name -> 0 when the user declared this port
	# (or all of them) as carrying an LCD; no guard applied:
	#   crt-dual.analog_lcd=1          -> every analog-capable port
	#   crt-dual.analog_lcd=DP-1,DP-2  -> those ports only
	# WHY a list: behind a converter that fabricates its own EDID nothing
	# in the kernel says what sits behind it — only the user can.
	local v
	v=$(_knob 'crt-dual\.analog_lcd') || return 1
	[ "$v" = "1" ] && return 0
	case ",$v," in
	*",$1,"*) return 0 ;;
	*",$(_pure_x_name "$1"),"*) return 0 ;;
	esac
	return 1
}

_declared_crt_matches() { # guard-aware: a suspended declaration does not match
	case " $_SUSPEND_CRT " in *" $1 "*) return 1 ;; esac
	_raw_crt_declared "$1"
}

_analog_lcd_declared() { # guard-aware: a suspended declaration does not match
	case " $_SUSPEND_LCD " in *" $1 "*) return 1 ;; esac
	_raw_lcd_declared "$1"
}

_decl_warn() { # $* = message -> stderr + the module log (dedup; report-bundled)
	local msg="display-detect: $*" log
	printf '%s\n' "$msg" >&2
	log="${CRT_DUAL_LOG:-/userdata/system/logs/display-detect.log}"
	if ! grep -qF "$*" "$log" 2>/dev/null; then
		# best-effort: a read-only call site must never fail on the log write
		printf 'display-detect [%s]: %s\n' "$(date +%FT%T)" "$*" >>"$log" 2>/dev/null || true
	fi
}

_evidence_class() { # $1 drm, $2 edid, $3 status -> class with declarations ignored
	_CLASSIFY_EVIDENCE_ONLY=1 _classify "$1" "$2" "$3"
}

_decl_guard() { # one-time: suspend declarations contradicted by live evidence
	# Rule live-evidence §3. A declaration written for one topology must
	# never steer another silently: the declared LCD port that live
	# evidence reads as no-panel while ANOTHER connected port presents a
	# real panel block (or a declared CRT port whose block is a real
	# panel) is a contradiction — warn loud, suspend, evidence wins.
	[ -z "$_GUARD_DONE" ] || return 0
	_GUARD_DONE=1
	local f st drm edid cls rows="" panels="" analogs=""
	for f in "$ENV_SYSFS"/card*-*/status; do
		[ -f "$f" ] || continue
		st=$(cat "$f" 2>/dev/null)
		[ "$st" = "connected" ] || continue
		drm=$(basename "$(dirname "$f")")
		drm=${drm#card*-}
		edid="${f%/status}/edid"
		cls=$(_evidence_class "$drm" "$edid" "$st")
		rows="$rows$drm|$cls|$edid"$'\n'
		[ "$cls" = "panel" ] && panels="$panels $drm"
		[ "$cls" = "analog" ] && analogs="$analogs $drm"
	done
	local d c e
	while IFS='|' read -r d c e; do
		[ -n "$d" ] || continue
		if _raw_lcd_declared "$d" && [ "$c" = "analog" ] && [ -n "$panels" ]; then
			_SUSPEND_LCD="$_SUSPEND_LCD $d"
			_decl_warn "crt-dual.analog_lcd names $d as a panel, but live evidence reads $d as no-panel while$panels presents a real panel block — declaration suspended, evidence wins (update batocera.conf if the cabling changed)"
		fi
		if _raw_crt_declared "$d" && [ "$c" = "panel" ] && [ -n "$analogs" ]; then
			# suspension only when the tube is demonstrably elsewhere (a
			# converter/no-EDID candidate exists): a panel-looking block
			# on the declared tube port with NO other analog candidate is
			# the residual the knob exists for (a converter whose fake is
			# indistinguishable from a real panel) — honored silently
			_SUSPEND_CRT="$_SUSPEND_CRT $d"
			_decl_warn "crt-dual.crt_output names $d as the tube, but its live EDID is a real panel block while$analogs reads as the converter/no-EDID class — declaration suspended, evidence wins (update batocera.conf if the cabling changed)"
		fi
	done <<<"$rows"
}

_classify() { # $1 = DRM connector, $2 = EDID path, $3 = status -> analog|panel
	# User declarations win (the documented knobs, LAST occurrence), but
	# only when _decl_guard has not suspended them (contradicted by live
	# evidence — rule live-evidence §3):
	#   crt-dual.crt_output=<port>  -> that port is a confirmed CRT
	#   crt-dual.analog_lcd=1|<list> -> analog ports (or the listed ones)
	#                                  carry an LCD
	if [ -z "${_CLASSIFY_EVIDENCE_ONLY:-}" ]; then
		_declared_crt_matches "$1" && { echo analog; return 0; }
		if _analog_capable "$1" && _analog_lcd_declared "$1"; then
			echo panel
			return 0
		fi
	fi
	# Evidence (the kernel's contracts; a converter may forward the real
	# display's block or fabricate its own — the block's CONTENT decides):
	#   fabricated (no name/range, no extension, size lie) -> nothing to
	#       describe behind the converter -> the no-DDC class (a tube);
	#   15 kHz capability declared (timing or range < 25 kHz) -> a 15 kHz
	#       display's own block, whatever the input byte says (the
	#       converter rewrites it: the live PHL pass-through reads digital);
	#   otherwise -> a real display's own block -> the panel path.
	if [ "$(_edid_bytes "$2")" -gt 0 ]; then
		if _edid_is_synthetic "$2"; then
			echo analog
		elif _edid_sub25khz "$2"; then
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
	_decl_guard
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
	_decl_guard
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
