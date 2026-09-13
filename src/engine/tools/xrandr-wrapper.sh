#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
# Copyright (C) 2026 FreZeeN
# Part of crt-dual — https://github.com/frezeen
# xrandr-wrapper.sh — AMD dce_v6 glitch-free wrapper (prod, always active)
#
# WHY: on AMD dce_v6 every FORCE-REQUERY xrandr re-probes the analog DAC
# and blips the 15kHz tube (measured 2026-08-13 per-command: --query/
# --verbose/--prop/--list* are G, --current + all writes are silent).
# Stock Batocera (batocera-resolution, S65values4boot, emulatorlauncher)
# bursts G calls at boot and at gameStart/Stop — the boot shows many
# glitches even when crt-dual itself is 0G (verified via xrandr-trace).
# This wrapper translates the G family to the glitch-free --current path
# ONLY on AMD (GPU display-class check in lspci, never the chipset), ONLY for
# the stock callers that need
# it — crt-dual's own calls already use --current, so the wrapper is a
# no-op for them. On NVIDIA/Intel the wrapper is inert (exec stock).
#
# WHERE: placed VOLATILELY at /usr/bin/xrandr by the PRE-X hook
# (S15crt-dual-gen) at every boot on AMD only — nothing persisted, no
# backup, no uninstall branch (owner directive 2026-08-31). verify.sh
# accepts both valid states (stock pre-boot, hook-placed post-boot).
# Always active on AMD, whole session.
#
# TRANSLATION (conservative, verified via xrandr --help):
# --query  -> --current  (re-probe vs cached)
# --verbose alone -> --current --verbose (cached + details)
# --prop alone    -> --current --prop
# --list* family  -> --current --list* (if stock supports it, else passthrough)
# Bare xrandr (no args) -> --current (same as --query)
set -uo pipefail
STOCK="/overlay/base/usr/bin/xrandr"
[ -x "$STOCK" ] || STOCK="/usr/bin/xrandr.stock"
[ -x "$STOCK" ] || exec /usr/bin/xrandr "$@"  # fallback if no backup

# ── shared translation core (AMD gate + desktop-name rewrite + _TRANS) ──
# The translation logic lives in src/tools/xrandr-shared.sh, ONE source of
# truth ALSO sourced by the display-trace wrapper (unified 2026-08-28:
# the 5-case _TRANS block was byte-identical in both files — divergence
# would make trace-on-AMD unfaithful to prod). If the shared file is
# missing, degrade to plain stock passthrough — never a broken xrandr.
if [ -r /userdata/system/crt-dual/src/tools/xrandr-shared.sh ]; then
	# shellcheck source=/dev/null
	source /userdata/system/crt-dual/src/tools/xrandr-shared.sh
else
	exec "$STOCK" "$@"
fi

# ── gated FULL logging (merged instrument, 2026-08-31 owner directive) ──
# ONE wrapper: the prod dispatch + the display-trace logging, active only
# while /tmp/crt-dual/display-trace-on exists. Toggled by
# display-trace.sh start/stop (CLI) and by the PRE-X hook when the package
# root has BOOT_TRACE (boot-burst debug). Marker off = zero cost beyond
# one [ -f ]. The logging sits BEFORE the AMD gate on purpose: the gate's
# own failure (it returned 0 on a real AMD GPU for three days — bug found
# 2026-08-31) is exactly the kind of behavior the instrument must see.
if [ -f /tmp/crt-dual/display-trace-on ]; then
	_ts=$(date '+%s.%N %H:%M:%S'); _epoch=${_ts% *}; _ht=${_ts#* }
	_caller=$(tr '\0' ' ' <"/proc/$PPID/cmdline" 2>/dev/null); _chain=""; _last=""; _p="$PPID"
	for _i in 1 2 3 4 5 6; do _c=$(tr '\0' ' ' <"/proc/$_p/cmdline" 2>/dev/null) || break; _t=$(printf '%s' "${_c%% *}" | sed 's#.*/##'); [ -n "$_t" ] && [ "$_t" != "$_last" ] && { _chain="${_chain:+$_chain -> }$_t"; _last="$_t"; }; _pp=$(awk '{print $4}' "/proc/$_p/stat" 2>/dev/null); [ -n "$_pp" ] && [ "$_pp" -gt 1 ] && [ "$_pp" != "$_p" ] || break; _p="$_pp"; done
	if [[ " $* " =~ (--mode|--rate|--primary|--noprimary|--off|--newmode|--addmode|--delmode|--transform|--scale|--pos|--right-of|--left-of|--above|--below|--same-as|--rotate|--reflect|--gamma|--brightness|--fb|--size|--panning|--dpi|--set|--dryrun) ]]; then _cls=W
	elif [[ " $* " =~ (--query|--verbose|--prop|--properties|--listmonitors|--listactivemonitors|--listproviders|--listPrimary|--listModes|--listConnectedOutputs|--currentResolution|--currentRotation) ]]; then _cls=G
	elif [[ " $* " =~ --current ]]; then _cls=R; else _cls=G; fi
	printf '%s %s %s PID=%s CHAIN=[%s] CALLER=[%s] ARGS=%s\n' "$_epoch" "$_cls" "$_ht" "$PPID" "$_chain" "${_caller:0:80}" "$*" >>/userdata/system/logs/display-trace.log 2>/dev/null || true
fi

# AMD gate — shared core (cached: lspci once per boot, then /tmp file;
# per-call lspci would add ~5ms ×45 at boot). DISPLAY-CLASS RESTRICTED:
# matching the bare vendor token across ALL of lspci fooled the gate on
# an AMD-chipset board (verified 2026-08-28 GTX 970 on Threadripper:
# "AMD Starship/Matisse" chipset lines matched, wrapper activated on
# NVIDIA and its --query->--current translation killed the heartbeat).
[ "$(_xrandr_is_amd)" = "1" ] || exec "$STOCK" "$@"

# ── desktop-name rewrite (AMD, C contract 2026-08-28) ──────────────────
# Stock's gameStop restore derives its request from the seq-key: the
# interlace desktop name loses its "i" upstream (the key builder strips
# non-alphanumerics: "640x480i" -> key "640x480.60.00" -> re-issued as
# --mode 640x480). On this family the bare "640x480" on the analog CRT
# can ONLY mean the desktop mode: the kernel-synthesized one was removed
# for tube safety (2026-08-12) and a CRT-targeted request never means the
# LCD's VESA 640x480. Translate it to the real name HERE so the stock
# restore lands on 640x480i by itself — no configgen logic touched, no
# RAM patch needed (this wrapper already stands between stock and X).
# Conservative by construction: exactly one --output, and that output is
# the classified CRT from detect-state. Anything else passes through.
if _new=$(_xrandr_desktop_rewrite "$@"); then
	_read=()
	while IFS= read -r _a; do _read+=("$_a"); done <<<"$_new"
	exec "$STOCK" "${_read[@]}"
fi

# Batocera-patched options (verified via trace, glitch-free via --current)
# These 5 carry same info as cached --current; emulate without re-probe.
_TRANS=$(_xrandr_trans_name "$*")
if [ -n "$_TRANS" ]; then
	_cur_out=$("$STOCK" --current 2>/dev/null) || exec "$STOCK" "$@"
	_out="${*: -1}"
	_xrandr_trans_reply "$_TRANS" "$_cur_out" "$_out"
	exit 0
fi

# Already glitch-free or a write -> passthrough
for _a in "$@"; do
	case "$_a" in
	--current|--mode|--output|--primary|--noprimary|--pos|--scale*|--transform|--addmode|--newmode|--delmode|--off|--auto|--fb|--dpi|--dryrun) exec "$STOCK" "$@" ;;
	esac
done

# G family -> translate to --current
_has_query=0; _has_verbose=0; _has_prop=0; _has_list=0; _bare=1
for _a in "$@"; do
	[ -n "$_a" ] && _bare=0
	case "$_a" in
	--query) _has_query=1 ;;
	--verbose) _has_verbose=1 ;;
	--prop|--properties) _has_prop=1 ;;
	--listmonitors|--listactivemonitors|--listproviders|--q1|--q2) _has_list=1 ;;
	esac
done

# Bare xrandr (no args) is --query
if [ "$_bare" = "1" ]; then exec "$STOCK" --current; fi

if [ "$_has_query" = "1" ]; then
	# replace --query with --current, keep other args (e.g. --verbose)
	_args=()
	for _a in "$@"; do
		if [ "$_a" = "--query" ]; then _args+=("--current"); else _args+=("$_a"); fi
	done
	exec "$STOCK" "${_args[@]}"
fi

if [ "$_has_verbose" = "1" ] || [ "$_has_prop" = "1" ] || [ "$_has_list" = "1" ]; then
	# prepend --current if not already there
	exec "$STOCK" --current "$@"
fi

exec "$STOCK" "$@"
