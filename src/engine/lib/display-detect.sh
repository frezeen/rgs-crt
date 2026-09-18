#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
# display-detect.sh — CRT-DUAL pure detection (slim)
# Contract: inputs(sysfs tree, X snapshot, EDID snapshot, probe-ok, overrides) -> roles
# Side effects: sets the role globals (CRT_OUTS/LCD_OUTS/...); _detect_demote
# debounces (sleep DEMOTE_DEBOUNCE_SEC) and prunes probe-ok. Reads only —
# never writes a mode; the apply helpers live in src/owner/sr-owner.sh.
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
	local d conn xname status has_analog=""
	for d in "$_sysfs_root"/card*-*/; do [ -e "$d" ] || continue; conn=$(basename "$d"); conn=${conn#card*-}; _output_is_analog "$conn" && { has_analog=1; break; }; done
	for d in "$_sysfs_root"/card*-*/; do [ -f "$d/status" ] || continue; status=$(cat "$d/status" 2>/dev/null); conn=$(basename "$d"); conn=${conn#card*-}; xname=$(_drm_to_x "$conn"); if _output_is_analog "$xname"; then case "$status" in connected) CRT_OUTS="$CRT_OUTS $xname";; disconnected) CRT_PRESUMED_OUTS="$CRT_PRESUMED_OUTS $xname";; esac; else case "$status" in connected) if [ -s "$d/edid" ]; then LCD_OUTS="$LCD_OUTS $xname"; elif [ -z "$has_analog" ]; then CRT_PRESUMED_OUTS="$CRT_PRESUMED_OUTS $xname"; else LCD_OUTS="$LCD_OUTS $xname"; fi;; disconnected) [ -z "$has_analog" ] && CRT_PRESUMED_OUTS="$CRT_PRESUMED_OUTS $xname";; esac; fi; done
	CRT_OUT=$(echo "$CRT_OUTS" | awk '{print $1}'); CRT_PRESUMED_OUT=$(echo "$CRT_PRESUMED_OUTS" | awk '{print $1}'); LCD_OUT=$(echo "$LCD_OUTS" | awk '{print $1}')
}
# Post-classify helpers — pure, testable, no xrandr when kept separate
_detect_filter_lcd_phantom() { [ -n "$LCD_OUTS" ] || return 0; local _l2="" _o2; for _o2 in $LCD_OUTS; do case " $_X_CONNECTED " in *" $_o2 "*) [ "$(_sysfs_status "$_o2")" = "connected" ] && _l2="$_l2 $_o2";; esac; done; LCD_OUTS="$(echo "$_l2" | sed 's/^ //')"; LCD_OUT="$(echo "$LCD_OUTS" | awk '{print $1}')"; }
_list_del() { echo "$1" | tr ' ' '\n' | grep -v "^$2$" | tr '\n' ' ' | sed 's/  */ /g; s/^ //; s/ $//'; } # "<list>" <token> -> normalised list minus token
_promote_one() { local _p="$1"; CRT_PRESUMED_OUTS=$(_list_del "$CRT_PRESUMED_OUTS" "$_p"); case " $CRT_OUTS " in *" $_p "*) :;; *) CRT_OUTS="$CRT_OUTS $_p";; esac; }
_detect_apply_override() { if _crt_dual_crt_output; then local _ov="$CRT_DUAL_CRT_OUTPUT"; LCD_OUTS=$(_list_del "$LCD_OUTS" "$_ov"); CRT_PRESUMED_OUTS=$(_list_del "$CRT_PRESUMED_OUTS" "$_ov"); CRT_OUTS="$_ov $(_list_del "$CRT_OUTS" "$_ov")"; fi; }
_detect_promote_live() { [ -n "$CRT_PRESUMED_OUTS" ] || return 0; local _p3; for _p3 in $CRT_PRESUMED_OUTS; do if _crt_active_15khz "$_p3"; then _promote_one "$_p3"; echo "CRT-DUAL-DETECT: $_p3 active timing 15kHz-class -> CRT confirmed" >&2; fi; done; }
_detect_promote_probe() { local _p; for _p in $(cat "$CRT_DUAL_STATE_DIR/probe-ok" 2>/dev/null); do case " $CRT_PRESUMED_OUTS " in *" $_p "*) _promote_one "$_p";; *) continue;; esac; done; }
_detect_promote_replug() { [ -n "$CRT_PRESUMED_OUTS" ] || return 0; local _pr; for _pr in $CRT_PRESUMED_OUTS; do if _output_is_analog "$_pr" && [ "$(_sysfs_status "$_pr" 2>/dev/null)" = "connected" ]; then _promote_one "$_pr"; echo "CRT-DUAL-DETECT: $_pr connected (replug) -> CRT confirmed" >&2; fi; done; }
_detect_demote() { [ -n "$CRT_OUTS" ] || return 0; local _c3="" _o4 _candidates=""; for _o4 in $CRT_OUTS; do if _output_is_analog "$_o4" && [ "$(_sysfs_status "$_o4" 2>/dev/null)" = "disconnected" ]; then _candidates="$_candidates $_o4"; else _c3="$_c3 $_o4"; fi; done; if [ -n "$_candidates" ]; then sleep "$DEMOTE_DEBOUNCE_SEC"; for _o4 in $_candidates; do if [ "$(_sysfs_status "$_o4" 2>/dev/null)" = "disconnected" ]; then case " $CRT_PRESUMED_OUTS " in *" $_o4 "*) :;; *) CRT_PRESUMED_OUTS="$CRT_PRESUMED_OUTS $_o4";; esac; [ -f "$CRT_DUAL_STATE_DIR/probe-ok" ] && { grep -v "^$_o4$" "$CRT_DUAL_STATE_DIR/probe-ok" >"$CRT_DUAL_STATE_DIR/probe-ok.tmp" 2>/dev/null || true; mv -f "$CRT_DUAL_STATE_DIR/probe-ok.tmp" "$CRT_DUAL_STATE_DIR/probe-ok" 2>/dev/null || true; }; else _c3="$_c3 $_o4"; fi; done; fi; CRT_OUTS="$(echo "$_c3" | sed 's/^ //')"; }
_detect_escape_analog_lcd() { if _crt_dual_analog_lcd; then LCD_OUTS="$CRT_OUTS $CRT_PRESUMED_OUTS $LCD_OUTS"; CRT_OUTS=""; CRT_PRESUMED_OUTS=""; fi; }
