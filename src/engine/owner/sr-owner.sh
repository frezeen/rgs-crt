#!/bin/bash
# sr-owner.sh — CRT-DUAL v2 SR-OWNER (1 cervello = 1 file, A letterale)

set -uo pipefail

STATE_DIR="${CRT_DUAL_STATE_DIR:-/tmp/crt-dual}"
WANT_FILE="${CRT_DUAL_WANT_FILE:-$STATE_DIR/want}"
WANT_LOCK="${WANT_FILE}.lock"
DETECT_STATE="$STATE_DIR/detect-state"
LOG="${CRT_DUAL_SR_OWNER_LOG:-/userdata/system/logs/sr-owner.log}"
mkdir -p "$(dirname "$LOG")" 2>/dev/null || true
log() {
	echo "SR-OWNER [$(date +%H:%M:%S.%3N)]: $*" | tee -a "$LOG" 2>/dev/null || true
	echo "SR-OWNER: $*" >&2
}

_state_val() { sed -n "s/^$1=//p" "$DETECT_STATE" 2>/dev/null | head -1 | awk '{print $1}'; }

_switchres_api_path() {
	echo "${CRT_DUAL_API:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../api" 2>/dev/null && pwd)/switchres_api.py}"
}

_owner_desktop_name() {
	# The desktop mode is the persistent conf Modeline ("640x480i" — the
	# X11 generator's boot contract): X attaches it at startup on every
	# family. Its RUNTIME name is a family fact (2026-08-28, GTX 970 + the
	# NVIDIA Programming-Modes docs): modesetting (AMD/Intel) keeps the
	# conf name verbatim; NVIDIA exposes the same mode under the bare
	# "640x480" alias with the Interlace flag (resolution-shaped suffixed
	# names belong to the driver's own registry — RRAddOutputMode BadMatch
	# even with an unused timing, measured). Shared code asks the adapter
	# (_desktop_mode_name), never hardcodes one. Refresh is the DYNAMIC
	# tube flag (crt-dual.refresh, 60 NTSC / 50 PAL); --rate disambiguates
	# the replug-synthesized @75 (lesson 2026-08-10). Echoes "NAME RATE".
	# NO state file: crt-mode-name was retired 2026-08-28 (charter §4).
	local _spec
	_spec=$(_desktop_mode_spec 2>/dev/null)
	[ -n "$_spec" ] || { log "FAIL: no desktop spec from the adapter (GPU_VENDOR=${GPU_VENDOR:-?})"; return 1; }
	echo "$_spec"
}

_owner_desktop_transform_guard() {
	# NVIDIA batch-lie (re-verified 2026-08-28: a request mixing CRT
	# --transform with LCD --scale-from returned rc=0 and left the LCD scale
	# on the CRT CRTC — source 213x213, zoomed ES). The layout batch applies
	# the desktop WITHOUT touching the CRT transform; this reads the CRT
	# transform back (client-cached --current --verbose, R class) and, when
	# not identity, repairs it in its own single-output request (proven
	# repair: standalone --transform none restores 640x480+0+0 1:1).
	local target="$1" _t
	_t=$(xrandr --display "${DISPLAY:-:0}" --current --verbose 2>/dev/null |
		sed -n "/^$target connected/,/^[A-Za-z]/p" | awk '/Transform:/ {print $2; exit}')
	[ -z "$_t" ] && return 0
	[ "$_t" = "1.000000" ] && return 0
	log "WARN: CRT transform leak ($_t) after layout batch — repairing standalone"
	xrandr --output "$target" --transform none 2>/dev/null || log "FAIL: transform repair on $target"
}

_crt_set_15khz_direct() {
	local target="${1:-${CRT_OUT:-}}"
	[ -z "$target" ] && return 1
	[ -z "${DISPLAY:-}" ] && export DISPLAY=:0

	local SR_API SR_INI
	SR_INI="/etc/switchres.ini"
	SR_API=$(_switchres_api_path)
	# Converter check FIRST (240p on DP->VGA fakes is a different physical
	# path, digital ports only — returns 0 handled / 2 API-broken / 1 not-a-converter).
	local _rc
	_crt_handle_converter "$target" "$SR_API" "$SR_INI"; _rc=$?
	if [ "$_rc" = "0" ]; then return 0; elif [ "$_rc" = "2" ]; then return 1; fi

	local _spec _want_name _rate
	if ! _spec=$(_owner_desktop_name); then
		echo "CRT-DUAL-CRT: $target — no desktop name from the family adapter (loud, no fallback)" >&2
		return 1
	fi
	_want_name=${_spec% *}; _rate=${_spec#* }
	xrandr --display "$DISPLAY" --output "$target" --mode "$_want_name" --rate "$_rate" --pos 0x0 2>/dev/null || true # attach-modeset, verified below
	xrandr --display "$DISPLAY" --output "$target" --transform none 2>/dev/null || true # standalone request: never mixed with another output's scale (batch-lie)
	# VERIFY by class (never by name identity): active must be a 15kHz-class
	# mode (_crt_active_15khz: the same oracle the watcher uses).
	local _cur
	_cur=$(_xrandr_active_mode "$target" name 2>/dev/null) || _cur=""
	if ! _crt_active_15khz "$target"; then
		_crt_handle_fallback "$target" "$_want_name" "$_cur"
	fi
	# Remove kernel DoubleScan "640x480" (54MHz, 60kHz — destructive on a
	# 15kHz tube, incident 2026-08-12) — ONLY when the bare name is NOT this
	# family's desktop alias: on NVIDIA "640x480" IS the interlaced desktop
	# (adapter truth, 2026-08-28); delmoding it would kill the tube. On
	# modesetting families the desktop name is suffixed, so a bare entry on
	# the analog port can only be the kernel synthesis.
	if [ "$_want_name" != "640x480" ]; then
		xrandr --display "$DISPLAY" --delmode "$target" "640x480" 2>/dev/null || true # best-effort; absent when the kernel never synthesized it
	fi
	_save_crt_desktop_mode "$target"
	return 0
}

# (SR-*: transform none) or a VESA collision (batocera-resolution
_save_crt_desktop_mode() {
	local _t="${1:-${CRT_OUT:-}}"
	[ -z "$_t" ] && return 0
	[ -z "${DISPLAY:-}" ] && export DISPLAY=:0
	local _m _spec _dn _r
	if _output_is_analog "$_t"; then
		if _spec=$(_owner_desktop_name); then _dn=${_spec% *}; _r=${_spec#* }; else _dn=$(_xrandr_active_mode "$_t" name 2>/dev/null); _r=60; fi
		_m="$_dn $_r.00"
	else
		_m=$(_xrandr_active_mode "$_t")
	fi
	[ -n "$_m" ] && echo "$_m" >"$CRT_DUAL_STATE_DIR/crt-desktop-mode"
}

# PRIMARY respecting effective mode (480i or 240p fallback — don't overwrite transform).
_crt_set_primary() {
	local target="${1:-${CRT_OUT:-}}"
	[ -z "$target" ] && return 1
	[ -z "${DISPLAY:-}" ] && export DISPLAY=:0
	_primary_clear_for "$target"
	local _cm
	_cm=$(_xrandr_active_mode "$target" name)
	xrandr --display "$DISPLAY" --output "$target" --primary 2>/dev/null || true # flag-only, zero CRTC change
	# VERIFY
	if [ "$(_xrandr_primary 2>/dev/null)" != "$target" ]; then
		_crt_primary_fallback "$target" "$_cm"
	fi
	return 0
}

_ensure_fb_640() {
	local crt="${1:-${CRT_OUT:-}}"
	[ -z "$crt" ] && return 0
	[ -n "${DISPLAY:-}" ] || export DISPLAY=:0
	local _sz
	_sz=$(xrandr --current 2>/dev/null | sed -n 's/^Screen 0:.* current \([0-9]* x [0-9]*\).*/\1/p' | tr -d ' ')
	[ "$_sz" = "640x480" ] && return 0
	local lcd lcd_n _cm
	lcd="${LCD_OUT:-}"
	[ -n "$lcd" ] && xrandr --output "$lcd" --off 2>/dev/null || true
	_cm=$(_xrandr_active_mode "$crt" name)
	if [ "$_cm" = "320x240" ]; then
		xrandr --output "$crt" --primary --mode "320x240" --scale 2x2 --pos 0x0 2>/dev/null || true
	else
		local _spec _m _r2
		_spec=$(_owner_desktop_name) || _spec="$(_xrandr_active_mode "$crt" name 2>/dev/null) 60"
		_m=${_spec% *}; _r2=${_spec#* }
		[ -n "$_m" ] && xrandr --output "$crt" --primary --mode "$_m" --rate "$_r2" --transform none --pos 0x0 2>/dev/null || true
	fi
	if [ -n "$lcd" ]; then
		lcd_n=$(_lcd_native "$lcd" 2>/dev/null)
		xrandr --output "$lcd" --mode "$lcd_n" --scale-from 640x480 --pos 0x0 2>/dev/null || true
	fi
	_kill_unmanaged_outputs "$crt" "$lcd"
}

# CRT gameStop).
_lcd_native() {
	local _n
	_n=$(xrandr --current 2>/dev/null |
		awk -v o="$1" '$0 ~ "^"o" " {c=1; next} c && /^[A-Za-z]/ {exit} c' |
		grep -oE "[0-9]+x[0-9]+" | sort -t x -k1,1n -k2,2n | tail -1)
	[ -n "$_n" ] && echo "$_n" || echo "1920x1080"
}

_kill_unmanaged_outputs() {
	# disconnected are skipped (no modeset target).
	local crt="$1" lcd="$2" name
	[ -n "$crt" ] || crt="__no_crt__"
	[ -n "$lcd" ] || lcd="__no_lcd__"
	DISPLAY=:0 xrandr --current 2>/dev/null | awk '/ connected /{print $1}' | while IFS= read -r name; do
		if [ "$name" != "$crt" ] && [ "$name" != "$lcd" ]; then
			xrandr --display "${DISPLAY:-:0}" --output "$name" --noprimary --off 2>/dev/null || true # best-effort; unmanaged output — off + primary-clear: a stale primary mark on a phantom steals the batocera-resolution anchor (observed 2026-08-12: --off alone left DP-1 'connected primary', the anchor would land on the phantom)
		fi
	done
	# expects one boot apply, not one per poll).
	if [ -n "$crt" ] && [ "$crt" != "__no_crt__" ]; then
		if [ "$(_xrandr_primary 2>/dev/null)" != "$crt" ]; then
			xrandr --display "${DISPLAY:-:0}" --output "$crt" --primary 2>/dev/null || true # best-effort; contract primary, flag-only
		fi
	elif [ -n "$lcd" ] && [ "$lcd" != "__no_lcd__" ]; then
		if [ "$(_xrandr_primary 2>/dev/null)" != "$lcd" ]; then
			xrandr --display "${DISPLAY:-:0}" --output "$lcd" --primary 2>/dev/null || true # best-effort; LCD-only contract primary
		fi
	fi
}

# PRIMARY at its NATIVE mode with --transform none — MANDATORY because
# the dual layout's --scale-from 640x480 persists across mode changes,
_lcd_native_primary_takeover() {
	local lcd
	lcd=$(_lcd_native "$LCD_OUT")
	_primary_clear_for "$LCD_OUT"
	xrandr --display "${DISPLAY:-:0}" --output "$LCD_OUT" --primary --mode "$lcd" --transform none --pos 0x0 2>/dev/null ||
		xrandr --display "${DISPLAY:-:0}" --output "$LCD_OUT" --primary --transform none --pos 0x0 2>/dev/null || true # best-effort last resort
	echo "$lcd"
}

apply_dual_layout() {
	# the unlocked body directly).
	exec 9>"$CRT_DUAL_STATE_DIR/layout.lock" 2>/dev/null || return 1
	flock -x -w 10 9 2>/dev/null || {
		exec 9>&- 2>/dev/null || true # release the fd regardless
		return 1
	}
	_apply_dual_layout_unlocked
	flock -u 9 2>/dev/null || true # released here
	exec 9>&- 2>/dev/null || true
	return 0
}

_apply_dual_layout_unlocked() {
	# Detect only when the caller did not (measured 2026-08-28:
	# detect_outputs = 1.21s, mostly the demote debounce sleep 1 +
	# per-port sysfs/xrandr reads). apply_via_engine already classified
	# (or skipped via --no-detect with a frozen topology); other callers
	# land here with empty roles and get the full detection as before.
	if [ -z "${CRT_OUT:-}${CRT_PRESUMED_OUT:-}${LCD_OUT:-}" ]; then
		detect_outputs 2>/dev/null || true # detection is idempotent; failure = empty classification, layout stays stock
	fi
	export DISPLAY="${DISPLAY:-:0}"

	# the LCD in upscaled 1920x1080 instead of native
	local crt crttag
	crt="${CRT_OUT}"
	crttag=""
	if [ -z "$crt" ] && [ -z "$LCD_OUT" ]; then
		crt="${CRT_PRESUMED_OUT}"
		crttag=" (presumed)"
	fi

	# Dual desktop: the mode is the persistent conf Modeline, named by the
	# family adapter (_owner_desktop_name) and applied by this single batch,
	# which carries no mode-name literal in shared code and no name lookup:
	# universal by construction. v1 topology properties preserved: one
	# request, LCD comes up already scaled (no full-HD flash frame on
	# dce_v6), CRT modeset rides the same write. The CRT transform is NOT
	# touched here (batch-lie: mixing it with the LCD's scale-from made
	# NVIDIA report rc=0 while leaving the LCD scale on the CRT CRTC —
	# 213x213 zoom, re-verified 2026-08-28); _owner_desktop_transform_guard
	# reads it back and repairs standalone when needed.
	if [ -n "$LCD_OUT" ] && [ -n "$crt" ]; then
		local lcd crt_m crt_r _err _spec _pooled
		_spec=$(_owner_desktop_name) || { echo "CRT-DUAL-CRT: dual aborted — no desktop name from the adapter on $crt" >&2; return 1; }
		crt_m=${_spec% *}; crt_r=${_spec#* }
		# RGS-15KHZ-EXT (gameStop dual converge): the CRT after a game holds
		# either the desktop raster itself (SR-1_640x480@60 injected — bare
		# 640x480 absent from the pool, dual batch BadMatch, measured
		# 2026-08-28 GTX 970) or a GAME raster (per-game 15kHz mode, e.g.
		# 693x520_57i). Keep the former verbatim (zero-change); a game
		# raster MUST return to the desktop mode — the oracle
		# (_crt_desktop_ok) only accepts desktop timings, so keeping a game
		# raster made every gameStop "not converged" (rc=1 -> the old
		# || fallback re-ran the whole sr-owner) AND left the tube on the
		# game raster, with the final 480i restore delegated to stock
		# configgen by accident (session 2026-09-10 01:39:50, display-trace).
		# Resolution path = the same pool->SR->ensure-inject flow the CRT-dark
		# branch uses (handles the no-pool corner); loud when nothing is
		# attachable: the batch below fails visibly.
		if _crt_active_15khz "$crt" 2>/dev/null; then
			_cur15=$(_xrandr_active_mode "$crt" name 2>/dev/null)
			case "$_cur15" in
				"$crt_m" | SR-*_640x480@*) crt_m="$_cur15" ;;
				*)
					_pooled=$(_crt_desktop_ensure "$crt") && crt_m="$_pooled" ||
						echo "CRT-DUAL-CRT: $crt — no attachable 480i in pool and inject failed (X stale?) — dual batch will fail loudly" >&2
					;;
			esac
		else
			_pooled=$(_crt_desktop_ensure "$crt") && crt_m="$_pooled" ||
				echo "CRT-DUAL-CRT: $crt — no attachable 480i in pool and inject failed (X stale?) — dual batch will fail loudly" >&2
		fi
		lcd=$(_lcd_native "$LCD_OUT")
		_err=$(xrandr --output "$crt" --mode "$crt_m" --rate "$crt_r" --primary --pos 0x0 --output "$LCD_OUT" --mode "$lcd" --scale-from 640x480 --pos 0x0 2>&1) || {
			echo "CRT-DUAL-CRT: dual batch failed: $_err — retrying two-step" >&2
			_err=$(xrandr --output "$crt" --mode "$crt_m" --rate "$crt_r" --primary --pos 0x0 --output "$LCD_OUT" --mode "$lcd" --transform none --pos 0x0 2>&1) || echo "CRT-DUAL-CRT: dual fallback batch failed: $_err" >&2
			xrandr --output "$LCD_OUT" --scale-from 640x480 --pos 0x0 2>/dev/null || true # dce_v6 two-step: scale from a live CRTC only
		}
		_owner_desktop_transform_guard "$crt" || true
		echo "CRT-DUAL-CRT: dual CRT=$crt@${crt_m} 15kHz primary (1:1)$crttag, LCD=$LCD_OUT upscaled from 640x480 ($lcd)"
	elif [ -n "$LCD_OUT" ]; then
		lcd=$(_lcd_native_primary_takeover)
		echo "CRT-DUAL-CRT: LCD-only=$LCD_OUT@$lcd native primary"
	elif [ -n "$crt" ]; then
		# no --auto: the converter's fake EDID is 31kHz!).
		_crt_set_15khz_direct "$crt"
		_crt_set_primary "$crt"
		# Hotplug CRT-only: HDMI may be disconnected but still owns CRTC 1 (seen 21:27 HDMI disconnected CRTC 1). _kill_unmanaged skips disconnected, so free it explicitly.
		for _o in HDMI-1 HDMI-0 DP-1 DP-2 DVI-D-1; do [ "$_o" != "$crt" ] && xrandr --display "$DISPLAY" --output "$_o" --off 2>/dev/null || true; done
		echo "CRT-DUAL-CRT: CRT-only=$crt@640x480$crttag (HDMI/DP off, free stale CRTC)"
	else
		echo "CRT-DUAL-CRT: dual-output — no output detected (DISPLAY=$DISPLAY)" >&2
	fi
	_kill_unmanaged_outputs "$crt" "$LCD_OUT"
}

# After a CRT game the CRT is already on, only:
# 1. CRT -> 640x480  (via _crt_set_15khz_direct)
restore_after_game() {
	detect_outputs 2>/dev/null || true # idempotent re-detection; see apply_dual_layout
	export DISPLAY="${DISPLAY:-:0}"

	local crt
	# set --scale-from 640x480, screen 640x480, primary on the detached
	crt="${CRT_OUT:-}"
	if [ -z "$crt" ] && [ -z "$LCD_OUT" ]; then
		crt="${CRT_PRESUMED_OUT}"
	fi
	if [ -n "$crt" ]; then
		# 1. CRT to 640x480 (15kHz modeline)
		_crt_set_15khz_direct "$crt"

		if [ -n "$LCD_OUT" ]; then
			local lcd _cm
			lcd=$(_lcd_native "$LCD_OUT")
			_cm=$(_xrandr_active_mode "$crt" name)
			if [ "$_cm" = "320x240" ]; then
				xrandr --display "$DISPLAY" \
					--output "$LCD_OUT" --mode "$lcd" --scale-from 640x480 --pos 0x0 \
					--output "$crt" --primary --mode "320x240" --scale 2x2 --pos 0x0 2>/dev/null || true # best-effort; see above
			else
				# CRT flag-only (primary/transform/pos): its desktop mode was
				# just applied by _crt_set_15khz_direct via the engine handle.
				xrandr --display "$DISPLAY" \
					--output "$LCD_OUT" --mode "$lcd" --scale-from 640x480 --pos 0x0 \
					--output "$crt" --primary --transform none --pos 0x0 2>/dev/null || true # best-effort; see above
			fi
			_owner_desktop_transform_guard "$crt" || true # mixed mode+scale requests can leak the LCD scale onto the CRT CRTC (NVIDIA batch-lie, 2026-08-28) — cached read-back, standalone repair
			_ensure_fb_640 "$crt" # clone FB invariant (see helper)
			echo "CRT-DUAL-CRT: restore dual CRT=$crt@640x480, LCD=$LCD_OUT upscaled ($lcd)"
		else
			_crt_set_primary "$crt"
			echo "CRT-DUAL-CRT: restore CRT-only=$crt@640x480"
		fi
	elif [ -n "$LCD_OUT" ]; then
		lcd=$(_lcd_native_primary_takeover)
		echo "CRT-DUAL-CRT: restore LCD-only=$LCD_OUT@$lcd native primary"
	fi
	_kill_unmanaged_outputs "$crt" "$LCD_OUT"
}

# (monitor plugged/unplugged live — no reboot).
# untouched.
# glitch-free and flips HDMI in ~1s there.
_layout_fingerprint() {
	_gpu_adapter || return 1
	_impl_fingerprint
}

# black with no CRTC).
#
_layout_state_parse() { # "OUT|mode|primary|xpos" per output + "SCREEN|WxH" — ONE --current read
	xrandr --current 2>/dev/null | awk '
		/^Screen / { if (match($0, /current [0-9]+ x [0-9]+/)) {
			split(substr($0, RSTART, RLENGTH), s, /[ x]+/)
			print "SCREEN|" s[2] "x" s[3] "||"
		}
		next }
		/^[A-Za-z]/ {
			if (name != "") print name "|" ((conn && mode != "") ? mode : "none") "|" prim "|" xpos
			name = $1; conn = ($2 == "connected"); prim = ($0 ~ / primary/) ? 1 : 0; mode = ""; xpos = ""
			if (match($0, /[0-9]+x[0-9]+\+[0-9]+\+[0-9]+/)) {
				split(substr($0, RSTART, RLENGTH), p, "+")
				xpos = p[2]
			}
			next
		}
		conn && /\*/ { mode = $1 }
		END { if (name != "") print name "|" ((conn && mode != "") ? mode : "none") "|" prim "|" xpos }
	'
}


_layout_convergent() {
	local _crt_outs _lcd_outs _rows _row _o _act _prim _xpos
	[ -f "$CRT_DUAL_STATE_DIR/detect-state" ] || return 1 # nothing classified yet -> not converged
	eval "$(_read_detect_state_roles)"                    # sets _crt_outs/_lcd_outs from the file
	_rows=$(_layout_state_parse)
	[ -n "$_rows" ] || return 1

	local _crt_mode _dn
	_dn=$(_desktop_mode_name 2>/dev/null)
	_crt_mode=$(awk '{print $1}' "$CRT_DUAL_STATE_DIR/crt-desktop-mode" 2>/dev/null)
	# Desktop convergence = the family's own desktop name (adapter truth:
	# "640x480i" on modesetting, bare "640x480" on NVIDIA where the driver
	# aliases the conf modeline — verified 2026-08-28 GTX 970). The bare
	# value is safe here because it can ONLY be the desktop on a family
	# whose adapter declares it: DefaultModes False keeps the VESA pool off
	# the classified analog port, and on modesetting the desktop name is
	# suffixed so a bare DoubleScan never equals $_dn.
	_crt_desktop_ok() {
		[ -n "$1" ] || return 1
		[ "$1" = "$_dn" ] && return 0
		[ -n "$_crt_mode" ] && [ "$1" = "$_crt_mode" ] && return 0
		# SR-* name from the mode-pool injector (hotplug after LCD-only
		# boot, root cause 2026-08-29): the API-named mode is the SAME
		# timing as the conf modeline — the desktop IS up. Compare by
		# timing signature (SR-1_640x480@60.00i -> 640x480@60), never by
		# exact name.
		_okname=$(printf '%s' "$1" | sed -E 's/^SR-[0-9]+_//; s/@[0-9.]+i?$//')
		_dn_base=$(printf '%s' "$_dn" | sed -E 's/i$//')
		[ "$_okname" = "$_dn_base" ] && return 0
		return 1
	}

	local _crt_prim_ok=0
	for _o in $_crt_outs $_lcd_outs; do
		_row=$(printf '%s\n' "$_rows" | grep "^$_o|")
		_act=$(echo "$_row" | cut -d'|' -f2)
		_prim=$(echo "$_row" | cut -d'|' -f3)
		_xpos=$(echo "$_row" | cut -d'|' -f4)
		case " $_crt_outs " in *" $_o "*)
			_crt_desktop_ok "$_act" || return 1
			[ -n "$_xpos" ] && [ "$_xpos" = "0" ] || return 1 # stale dual puts it right of the gone LCD (black, verified 2026-08-11)
			[ "$_prim" = "1" ] && _crt_prim_ok=1              # batocera-resolution anchor (configgen reads ONLY the primary at gameStart)
			;;
		esac
		case " $_lcd_outs " in *" $_o "*)
			# 2026-08-12) ...
			[ -n "$_act" ] && [ "$_act" != "none" ] || return 1
			[ -n "$_xpos" ] && [ "$_xpos" = "0" ] || return 1
			;;
		esac
	done
	# the LCD legitimately clones at 640x480.
	if [ -z "${_crt_outs// /}" ]; then
		for _o in $_lcd_outs; do
			local _want_l
			_want_l=$(_lcd_native "$_o" 2>/dev/null)
			[ -n "$_want_l" ] || _want_l="1920x1080"
			_row=$(printf '%s\n' "$_rows" | grep "^$_o|")
			[ "$(echo "$_row" | cut -d'|' -f2)" = "$_want_l" ] || return 1
		done
		# one display on every verified topology.
		local _lcd0 _scr
		_lcd0=$(printf '%s' "$_lcd_outs" | awk '{print $1}')
		_scr=$(printf '%s\n' "$_rows" | grep "^SCREEN|" | cut -d'|' -f2)
		[ "$_scr" = "$(_lcd_native "$_lcd0" 2>/dev/null || echo 1920x1080)" ] || return 1
	fi
	# dual must be 640x480 screen (clone) — not native 1920x1080 (seen live: gameStop left 1920 with ES 640 in corner)
	if [ -n "$_crt_outs" ] && [ -n "$_lcd_outs" ]; then
		_scr=$(printf '%s\n' "$_rows" | grep "^SCREEN|" | cut -d'|' -f2)
		[ "$_scr" = "640x480" ] || return 1
	fi
	# ...the CRT holds the primary when present...
	if [ -n "$_crt_outs" ] && [ "$_crt_prim_ok" != "1" ]; then
		return 1 # stock ES re-marks the first checker-sorted output primary on restart
	fi
	while IFS='|' read -r _o _act _prim _xpos _rest; do
		[ -n "$_o" ] || continue
		[ "$_o" = "SCREEN" ] && continue # synthetic size row, not an output
		case " $_crt_outs $_lcd_outs " in *" $_o "*) continue ;; esac
		[ "$_act" = "none" ] || return 1
		[ "$_prim" = "0" ] || return 1 # phantom primary on unmanaged output (seen live 2026-08-25 unplug: DVI-I-1 primary with act none)
	done <<<"$_rows"
	return 0
}

_read_detect_state_roles() { # emit _crt_outs=/​_lcd_outs= assignments from detect-state
	[ -f "$CRT_DUAL_STATE_DIR/detect-state" ] || return 0
	local _k _v
	while IFS='=' read -r _k _v; do
		case "$_k" in
		CRT_OUTS) printf '_crt_outs="%s"\n' "$_v" ;;
		LCD_OUTS) printf '_lcd_outs="%s"\n' "$_v" ;;
		esac
	done <"$CRT_DUAL_STATE_DIR/detect-state"
}

layout_apply_if_changed() {
	export DISPLAY="${DISPLAY:-:0}"

	local fp old
	fp=$(_layout_fingerprint)
	[ -n "$fp" ] || return 1

	if _layout_convergent; then
		echo "$fp" >"$CRT_DUAL_STATE_DIR/layout-fp" # keep the debug fp aligned
		return 0                                    # layout already current — no xrandr writes
	fi

	exec 9>"$CRT_DUAL_STATE_DIR/layout.lock" 2>/dev/null || return 1
	flock -x -w 10 9 2>/dev/null || {
		exec 9>&- 2>/dev/null || true # release the fd regardless
		return 1
	}
	old=""
	[ -f "$CRT_DUAL_STATE_DIR/layout-fp" ] && old=$(cat "$CRT_DUAL_STATE_DIR/layout-fp" 2>/dev/null)
	if _layout_convergent; then
		[ "$old" = "$fp" ] || echo "$fp" >"$CRT_DUAL_STATE_DIR/layout-fp"
		flock -u 9 2>/dev/null || true
		exec 9>&- 2>/dev/null || true
		return 0
	fi

	if ! _apply_dual_layout_unlocked 2>/dev/null; then
		flock -u 9 2>/dev/null || true
		exec 9>&- 2>/dev/null || true
		return 1 # apply failed — fingerprint NOT updated, next check retries
	fi
	fp=$(_layout_fingerprint)
	# failure so the next wake-up retries.
	if ! _layout_convergent; then
		flock -u 9 2>/dev/null || true
		exec 9>&- 2>/dev/null || true
		return 1 # not converged — fingerprint NOT updated, next check retries
	fi
	echo "$fp" >"$CRT_DUAL_STATE_DIR/layout-fp"
	flock -u 9 2>/dev/null || true
	exec 9>&- 2>/dev/null || true
	return 0
}
_owner_es_resize() {
	local _wid _crt _lcd _mode _w _h
	_wid=$(xdotool search --class emulationstation 2>/dev/null | head -1)
	[ -z "$_wid" ] && return 0
	_crt="$CRT_OUT"
	if [ -n "$_crt" ]; then
		_w=640; _h=480
	else
		_lcd="$LCD_OUT"
		_mode=$(xrandr --current 2>/dev/null | sed -n "/^$_lcd connected/,/^[^ ]/p" | grep '\*' | head -1 | awk '{print $1}')
		_w=${_mode%x*}; _h=${_mode#*x}
		[ -z "$_w" ] && { _w=1920; _h=1080; }
	fi
	xdotool windowsize "$_wid" "$_w" "$_h" 2>/dev/null || true
	xdotool windowmove "$_wid" 0 0 2>/dev/null || true
	log "ES resized to ${_w}x${_h}"
}
_owner_display_readback() {
	local _txt _o _line _cur _pos _m _act
	_txt=$(xrandr --current 2>/dev/null)
	log "readback screen=$(echo "$_txt" | sed -n 's/^Screen 0:.* current \([0-9]* x [0-9]*\).*/\1/p' | tr -d ' ')"
	while IFS= read -r _line; do case "$_line" in *connected*) _o=$(echo "$_line" | awk '{print $1}'); _pos=$(echo "$_line" | awk '{for(i=1;i<=NF;i++) if($i ~ /^[0-9]+x[0-9]+\+[0-9]+\+[0-9]+$/){print $i; exit}}'); _cur="$_o:pos=$_pos";; [[:space:]]*[0-9]x[0-9]*) if [ -n "${_cur:-}" ]; then _act=$(echo "$_line" | awk '{for(i=2;i<=NF;i++) if($i ~ /\*/){print $i; exit}}'); if [ -n "$_act" ]; then _m=$(echo "$_line" | awk '{print $1}'); log "readback   $_cur mode=$_m rates=$_act"; _cur=""; fi; fi;; esac; done <<<"$_txt"
}

apply_via_engine() {
	# libs are sourced by the main bootstrap (every dispatch path needs
	# them now — gameStart target branches included)
	if ! command -v layout_apply_if_changed >/dev/null 2>&1; then
		if ! command -v _apply_dual_layout_unlocked >/dev/null 2>&1; then
			log "FAIL: apply engine not available — loud failure"
			return 2
		fi
	fi
	command -v detect_gpu >/dev/null 2>&1 && detect_gpu 2>/dev/null || true
	# Topology is FROZEN while the game guard is up: the watcher sleeps
	# during a session (layout-watch.sh: game-guard branch), so between
	# gameStart and gameStop no hotplug can have happened. Re-detecting
	# here costs ~1.2s (demote debounce sleep 1 + per-port sysfs/xrandr
	# reads) for zero new information — the last detect-state is the
	# truth. The gameStop caller passes --no-detect; hotplug callers
	# (watcher) do NOT, so they keep the fresh detect that IS their
	# event handling. Fallback: if the state file is missing, detect
	# anyway (measured 2026-08-28: detect_outputs = 1.21s, gameStop
	# ~3.5s total, of which ~2.4s was double detect).
	if [ "$_no_detect" = "1" ] && [ -f "$DETECT_STATE" ]; then
		log "detect skipped (--no-detect, topology frozen — reusing detect-state)"
	else
		command -v detect_outputs >/dev/null 2>&1 && detect_outputs 2>/dev/null || true
		command -v crt_probe >/dev/null 2>&1 && crt_probe 2>/dev/null || true
	fi
	CRT_OUT="$(_state_val CRT_OUT)"
	if [ -z "$CRT_OUT" ]; then
		_lcd_tmp="$(_state_val LCD_OUT)"
		if [ -z "$_lcd_tmp" ]; then
			CRT_OUT="$(_state_val CRT_PRESUMED_OUT)"
		fi
	fi
	LCD_OUT="$(_state_val LCD_OUT)"
	log "engine apply: want=$want crt=$CRT_OUT lcd=$LCD_OUT (detect refreshed)"
	local _rc=0
	if layout_apply_if_changed 2>/dev/null; then
		log "engine converge-or-apply: applied"
	else
		_rc=$?
		log "engine converge-or-apply: not converged (rc=$_rc)"
	fi
	_owner_es_resize || true
	command -v _es_focus_restore >/dev/null 2>&1 && _es_focus_restore 2>/dev/null || {
		local _wid _focus
		_wid=$(xdotool search --class emulationstation 2>/dev/null | head -1)
		if [ -n "$_wid" ]; then
			_focus=$(xdotool getwindowfocus 2>/dev/null | awk '{print $NF}')
			[ "$_focus" != "$_wid" ] && xdotool windowfocus "$_wid" 2>/dev/null || true
		fi
	}
	_owner_display_readback || true
	log "engine apply done (detect-state: $(tr '\n' ' ' <"$STATE_DIR/detect-state" 2>/dev/null))"
	return $_rc
}

# Main — only when executed, not when sourced
if [[ "${BASH_SOURCE[0]:-}" != "${0:-}" ]]; then
	return 0 2>/dev/null || true
fi
# Lib bootstrap — BEFORE the want dispatch. Every dispatch path
# (_solo-prep takeover, apply_via_engine's layout apply) resolves mode
# names through the display lib; sourcing it lazily left branches running
# on undefined functions (rc 127 → empty names → the "--mode ''" lottery
# batch — FAIL log artifact + black-screen risk; trace 2026-08-30 15:19:39).
_self_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
for _lib in "$_self_dir/../lib/gpu-lib.sh" "/userdata/system/crt-dual/src/lib/gpu-lib.sh" "$(dirname "$_self_dir")/lib/gpu-lib.sh"; do
	[ -r "$_lib" ] && source "$_lib" 2>/dev/null && break
done
for _lib in "$_self_dir/../lib/display-lib.sh" "/userdata/system/crt-dual/src/lib/display-lib.sh" "$(dirname "$_self_dir")/lib/display-lib.sh"; do
	[ -r "$_lib" ] && source "$_lib" 2>/dev/null && break
done
want="dual"
_no_detect=0
_check_only=0
_solo_target=""
for arg in "$@"; do case "$arg" in --want) shift; WANT_FILE="$1";; --state-dir) shift; STATE_DIR="$1";; --no-detect) _no_detect=1;; --check) _check_only=1;; --solo-prep) shift; _solo_target="$1";; esac done
[ -f "$WANT_FILE" ] && want="$(cat "$WANT_FILE" 2>/dev/null | head -1 | tr -d ' \n' || echo dual)"
[ -z "$want" ] && want="dual"
if [ ! -f "$DETECT_STATE" ]; then
	log "no detect-state at $DETECT_STATE — run detect_outputs first"
	exit 1
fi
if [ "$_check_only" = "1" ]; then
	# Read-only converge probe for the watcher settle window (2026-09-03):
	# NO detect (sysfs debounce + AMD edid --prop are display contact),
	# NO probe, NO apply, NO ES handover — the oracle reads detect-state
	# + `xrandr --current` (R class, cached, never a force-requery) only.
	# rc 0 = converged, rc 1 = broken. Quiet by contract: the rc IS the
	# signal, the watcher logs the re-request when it fires one.
	command -v detect_gpu >/dev/null 2>&1 && detect_gpu 2>/dev/null || true
	export DISPLAY="${DISPLAY:-:0}"
	if _layout_convergent 2>/dev/null; then exit 0; else exit 1; fi
fi
# RGS-15KHZ-EXT (solo-launch prep, 2026-09-13): per-launch engine work in
# dual = ONLY turn off the display the game will NOT use, then stock (+ the
# patched launcher) manages the solo session end to end. The gameStop
# restore belongs to the WATCHER (game-ended emitter → want=dual →
# apply_dual_layout), never to a launch hook. Loud rc, no fallback chain.
if [ -n "$_solo_target" ]; then
	command -v detect_gpu >/dev/null 2>&1 && detect_gpu 2>/dev/null || true
	export DISPLAY="${DISPLAY:-:0}"
	CRT_OUT="$(_state_val CRT_OUT)"
	LCD_OUT="$(_state_val LCD_OUT)"
	if [ -z "$CRT_OUT" ] || [ -z "$LCD_OUT" ]; then
		log "solo-prep: not dual (crt=${CRT_OUT:-none} lcd=${LCD_OUT:-none}) — nothing to do"
		exit 0
	fi
	if [ "$_solo_target" = "crt" ]; then
		xrandr --output "$LCD_OUT" --off || { log "solo-prep: LCD $LCD_OUT off FAILED"; exit 1; }
		log "solo-prep: LCD $LCD_OUT off — CRT-only session (stock+patch own the launch)"
	else
		# Two calls, measured 2026-09-14 (AMD R9 270X): the X server can hold
		# a stale mode record (star on 1920x1080) while the live framebuffer
		# is still the dual-clone 640x480 — in that state the single
		# "--primary --auto" call is a silent no-op (X believes the target is
		# already active), configgen reads the 640x480 geometry and RA lowers
		# the panel. Turning the LCD off frees the CRTC, the re-add from a
		# clean state is a real reprogram at the EDID preferred mode.
		_err=$(xrandr --output "$CRT_OUT" --off --output "$LCD_OUT" --off 2>&1) || { log "solo-prep: outputs off FAILED: $_err"; exit 1; }
		_err=$(xrandr --output "$LCD_OUT" --primary --auto 2>&1) || { log "solo-prep: LCD takeover FAILED: $_err"; exit 1; }
		log "solo-prep: CRT $CRT_OUT off, LCD $LCD_OUT primary native — LCD-only session (stock owns the launch)"
	fi
	exit 0
fi
CRT_OUT="$(_state_val CRT_OUT)"
if [ -z "$CRT_OUT" ]; then
	_lcd_tmp="$(_state_val LCD_OUT)"
	if [ -z "$_lcd_tmp" ]; then
		CRT_OUT="$(_state_val CRT_PRESUMED_OUT)"
	fi
fi
LCD_OUT="$(_state_val LCD_OUT)"
log "want=$want crt=$CRT_OUT lcd=$LCD_OUT"
if [ -f "$STATE_DIR/profile" ] || [ -f "/tmp/crt-dual-mode" ]; then
	log "game guard active — yield (no apply)"
	exit 0
fi
case "$want" in
dual|both|all) apply_via_engine; exit $? ;;
*)
	log "unknown want '$want' — treating as dual"
	apply_via_engine; exit $? ;;
esac
exit 0
