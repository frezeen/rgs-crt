#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
# Copyright (C) 2026 FreZeeN
# Part of crt-dual — https://github.com/frezeen
# display-apply.sh — transition (ADR-002): compare reality with the plan;
# if different, ONE xrandr invocation, then verify the kernel truth.
# Mismatch after the batch = one bounded repair (off->on per output), one
# re-verify, then LOUD failure. No retry ladder, no alternate path.
#
# Usage:
#   display-apply.sh            plan + verdict (NO writes; default = dry)
#   display-apply.sh --apply    do the writes (batch + verify + repair)
#   display-apply.sh --plan     print the plan only
set -uo pipefail
export DISPLAY="${DISPLAY:-:0}" # the daemon is setsid-detached: every xrandr call needs it explicitly
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SYSFS="${CRT_DUAL_SYSFS:-/sys/class/drm}"
# CRTC ownership truth (modetest; CRT_DUAL_MODETEST = test seam). Kernel
# `enabled` alone means "encoder attached" — see crtc-owner.sh.
[ -r "$HERE/crtc-owner.sh" ] && . "$HERE/crtc-owner.sh"

# ── una lettura per FASE, non una per domanda ──────────────────────────────
# Su dce_v6 ogni `--current` costa ~150 ms (misurato 2026-10-18: un singolo
# apply ne faceva 22 = 2,9 s, una uscita gioco 45 — ed erano la finestra in cui
# lo schermo resta nero). La cache vive nel processo corrente, e le pipeline
# girano in subshell: quindi la riempie _state_load(), chiamata DIRETTAMENTE,
# e i lettori la consumano. Se manca, ogni lettore legge davvero: la cache e'
# un'ottimizzazione, mai un modo per rispondere male.
_XOUT=""
_DRMLIST=""
_STATE_UNKNOWN=""
_read_x() { timeout 5 env DISPLAY="${DISPLAY:-:0}" xrandr --current 2>/dev/null; }
_x() { printf '%s\n' "${_XOUT:-$(_read_x)}"; }
_drm_list() { printf '%s\n' "${_DRMLIST:-$(bash "$HERE/display-detect.sh" --list 2>/dev/null)}"; }
_state_load() {
	[ -n "${_XOUT:-}" ] || _XOUT="$(_read_x)"
	[ -n "${_DRMLIST:-}" ] || _DRMLIST="$(bash "$HERE/display-detect.sh" --list 2>/dev/null)"
	# Stato illeggibile = non si decide NULLA per output (si riasserisce il
	# piano): una lettura fallita non deve diventare una scrittura.
	if [ -n "${_XOUT:-}" ]; then _STATE_UNKNOWN=""; else _STATE_UNKNOWN=1; fi
}
# Ogni scrittura invalida: la verifica deve leggere il DOPO, non il prima.
_refresh() { _XOUT=""; _DRMLIST=""; }
_cur_mode() { _x | sed -n "/^$1 connected/,/^[^ ]/p" | awk '$0 ~ /\*/ { print $1; exit }'; }
_cur_pos() { _x | awk -v o="$1" '$1 == o { for (i = 1; i <= NF; i++) if ($i ~ /^[0-9]+x[0-9]+\+[0-9]+\+[0-9]+$/) { split($i, p, "+"); print p[2] "x" p[3]; exit } }'; }
_cur_size() { _x | awk -v o="$1" '$1 == o { for (i = 1; i <= NF; i++) if ($i ~ /^[0-9]+x[0-9]+\+[0-9]+\+[0-9]+$/) { split($i, p, "+"); print p[1]; exit } }'; }
# La dimensione che xrandr DEVE riportare per una gamba: con --scale-from e'
# la sorgente dello scale (il pannello dice 640x480 mentre il modo e' 1920x1080),
# senza e' la dimensione del modo (il `i` di 640x480i non e' una dimensione).
_want_size() { if [ -n "$1" ] && [ "$1" != "-" ]; then printf '%s\n' "$1"; else printf '%s\n' "${2%i}"; fi; }
_cur_prim() { _x | awk -v o="$1" '$1 == o { print ($0 ~ / primary/) ? "primary" : "-"; exit }'; }
_screen() { _x | sed -n 's/^Screen 0:.*current \([0-9]* x [0-9]*\).*/\1/p' | tr -d ' '; }
_drm_of_x() { _drm_list | awk -F'\t' -v x="$1" '$3 == x { print $1; exit }'; }
_enabled() { local d; d=$(_drm_of_x "$1"); [ -n "$d" ] && cat "$SYSFS/card0-$d/enabled" 2>/dev/null; }
_all_x() { _x | awk '$2 == "connected" { print $1 }'; }
_x_name_for_drm() { # $1 = DRM connector -> its X output name (exact, then slot-stripped)
	local drm="$1" x
	x=$(printf '%s' "$drm" | sed -E 's/-[A-Za-z]-/-/')
	if _x | awk -v a="$drm" '$1 == a { f = 1 } END { exit !f }'; then
		printf '%s\n' "$drm"
		return 0
	fi
	if _x | awk -v b="$x" '$1 == b { f = 1 } END { exit !f }'; then
		printf '%s\n' "$x"
		return 0
	fi
	return 1
}
_planned() { printf '%s\n' "$plan" | awk -F'\t' -v o="$1" '$1 == o { f = 1 } END { exit !f }'; }
XCONF="${CRT_DUAL_XCONF:-/etc/X11/xorg.conf.d/99-crt.conf}"
_modes() { _x | sed -n "/^$1 connected/,/^[^ ]/p" | awk 'NF >= 2 && $1 ~ /^[0-9]/ { print }'; }
_ensure_mode() { # $1 output, $2 mode — re-add the conf modeline when X lost it
	# dce_v6 mode-pool loss after an LCD excursion (root cause 2026-08-29,
	# seen again in the ADR-002 swap 2026-09-19): the generated conf IS the
	# source of truth; re-add its Modeline dynamically (no literal timing).
	local x="$1" m="$2" line params
	_modes "$x" | awk -v m="$m" '$1 == m { f = 1 } END { exit !f }' && return 0
	line=$(grep -m1 -E "^[[:space:]]*Modeline[[:space:]]+\"$m\"" "$XCONF" 2>/dev/null)
	[ -n "$line" ] || {
		echo "display-apply: mode '$m' missing on $x and no Modeline in $XCONF" >&2
		return 1
	}
	params=$(printf '%s\n' "$line" | sed -E 's/^[[:space:]]*Modeline[[:space:]]+"[^"]+"[[:space:]]+//')
	read -r -a _parr <<<"$params"
	xrandr --newmode "$m" "${_parr[@]}" 2>/dev/null || true # already known = fine
	xrandr --addmode "$x" "$m" 2>/dev/null || {
		echo "display-apply: --addmode '$m' on $x failed" >&2
		return 1
	}
	_refresh # il pool e' cambiato: la cache non vale piu'
	echo "display-apply: re-added mode '$m' on $x from $XCONF (mode-pool loss)"
	return 0
}
_unplanned_enabled() { # connectors whose CURRENT encoder HOLDS A CRTC, outside the plan
	# Kernel `enabled` only says an encoder is attached (drm_sysfs.c) —
	# the CRTC id comes from modetest (crtc-owner.sh). An encoder-only
	# attach has nothing RandR can free, so it is NOT a mismatch (the
	# 2026-09-22 tester report: DVI-D-1 enabled with no CRTC failed every
	# apply and the bounded repair blinked the tube). Unknown truth (tool
	# missing/broken) falls back to the old, louder behavior.
	local f drm x crtc
	for f in "$SYSFS"/card*-*/enabled; do
		[ -f "$f" ] || continue
		[ "$(cat "$f" 2>/dev/null)" = "enabled" ] || continue
		drm=$(basename "$(dirname "$f")")
		drm=${drm#card*-}
		crtc="?"
		command -v crtc_of >/dev/null 2>&1 && crtc=$(crtc_of "$drm")
		[ -z "$crtc" ] && continue # no CRTC: encoder-only attach, not a holder
		x=$(_x_name_for_drm "$drm" 2>/dev/null) || x=""
		if [ -n "$x" ]; then
			_planned "$x" || printf '%s\n' "$x"
		else
			printf '?%s\n' "$drm" # no X output: cannot free via RandR (see _ignored_holders for the conf-ignored class)
		fi
	done
}
_encoder_only_holders() { # enabled+disconnected with a KNOWN-empty CRTC: a note, never a mismatch
	local f drm crtc
	command -v crtc_of >/dev/null 2>&1 || return 0
	for f in "$SYSFS"/card*-*/enabled; do
		[ -f "$f" ] || continue
		[ "$(cat "$f" 2>/dev/null)" = "enabled" ] || continue
		drm=$(basename "$(dirname "$f")")
		drm=${drm#card*-}
		[ "$(cat "$(dirname "$f")/status" 2>/dev/null)" = "disconnected" ] || continue
		crtc=$(crtc_of "$drm")
		[ -z "$crtc" ] && printf '%s\n' "$drm"
	done
}
_ignored_by_conf() { # $1 = connector name — true when the generated conf ignores it
	local _id="$1" _f="$XCONF"
	[ -f "$_f" ] || return 1
	awk -v id="$_id" '
		/^[[:space:]]*Section[[:space:]]+"Monitor"/ { ins = 1; hit = 0; ign = 0; next }
		/^[[:space:]]*EndSection/ { if (ins && hit && ign) ok = 1; ins = 0; next }
		ins && /^[[:space:]]*Identifier/ { if (index($0, "\"" id "\"")) hit = 1; next }
		ins && hit && /[Oo]ption[[:space:]]+"[Ii]gnore"[[:space:]]+"true"/ { ign = 1 }
		END { exit !ok }
	' "$_f" 2>/dev/null
}
_ignored_holders() { # '?DRM' entries: conf-ignored AND disconnected AND no X name — unactionable by construction
	# (AMD boot 2026-09-21 after the Intel phase: DVI-D-1 disconnected with a
	# stale encoder binding and Option "ignore" in the conf; counted as a
	# mismatch it failed every apply → the bounded repair off->on'ed BOTH
	# outputs at every event, twice per boot, the 2nd cycle caused only by
	# this. The conf is regenerated pre-X from live truth, so the match
	# follows the topology; anything not exactly this stays LOUD.)
	# RESIDUAL (ADR-002, watch): if such a connector really holds a CRTC,
	# RandR still cannot free it and this stays a note; the CRTC truth is
	# visible per connector in diag-dump (crtc=...).
	local f drm y
	for f in "$SYSFS"/card*-*/enabled; do
		[ -f "$f" ] || continue
		[ "$(cat "$f" 2>/dev/null)" = "enabled" ] || continue
		drm=$(basename "$(dirname "$f")")
		drm=${drm#card*-}
		[ "$(cat "$(dirname "$f")/status" 2>/dev/null)" = "disconnected" ] || continue
		_x_name_for_drm "$drm" >/dev/null 2>&1 && continue # has an X handle: normal unplanned path frees it
		y=$(printf '%s' "$drm" | sed -E 's/-[A-Za-z]-/-/')
		if _ignored_by_conf "$drm" || _ignored_by_conf "$y"; then
			printf '?%s\n' "$drm"
		fi
	done
}
_actionable_unplanned() { # _unplanned_enabled minus the conf-ignored '?' class
	local _raw _ign _it _out=""
	_raw=$(_unplanned_enabled)
	[ -n "$_raw" ] || return 0
	_ign=$(_ignored_holders)
	for _it in $_raw; do
		case "$_it" in
		'?'*)
			case " $_ign " in *" $_it "*) continue ;; esac
			;;
		esac
		_out="$_out$_it"$'\n'
	done
	printf '%s' "$_out"
}
STATE_DIR="${CRT_DUAL_STATE_DIR:-/tmp/crt-dual}"
_write_desktop_state() { # single writer of the analog desktop name (the model reads it)
	local analog mode line rate
	analog=$(_drm_list | awk -F'\t' '$2 == "analog" { print $3; exit }')
	[ -n "$analog" ] || return 0
	mode=$(_cur_mode "$analog")
	[ -n "$mode" ] || return 0
	line=$(_x | sed -n "/^$analog connected/,/^[^ ]/p" | awk -v m="$mode" '$1 == m { print; exit }')
	rate=$(printf '%s\n' "$line" | awk '{ for (i = 2; i <= NF; i++) if ($i ~ /\*/) { gsub(/[*+]/, "", $i); print $i; exit } }')
	printf '%s\n' "${mode}${rate:+ $rate}" >"$STATE_DIR/crt-desktop-mode" 2>/dev/null || true
}

_es_follow() {
	if [ -n "${CRT_DUAL_ES_FOLLOW_CMD:-}" ]; then bash -c "$CRT_DUAL_ES_FOLLOW_CMD"; return $?; fi
	command -v xdotool >/dev/null 2>&1 || return 0
	local sw wid ww
	sw=$(printf '%s\n' "${plan:-}" | awk -F'\t' '$1 == "SCREEN" { print $2; exit }')
	# invocata da sola (--es-follow) non c'e' un piano: la dimensione buona e'
	# quella dello schermo ADESSO — la stessa che il piano avrebbe chiesto.
	[ -n "$sw" ] || sw=$(_screen)
	case "$sw" in '' | none | *[!0-9x]*) return 0 ;; esac
	wid=$(DISPLAY="${DISPLAY:-:0}" xdotool search --class emulationstation 2>/dev/null | head -1)
	[ -n "$wid" ] || return 0
	ww=$(DISPLAY="${DISPLAY:-:0}" xdotool getwindowgeometry "$wid" 2>/dev/null | sed -n 's/.*Geometry: //p')
	if [ -n "$ww" ] && [ "$ww" != "$sw" ]; then
		DISPLAY="${DISPLAY:-:0}" xdotool windowsize "$wid" "$sw" 2>/dev/null || true
		# VERIFICA, non fede: ES impone la propria geometria (openbox onora il
		# suo hint) e il resize resta senza effetto — misurato 2026-10-18: la
		# finestra e' rimasta 1920x1080 dopo il windowsize, mentre il log
		# dichiarava "followed the screen". Un log che dichiara un effetto non
		# avvenuto e' un difetto: si rilegge e si scrive quello che e' vero.
		local _ww2
		_ww2=$(DISPLAY="${DISPLAY:-:0}" xdotool getwindowgeometry "$wid" 2>/dev/null | sed -n 's/.*Geometry: //p')
		if [ -n "$_ww2" ] && [ "$_ww2" = "$sw" ]; then
			printf 'RECONCILE [%s]: apply: ES window %s -> %s (followed the screen)\n' \
				"$(date +%H:%M:%S)" "$ww" "$sw" \
				>>"${CRT_DUAL_RECONCILE_LOG:-/userdata/system/logs/display-reconcile.log}" 2>/dev/null || true
		else
			printf 'RECONCILE [%s]: apply: ES window %s -> %s NOT applied (still %s) — the reconciler owns the repair\n' \
				"$(date +%H:%M:%S)" "$ww" "$sw" "${_ww2:-?}" \
				>>"${CRT_DUAL_RECONCILE_LOG:-/userdata/system/logs/display-reconcile.log}" 2>/dev/null || true
		fi
	fi
	# (Il jiggle col MOUSE e' stato rimosso il 2026-10-18: due prove su due
	# mostrano che ES non lo processa — ne' sulla pagina stantia ne' sullo
	# screensaver. Lo stimolo giusto e' un tasto, ed e' nel riconciliatore,
	# GATED dal contenuto: mandarlo a ogni passata farebbe navigare ES.)
}

# La spinta a ES da sola: la usa il riconciliatore quando l'apply NON ha
# scritto (delta vuoto) ma la sessione e' finita — il frame stantio di ES si
# sblocca con un input, e quello e' il caso in cui il menu resta nero.
if [ "${1:-}" = "--es-follow" ]; then _es_follow; exit $?; fi

plan=$(bash "$HERE/display-model.sh") || exit 1
[ "${1:-}" = "--plan" ] && { printf '%s\n' "$plan"; exit 0; }
mode="${1:-dry}"

# reality vs plan — una lettura di stato per tutta la fase (misurato:
# senza questa, questo blocco ne faceva una per output per domanda)
# _leg_mismatch <name> <on|off> <mode> <primary|-> <pos> <scale|->
# -> il motivo del disaccordo, niente se la gamba e' a piano. UNA funzione per
# il delta e per la verifica: erano due confronti diversi, e la verifica non
# guardava primary/pos/scala (una gamba puo' essere "verde" e sbagliata).
_leg_mismatch() {
	local name="$1" on="$2" mode="$3" prim="$4" pos="$5" scale="$6" cm cs want
	[ -n "${_STATE_UNKNOWN:-}" ] && { printf 'unknown-state'; return; }
	cm=$(_cur_mode "$name")
	if [ "$on" = "on" ]; then
		[ "$cm" = "$mode" ] || { printf 'mode(%s!=%s)' "$cm" "$mode"; return; }
		[ "$(_cur_prim "$name")" = "$prim" ] || { printf 'primary'; return; }
		[ "$(_cur_pos "$name")" = "$pos" ] || { printf 'pos'; return; }
		want=$(_want_size "$scale" "$mode")
		cs=$(_cur_size "$name")
		[ "$cs" = "$want" ] || { printf 'size(%s!=%s)' "$cs" "$want"; return; }
		[ "$(_enabled "$name")" = "enabled" ] || { printf 'kernel'; return; }
	else
		[ -z "$cm" ] || { printf 'should-be-off'; return; }
		[ "$(_enabled "$name")" = "disabled" ] || { printf 'kernel-on'; return; }
	fi
}
_state_load
# mismatch = cosa discorda (per il verdetto e per il log).
# _delta    = le GAMBE che entrano nel batch. Sono la stessa cosa tranne per
#             SCREEN, che e' una POST-CONDIZIONE e non una gamba: non aggiunge
#             mai nulla al batch (P2b). Con lo stato illeggibile il delta e'
#             tutto il piano: non si decide per output su una lettura fallita.
mismatch=""
_delta=""
while IFS=$'\t' read -r name f1 f2 f3 f4 f5; do
	[ "$name" = "SCREEN" ] && continue
	_why=$(_leg_mismatch "$name" "${f1:-}" "${f2:-}" "${f3:-}" "${f4:-0x0}" "${f5:--}")
	[ -n "$_why" ] && { mismatch="$mismatch $name:$_why"; _delta="$_delta $name"; }
done <<<"$plan"
want_screen=$(printf '%s\n' "$plan" | awk -F'\t' '$1 == "SCREEN" { print $2 }')
if [ "$want_screen" != "none" ]; then
	_cur_scr=$(_screen)
	[ "$_cur_scr" = "$want_screen" ] || mismatch="$mismatch screen($_cur_scr!=$want_screen)"
fi
# a CRTC outside the plan is a mismatch even in the read-only verdict (the
# stale class: a gone output can keep one — the daemon's settle must see it).
# NOTES, never mismatches (kernel truth, crtc-owner.sh):
#  - a connector the generated conf deliberately IGNORES, disconnected,
#    with an encoder attached and no X output has no RandR handle
#    (2026-09-21 churn: the bounded repair off->on'ed BOTH outputs);
#  - a disconnected connector whose encoder holds NO CRTC is an attach
#    only — nothing RandR could free (2026-09-22 tester report: a phantom
#    `unplanned(DVI-D-1)` failed every apply on a CRT-only box).
# Everything else stays LOUD.
_ignored_conf=$(_ignored_holders)
_attach_only=$(_encoder_only_holders)
# the same connector can be in both classes (conf-ignored AND no CRTC):
# name it once, in the conf-ignored line
_attach_list=""
for _c in $_attach_only; do
	case " $_ignored_conf " in
	*" $_c "* | *"?$_c "*) continue ;;
	esac
	_attach_list="$_attach_list $_c"
done
_note=""
[ -n "$_ignored_conf" ] && _note="conf-ignored, not actionable:$(printf '%s' "$_ignored_conf" | tr '\n' ',')"
[ -n "$_attach_list" ] && _note="${_note:+$_note }encoder-only attach (no CRTC), not actionable:${_attach_list# }"
_unplanned=$(_actionable_unplanned)
[ -n "$_unplanned" ] && mismatch="$mismatch unplanned($(printf '%s' "$_unplanned" | tr '\n' ','))"

if [ -z "$mismatch" ]; then
	echo "display-apply: reality matches the plan (zero writes)"
	[ -n "$_note" ] && echo "display-apply: note: $_note"
	exit 0
fi

# build ONE batch (una sola invocazione, come da contratto ADR-002) con le
# SOLE gambe in disaccordo + --off per ogni altro output che tiene un CRTC
# (residui connessi da _all_x E disconnessi stantii dalla verita' kernel —
# la classe della mattina del 2026-09-19). Prima ci entrava il piano INTERO:
# una mode-set a vuoto sul tubo a ogni uscita (misurato 2026-10-18).
cmd=(xrandr)
_clear_out=""      # output con una scala RESIDUA da togliere (piano senza scala)
_off_outs=""       # output fuori piano da spegnere (serve alla riparazione)
while IFS=$'\t' read -r name f1 f2 f3 f4 f5; do
	[ "$name" = "SCREEN" ] && continue
	case " $_delta " in *" $name "*) ;; *) continue ;; esac
	if [ "$f1" = "on" ]; then
		# Il ripristino stock atterra PRIMA di noi (misurato) e in tutti i casi
		# misurati il suo modo e' gia' quello del piano: si ACCETTA, cioe' non
		# si ri-emette. Se il modo e' gia' a piano si aggiunge solo cio' che
		# manca (primary/pos/scala); se il modo cambia, o l'output e' spento, o
		# il solo disaccordo e' il kernel, la gamba e' intera — il modo nuovo
		# porta con se' pos e scala (Step 3, 2026-10-18).
		cm=$(_cur_mode "$name")
		why=$(_leg_mismatch "$name" "${f1:-}" "${f2:-}" "${f3:-}" "${f4:-0x0}" "${f5:--}")
		if [ "$cm" != "$f2" ] || [ "$why" = "kernel" ]; then
			cmd+=(--output "$name" --mode "$f2")
			[ "$f3" = "primary" ] && cmd+=(--primary)
			cmd+=(--pos "${f4:-0x0}")
			[ "$f5" != "-" ] && cmd+=(--scale-from "$f5")
		else
			cmd+=(--output "$name")
			[ "$f3" = "primary" ] && [ "$(_cur_prim "$name")" != "primary" ] && cmd+=(--primary)
			[ "$(_cur_pos "$name")" != "${f4:-0x0}" ] && cmd+=(--pos "${f4:-0x0}")
			if [ "$(_cur_size "$name")" != "$(_want_size "$f5" "$f2")" ]; then
				if [ "$f5" != "-" ]; then
					cmd+=(--scale-from "$f5")
				else
					# Il piano NON vuole scala e la geometria e' ancora quella
					# della sorgente: la scala si TOGLIE. Viaggia in una richiesta
					# sua, mai mescolata con uno --scale-from di un altro output
					# (NVIDIA risponde rc=0 e lo mette sul CRTC sbagliato). E' lo
					# stesso verbo che il prep usa gia' per la scala residua.
					_clear_out="$_clear_out $name"
				fi
			fi
		fi
	else
		cmd+=(--output "$name" --off)
	fi
done <<<"$plan"
_off_seen=""
for x in $(_all_x) $(_unplanned_enabled | grep -v '^?'); do
	[ -n "$x" ] || continue
	case " $_off_seen " in *" $x "*) continue ;; esac
	_planned "$x" && continue
	_off_seen="$_off_seen $x"
	_off_outs="$_off_outs $x"
	cmd+=(--output "$x" --off)
done

# Le scale residue sono gambe a tutti gli effetti (contano per la guardia),
# ma viaggiano PRIMA del batch e da sole.
_clears=""
for _o in $_clear_out; do _clears="$_clears --output $_o --transform none"; done
_batch_legs=$(( ${#cmd[@]} - 1 ))
_legs=$_batch_legs
[ -n "$_clear_out" ] && _legs=$(( _legs + 1 ))

# Nessuna gamba da scrivere = l'unica cosa fuori e' la post-condizione SCREEN.
# Non si scrive (non c'e' nulla che la sistemi) e non si finge verde: si urla,
# e la cosa si vede. Uno SCREEN che segue gli output non arriva mai qui.
if [ "$_legs" -le 0 ]; then
	echo "display-apply: LOUD FAILURE — mismatch con zero gambe scrivibili ($mismatch): lo schermo segue gli output, quindi non c'e' cosa scrivere" >&2
	exit 1
fi

if [ "$mode" != "--apply" ]; then
	echo "display-apply: MISMATCH$mismatch"
	[ -n "$_note" ] && echo "display-apply: note: $_note"
	[ -n "$_clears" ] && printf 'display-apply: would run (transform clear): xrandr%s\n' "$_clears"
	[ "$_batch_legs" -gt 0 ] && printf 'display-apply: would run: %s\n' "${cmd[*]}"
	exit 1
fi

# ogni modo che stiamo per scrivere deve esistere su QUEL output (ripristino
# della Modeline dal conf quando X ha perso il pool). Solo le gambe del delta:
# un output che non tocchiamo non va toccato nemmeno nel suo pool di modi.
while IFS=$'\t' read -r name f1 f2 _f3 _f4 _f5; do
	[ "$name" = "SCREEN" ] && continue
	[ "$f1" = "on" ] || continue
	case " $_delta " in *" $name "*) ;; *) continue ;; esac
	_ensure_mode "$name" "$f2" || exit 1
done <<<"$plan"

# La scala residua si toglie PRIMA del batch: una richiesta per output, sola.
for _o in $_clear_out; do
	_err=$(xrandr --output "$_o" --transform none 2>&1) || {
		echo "display-apply: transform clear FAILED on $_o: $_err" >&2
		exit 1
	}
done
if [ "$_batch_legs" -gt 0 ]; then
	_err=$("${cmd[@]}" 2>&1) || {
		echo "display-apply: batch FAILED: $_err" >&2
		exit 1
	}
fi
# ES tiene la geometria VECCHIA finche' non gliela si cambia: la finestra resta
# grande mentre lo schermo e' gia' piccolo, e in quella fessura ES disegna il
# fotogramma tagliato (misurato 2026-10-18, video 10 fps + inventario finestre
# ogni 0,25 s: 0,23 s di contenuto tagliato subito dopo il batch — e' la
# "splash" che l'owner vede). Va fatto QUI, dove la scrittura avviene, e PRIMA
# della verifica: spostarlo dopo costa una verifica intera di fotogramma
# tagliato. La dimensione la sa il piano: zero letture in piu'.
_es_follow
_refresh; _state_load # lo stato e' cambiato: la verifica legge il DOPO

# verify (kernel truth included); one bounded repair on mismatch
verify() {
	local bad="" un _why
	while IFS=$'\t' read -r name f1 f2 f3 f4 f5; do
		[ "$name" = "SCREEN" ] && continue
		_why=$(_leg_mismatch "$name" "${f1:-}" "${f2:-}" "${f3:-}" "${f4:-0x0}" "${f5:--}")
		[ -n "$_why" ] && bad="$bad $name"
	done <<<"$plan"
	if [ -n "$want_screen" ] && [ "$want_screen" != "none" ] && [ "$(_screen)" != "$want_screen" ]; then
		bad="$bad screen"
	fi
	un=$(_actionable_unplanned)
	if [ -n "$un" ]; then
		bad="$bad unplanned($(printf '%s' "$un" | tr '\n' ','))"
	fi
	[ -z "$bad" ]
}
if verify; then
	_write_desktop_state
	echo "display-apply: applied and verified"
	exit 0
fi
# repair: OFF->ON esplicito degli output "on" del piano, poi il PIANO INTERO.
# Il batch a grana di campo puo' non contenere il modo: ri-eseguirlo dopo un off
# lascerebbe l'output spento. L'off azzera anche una scala residua, quindi la
# riparazione non ha bisogno del transform-clear.
for name in $(printf '%s\n' "$plan" | awk -F'\t' '$1 != "SCREEN" && $2 == "on" { print $1 }'); do
	xrandr --output "$name" --off 2>/dev/null || true
done
rcmd=(xrandr)
while IFS=$'\t' read -r name f1 f2 f3 f4 f5; do
	[ "$name" = "SCREEN" ] && continue
	if [ "$f1" = "on" ]; then
		rcmd+=(--output "$name" --mode "$f2")
		[ "$f3" = "primary" ] && rcmd+=(--primary)
		rcmd+=(--pos "${f4:-0x0}")
		[ "$f5" != "-" ] && rcmd+=(--scale-from "$f5")
	else
		rcmd+=(--output "$name" --off)
	fi
done <<<"$plan"
for x in $_off_outs; do rcmd+=(--output "$x" --off); done
_err=$("${rcmd[@]}" 2>&1) || {
	echo "display-apply: repair batch FAILED: $_err" >&2
	exit 1
}
_refresh; _state_load # la riparazione ha scritto: rileggi il dopo
if verify; then
	_write_desktop_state
	echo "display-apply: applied and verified (after one repair)"
	exit 0
fi
echo "display-apply: LOUD FAILURE — state does not match the plan after batch+repair$mismatch" >&2
exit 1
