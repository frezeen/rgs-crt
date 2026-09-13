#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
# display-detect.sh — CRT-DUAL v2 T15.1 pure detection (slim)
# Contract: inputs(sysfs tree, X snapshot, EDID snapshot, probe-ok, overrides) -> roles
# Zero side effects except setting globals CRT_OUTS/LCD_OUTS etc — no xrandr, no writes.
# Sole owner: detection cascade (charter §1). Adapters own truth oracles.
# Test seam: fixtures inject snapshots, live path passes no arg and reads once.
: "${CRT_DUAL_SYSFS:=/sys/class/drm}"
# Pure classify: takes _lx snapshot and _sysfs_root, sets globals. No xrandr inside when arg provided.
_detect_xrandr_pure() {
	local _lx="${1:-}" _sysfs_root="${2:-$CRT_DUAL_SYSFS}"
	_X_CONNECTED=""; CRT_OUTS=""; CRT_PRESUMED_OUTS=""; LCD_OUTS=""
	[ -n "$_lx" ] || _lx=$(xrandr --current 2>/dev/null)
	[ -n "$_lx" ] || return 0
	local line out has_analog="" _edid state
	while read -r line; do case "$line" in *" connected"*|*" disconnected"*) ;; *) continue;; esac; read -r _xn _xs _ <<<"$line"; [ "$_xs" = "connected" ] && _X_CONNECTED="$_X_CONNECTED $_xn"; done <<<"$_lx"
	while read -r line; do [[ "$line" != *" connected"* && "$line" != *" disconnected"* ]] && continue; out=$(echo "$line" | awk '{print $1}'); _output_is_analog "$out" && { has_analog=1; break; }; done <<<"$_lx"
	while read -r line; do [[ "$line" != *" connected"* && "$line" != *" disconnected"* ]] && continue; out=$(echo "$line" | awk '{print $1}'); [ -n "$out" ] || continue; if _output_is_analog "$out"; then _edid=0; _edid_present "$out" && _edid=1; if [ "$_edid" = "1" ]; then LCD_OUTS="$LCD_OUTS $out"; else CRT_PRESUMED_OUTS="$CRT_PRESUMED_OUTS $out"; fi; else state=$(_sysfs_status "$out"); case "$state" in connected) _edid=0; _edid_present "$out" && _edid=1; if [ "$_edid" = "1" ]; then LCD_OUTS="$LCD_OUTS $out"; elif [ -z "$has_analog" ]; then CRT_PRESUMED_OUTS="$CRT_PRESUMED_OUTS $out"; else LCD_OUTS="$LCD_OUTS $out"; fi;; *) [ -z "$has_analog" ] && CRT_PRESUMED_OUTS="$CRT_PRESUMED_OUTS $out";; esac; fi; done <<<"$_lx"
}
_detect_sysfs_pure() {
	local _sysfs_root="${1:-$CRT_DUAL_SYSFS}"
	CRT_OUTS=""; CRT_PRESUMED_OUTS=""; LCD_OUTS=""
	local d conn type idx xidx xtype xname status has_analog=""
	for d in "$_sysfs_root"/card*-*/; do [ -e "$d" ] || continue; conn=$(basename "$d"); conn=${conn#card*-}; _output_is_analog "$conn" && { has_analog=1; break; }; done
	for d in "$_sysfs_root"/card*-*/; do [ -f "$d/status" ] || continue; status=$(cat "$d/status" 2>/dev/null); conn=$(basename "$d"); conn=${conn#card*-}; type=${conn%-*}; idx=${conn##*-}; xidx=$((idx - $(_gpu_adapter && _impl_drm_offset || echo 0))); xtype=${type%-A}; xname="${xtype}-${xidx}"; if _output_is_analog "$xname"; then case "$status" in connected) CRT_OUTS="$CRT_OUTS $xname";; disconnected) CRT_PRESUMED_OUTS="$CRT_PRESUMED_OUTS $xname";; esac; else case "$status" in connected) if [ -s "$d/edid" ]; then LCD_OUTS="$LCD_OUTS $xname"; elif [ -z "$has_analog" ]; then CRT_PRESUMED_OUTS="$CRT_PRESUMED_OUTS $xname"; else LCD_OUTS="$LCD_OUTS $xname"; fi;; disconnected) [ -z "$has_analog" ] && CRT_PRESUMED_OUTS="$CRT_PRESUMED_OUTS $xname";; esac; fi; done
	CRT_OUT=$(echo "$CRT_OUTS" | awk '{print $1}'); CRT_PRESUMED_OUT=$(echo "$CRT_PRESUMED_OUTS" | awk '{print $1}'); LCD_OUT=$(echo "$LCD_OUTS" | awk '{print $1}')
}
# Post-classify helpers — pure, testable, no xrandr when kept separate
_detect_filter_lcd_phantom() { [ -n "$LCD_OUTS" ] || return 0; local _l2="" _o2; for _o2 in $LCD_OUTS; do case " $_X_CONNECTED " in *" $_o2 "*) [ "$(_sysfs_status "$_o2")" = "connected" ] && _l2="$_l2 $_o2";; esac; done; LCD_OUTS="$(echo "$_l2" | sed 's/^ //')"; LCD_OUT="$(echo "$LCD_OUTS" | awk '{print $1}')"; }
_promote_one() { local _p="$1"; CRT_PRESUMED_OUTS=$(echo "$CRT_PRESUMED_OUTS" | tr ' ' '\n' | grep -v "^$_p$" | tr '\n' ' ' | sed 's/  */ /g; s/^ //; s/ $//'); case " $CRT_OUTS " in *" $_p "*) :;; *) CRT_OUTS="$CRT_OUTS $_p";; esac; }
_detect_apply_override() { if _crt_dual_crt_output; then local _ov="$CRT_DUAL_CRT_OUTPUT"; LCD_OUTS=$(echo "$LCD_OUTS" | tr ' ' '\n' | grep -v "^$_ov$" | tr '\n' ' ' | sed 's/  */ /g; s/^ //; s/ $//'); CRT_PRESUMED_OUTS=$(echo "$CRT_PRESUMED_OUTS" | tr ' ' '\n' | grep -v "^$_ov$" | tr '\n' ' ' | sed 's/  */ /g; s/^ //; s/ $//'); CRT_OUTS=$(echo "$CRT_OUTS" | tr ' ' '\n' | grep -v "^$_ov$" | tr '\n' ' ' | sed 's/  */ /g; s/^ //; s/ $//'); CRT_OUTS="$_ov $CRT_OUTS"; fi; }
# CRT verify helpers — slim _crt_set_15khz_direct (T15.2)
_crt_handle_fallback() { local target="$1" _want_name="$2" _cur="$3"; if [ "$_cur" != "$_want_name" ]; then if [ -n "$_cur" ]; then if _output_is_analog "$target"; then echo "CRT-DUAL-CRT: $target — 480i mode $_want_name not effective (active $_cur) — analog port: transient, left as-is, next trigger retries" >&2; else xrandr --display "${DISPLAY:-:0}" --output "$target" --mode "320x240" --scale 2x2 2>/dev/null || true; echo "CRT-DUAL-CRT: $target — 480i mode $_want_name not effective (active $_cur) -> 240p fallback (320x240, full desktop)" >&2; fi; else echo "CRT-DUAL-CRT: $target — 480i verify read no mode (X busy?) — left as-is, next trigger retries" >&2; fi; fi; }
# Primary fallback — powers off others, re-marks primary, restores others (used by _crt_set_primary)
_crt_primary_fallback() { # restore own prior mode (_cm) or the family desktop name — no literals in shared code
	local target="$1" _cm="$2" _other _m
	local _dspec _desktop _drate
	_dspec=$(_desktop_mode_spec 2>/dev/null); _desktop=${_dspec% *}; _drate=${_dspec#* }
	for _other in $CRT_OUTS $LCD_OUTS; do [ -z "$_other" ] && continue; [ "$_other" = "$target" ] && continue; xrandr --display "${DISPLAY:-:0}" --output "$_other" --off 2>/dev/null || true; done
	if [ "$_cm" = "320x240" ]; then
		xrandr --display "${DISPLAY:-:0}" --output "$target" --primary --mode "320x240" --scale 2x2 --pos 0x0 2>/dev/null || true
	else
		_m="${_cm:-$_desktop}"
		local _rate=""
		[ "$_m" = "$_desktop" ] && _rate="$_drate" # desktop restores carry the tube refresh (replug @75 lesson, 2026-08-10)
		[ -n "$_m" ] && xrandr --display "${DISPLAY:-:0}" --output "$target" --primary --mode "$_m" ${_rate:+--rate $_rate} --transform none --pos 0x0 2>/dev/null || true
	fi
	for _other in $CRT_OUTS $LCD_OUTS; do [ -z "$_other" ] && continue; [ "$_other" = "$target" ] && continue
		if echo " $LCD_OUTS " | grep -q " $_other "; then
			local _lcd_n; _lcd_n=$(_lcd_native "$_other" 2>/dev/null)
			xrandr --display "${DISPLAY:-:0}" --output "$_other" --mode "$_lcd_n" --scale-from 640x480 --pos 0x0 2>/dev/null || true
		elif [ -n "$_desktop" ]; then
			xrandr --display "${DISPLAY:-:0}" --output "$_other" --mode "$_desktop" ${_drate:+--rate $_drate} --transform none --pos 0x0 2>/dev/null || true
		fi
	done
}
# Converter 240p helper — DP->VGA converter can expose fake EDID with VESA 31kHz modes
# (640x480@59.94 preferred, 1024x768, 800x600, 848x480 — verified HP 800 G5 2026-08-09).
# On this port: 480i IMPOSSIBLE (interlace over DP -> ENOENT, verified), so 240p direct.
# Garbage->converter meaningful ONLY on a DIGITAL port (DP/HDMI/DVI-D). Bare ANALOG CRT
# (DVI-I/VGA/CRT) has NO EDID so X synthesizes the VESA list identical in shape — treating
# a real analog CRT as a converter made this function refuse 480i on ES/batocera-resolution
# --auto (verified 2026-08-19 R9 270X: 1024x768 + "non-desktop -> restore pending" ad infinitum).
# On an analog port 480i is always physically possible -> 480i path; 240p is digital-only.
# Scale 2x2 stays on RandR BY DOCUMENTED LIMIT: Switchres API has no transform control.
# EDID modes CANNOT be removed (RRDeleteOutputMode BadAccess, i915 owns them) — stay
# dormant: no --auto/--mode "640x480i" touches them anymore (the name "320x240" is ours).
# Returns: 0 if handled (digital converter -> 240p), 1 if not converter, 2 if API broken.
_crt_handle_converter() { local target="$1" SR_API="$2" SR_INI="$3"; local _garbage; _garbage=$(xrandr --display "${DISPLAY:-:0}" --current 2>/dev/null | sed -n "/^$target connected/,/^[^ ]/p" | awk '$1 ~ /^[0-9]+x[0-9]+$/ && $1 != "640x480" && $1 != "320x240" {print $1}' | sort -u | tr '\n' ' '); if [ -n "$_garbage" ] && ! _output_is_analog "$target"; then local _p240; _p240=$("$SR_API" create 320 240 60 "$target" --ini "$SR_INI") || { echo "CRT-DUAL-CRT: $target — API could not create the 240p mode (loud failure, no fallback)" >&2; return 2; }; xrandr --display "${DISPLAY:-:0}" --output "$target" --mode "$_p240" --scale 2x2 2>/dev/null || true; _save_crt_desktop_mode "$target"; echo "CRT-DUAL-CRT: $target — converter with VESA EDID (31kHz ignored, dormant modes) -> 240p full desktop" >&2; return 0; fi; return 1; }
_detect_promote_live() { [ -n "$CRT_PRESUMED_OUTS" ] || return 0; local _p3; for _p3 in $CRT_PRESUMED_OUTS; do if _crt_active_15khz "$_p3"; then _promote_one "$_p3"; echo "CRT-DUAL-DETECT: $_p3 active timing 15kHz-class -> CRT confirmed" >&2; fi; done; }
_detect_promote_probe() { local _p; for _p in $(cat "$CRT_DUAL_STATE_DIR/probe-ok" 2>/dev/null); do case " $CRT_PRESUMED_OUTS " in *" $_p "*) _promote_one "$_p";; *) continue;; esac; done; }
_detect_promote_replug() { [ -n "$CRT_PRESUMED_OUTS" ] || return 0; local _pr; for _pr in $CRT_PRESUMED_OUTS; do if _output_is_analog "$_pr" && [ "$(_sysfs_status "$_pr" 2>/dev/null)" = "connected" ]; then _promote_one "$_pr"; echo "CRT-DUAL-DETECT: $_pr connected (replug) -> CRT confirmed" >&2; fi; done; }
_detect_demote() { [ -n "$CRT_OUTS" ] || return 0; local _c3="" _o4 _candidates=""; for _o4 in $CRT_OUTS; do if _output_is_analog "$_o4" && [ "$(_sysfs_status "$_o4" 2>/dev/null)" = "disconnected" ]; then _candidates="$_candidates $_o4"; else _c3="$_c3 $_o4"; fi; done; if [ -n "$_candidates" ]; then sleep "$DEMOTE_DEBOUNCE_SEC"; for _o4 in $_candidates; do if [ "$(_sysfs_status "$_o4" 2>/dev/null)" = "disconnected" ]; then case " $CRT_PRESUMED_OUTS " in *" $_o4 "*) :;; *) CRT_PRESUMED_OUTS="$CRT_PRESUMED_OUTS $_o4";; esac; [ -f "$CRT_DUAL_STATE_DIR/probe-ok" ] && { grep -v "^$_o4$" "$CRT_DUAL_STATE_DIR/probe-ok" >"$CRT_DUAL_STATE_DIR/probe-ok.tmp" 2>/dev/null || true; mv -f "$CRT_DUAL_STATE_DIR/probe-ok.tmp" "$CRT_DUAL_STATE_DIR/probe-ok" 2>/dev/null || true; }; else _c3="$_c3 $_o4"; fi; done; fi; CRT_OUTS="$(echo "$_c3" | sed 's/^ //')"; }
_detect_escape_analog_lcd() { if _crt_dual_analog_lcd; then LCD_OUTS="$CRT_OUTS $CRT_PRESUMED_OUTS $LCD_OUTS"; CRT_OUTS=""; CRT_PRESUMED_OUTS=""; fi; }
