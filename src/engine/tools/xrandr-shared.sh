#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
# Copyright (C) 2026 FreZeeN
# Part of crt-dual — https://github.com/frezeen
# xrandr-shared.sh — translation core shared by BOTH xrandr wrappers
# (prod src/tools/xrandr-wrapper.sh + diag src/tools/display-trace.sh).
#
# ONE source of truth for the batocera-patched option replies and the
# desktop-name rewrite (unified 2026-08-28: the 5-case _TRANS block was
# byte-identical in both wrappers; divergence would make trace-on-AMD
# unfaithful to prod). The wrappers source this file at runtime from the
# package path; if it is missing they degrade to plain stock passthrough
# (never a broken /usr/bin/xrandr).
#
# Pure functions, no side effects, no globals beyond the functions:
#   _xrandr_trans_name "$*"          -> echo the translation name ("" = none)
#   _xrandr_trans_reply <name> <cached-current-output> <out-arg>
#                                    -> echo the emulated reply
#   _xrandr_desktop_rewrite "$@"     -> echo rewritten args (one per line)
#                                       when the C-contract rewrite applies,
#                                       exit 0; empty + exit 1 = no match
#
# NOT shared (by design): the G-family -> --current translation stays
# prod-only — the trace wrapper must SEE the original --query calls to
# log the glitch source.

# _xrandr_is_amd — family gate shared by BOTH wrappers (cached: lspci once
# per boot, then /tmp file; per-call lspci would add ~5ms ×45 at boot).
# DISPLAY-CLASS RESTRICTED: matching the bare vendor token across ALL of
# lspci fooled the gate on an AMD-chipset board (verified 2026-08-28 GTX
# 970 on Threadripper: "AMD Starship/Matisse" chipset lines matched and
# the wrapper activated on NVIDIA, killing the hotplug heartbeat). Same
# rule as gpu-lib.sh _gpu_line: ask only the GPU, never the chipset.
_xrandr_is_amd() {
	local _a
	if [ -f /tmp/crt-dual/gpu-is-amd ]; then
		cat /tmp/crt-dual/gpu-is-amd 2>/dev/null || echo 0
		return 0
	fi
	# Class pattern mirrors gpu-lib _gpu_line EXACTLY ("VGA|3D|Display
	# controller"): the word-boundary form "\b(vga|3d|display) controller\b"
	# required "vga controller" ADJACENT and never matched the standard
	# "VGA compatible controller" class string -> the gate returned 0 on a
	# real AMD GPU -> the wrapper silently became stock (every glitch storm
	# since 2026-08-28; exposed by the owner's A/B prod-vs-trace boots
	# 2026-08-31). The class filter still excludes chipset lines (the
	# Threadripper protection holds: "Starship/Matisse" is a Host bridge
	# line, not a VGA/3D/Display controller).
	if lspci 2>/dev/null | grep -iE "VGA|3D|Display controller" | grep -qiE "\b(AMD|ATI)\b"; then _a=1; else _a=0; fi
	mkdir -p /tmp/crt-dual 2>/dev/null || true
	printf '%s' "$_a" > /tmp/crt-dual/gpu-is-amd 2>/dev/null || true
	echo "$_a"
}

# _xrandr_trans_name <args...> — name of the batocera-patched option.
_xrandr_trans_name() {
	case " $* " in
	*"--listConnectedOutputs"*) echo listConnected ;;
	*"--currentResolution"*) echo currentResolution ;;
	*"--currentRotation"*) echo currentRotation ;;
	*"--listModes"*) echo listModes ;;
	*"--listPrimary"*) echo listPrimary ;;
	*) echo "" ;;
	esac
}

# _xrandr_trans_reply <name> <cached-current-output> <out-arg> — emit the
# reply the stock binary would produce, from a cached --current snapshot
# (no re-probe, glitch-free on AMD dce_v6).
_xrandr_trans_reply() {
	local _t="$1" _cur="$2" _out="$3" _rot
	case "$_t" in
	listPrimary) printf '%s\n' "$_cur" | sed -n '/ connected primary /p' | head -1 | awk '{print $1}' ;;
	listConnected) printf '%s\n' "$_cur" | sed -n '/ connected /p' | awk '{print $1"*"}' ;;
	currentResolution) printf '%s\n' "$_cur" | sed -n "/^$_out connected/p" | grep -oE '[0-9]+x[0-9]+' | head -1 ;;
	currentRotation) _rot=$(printf '%s\n' "$_cur" | sed -n "/^$_out connected/p" | grep -oE '\([a-z]+' | tr -d '(' | head -1); case "$_rot" in left) echo 1;; inverted) echo 2;; right) echo 3;; *) echo 0;; esac ;;
	listModes) printf '%s\n' "$_cur" | sed -n "/^$_out connected/,/^[A-Za-z0-9]/p" | grep -E '^[[:space:]]+[0-9]+x' | grep -v ' SR' | while read -r _mname _mrates; do _wxh=$(printf '%s' "$_mname" | tr -cd '0-9x' | sed 's/x$//'); for _r in $_mrates; do _star=""; case "$_r" in *\**) _star="*";; esac; _r=$(printf '%s' "$_r" | tr -d '*+'); printf '%s.%s %s %s Hz%s\n' "$_wxh" "$_r" "$_mname" "$_r" "$_star"; done; done ;;
	esac
}

# _xrandr_desktop_rewrite <args...> — C contract (2026-08-28): the stock
# gameStop request derives its mode from the seq-key, which strips
# non-alphanumerics ("640x480i" -> key "640x480.60.00" -> re-issued as
# --mode 640x480). On the ANALOG CRT of a MODESETTING family the bare
# name can ONLY mean the desktop mode (the kernel-synthesized one was
# removed for tube safety, 2026-08-12, and a CRT-targeted request never
# means the LCD's VESA 640x480). AMD-ONLY by construction: on NVIDIA the
# bare "640x480" IS the interlaced desktop alias (family adapter truth,
# 2026-08-28) — rewriting it there would BadMatch every gameStop
# (regression caught live 23:26:13, trace REWRITE=1 on the GTX 970 box).
# Conservative: exactly one --output, and that output is the classified
# CRT from detect-state. Anything else: no match.
_xrandr_desktop_rewrite() {
	case " $* " in
	*" --mode 640x480 "*|*" --mode "640x480" "*)
		[ "$(_xrandr_is_amd)" = "1" ] || return 1
		local _crt="" _nout _o _prev _a
		[ -f /tmp/crt-dual/detect-state ] && _crt=$(sed -n 's/^CRT_OUT=//p' /tmp/crt-dual/detect-state 2>/dev/null | head -1 | awk '{print $1}')
		_nout=$(printf '%s\n' "$@" | grep -c '^--output$')
		if [ -n "$_crt" ] && [ "$_nout" = "1" ] && [ "${2:-}" != "" ]; then
			_o=$(printf '%s\n' "$@" | awk 'p{print;exit} /^--output$/{p=1}')
			if [ "$_o" = "$_crt" ]; then
				_prev=""
				for _a in "$@"; do
					if [ "$_prev" = "--mode" ] && [ "$_a" = "640x480" ]; then printf '%s\n' "640x480i"; else printf '%s\n' "$_a"; fi
					_prev="$_a"
				done
				return 0
			fi
		fi
		;;
	esac
	return 1
}