#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
# Copyright (C) 2026 FreZeeN
# Part of crt-dual — https://github.com/frezeen
# display-reconcile.sh — the ONE writer (ADR-002). Event loop:
# guard aware (a session owns the display), coalesced wake bells
# (poke / manual trigger / DRM status flip / ES pid / game-ended), then
# reconcile = detect -> model -> apply-if-needed -> verify. A correct
# state is ZERO writes. After an apply a short settle window re-checks
# read-only: stock rewrites ~1 s after an ES restart land with no new
# event and must be caught (the old watcher's lesson, kept as a
# post-condition, not a branch).
#
# Usage:
#   display-reconcile.sh --check    read-only verdict (rc 0 = reality == plan)
#   display-reconcile.sh --once     one reconcile pass (yield during a session)
#   display-reconcile.sh --daemon   the loop
set -uo pipefail
export DISPLAY="${DISPLAY:-:0}" # the daemon is setsid-detached: every xrandr call needs it explicitly
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_DIR="${CRT_DUAL_STATE_DIR:-/tmp/crt-dual}"
MODE_FILE="${CRT_DUAL_MODE_FILE:-/tmp/crt-dual-mode}"
PROFILE_FILE="${CRT_DUAL_PROFILE_FILE:-/tmp/crt-dual/profile}"
# Poll interval: the gameStop bell (udev-poke) is only seen at a loop wake,
# so this bounds the visible "desktop comes back late" gap after a game
# exit (owner-observed ~1 s FullHD flash at 2 s, 2026-09-20). 0.5 s keeps
# the wake quick; the per-iteration work is cheap status reads.
POLL="${CRT_DUAL_RECONCILE_POLL:-0.5}"
# Finestra di attesa su una RIMOZIONE (poll). Misurato 2026-10-18: staccare un
# cavo e' spesso il primo gesto di uno spostamento; applicare subito costa due
# apply e ~1 s di pannello nero, aspettare no (il layout resta quello di prima).
DEBOUNCE_POLLS="${CRT_DUAL_DEBOUNCE_POLLS:-4}"
LOG="${CRT_DUAL_RECONCILE_LOG:-/userdata/system/logs/display-reconcile.log}"
ITERS="${CRT_DUAL_RECONCILE_ITERS:-0}" # 0 = forever (tests set a finite count)
log() { echo "RECONCILE [$(date +%H:%M:%S)]: $*" | tee -a "$LOG" 2>/dev/null || true; }
_x() { timeout 5 env DISPLAY="${DISPLAY:-:0}" xrandr --current 2>/dev/null; }

_session_active() { [ -f "$MODE_FILE" ] || [ -f "$PROFILE_FILE" ]; }

# ── Deadlock breaker probes (root cause, measured 2026-10-10/11) ─────────
# emulatorlauncher (ES's child, one per session) returns only when it sees
# EOF on the game's stdout/stderr pipes. When the game's renderer dies, the
# processes UNDER it — gamescopereaper, the winedevice workers, the game
# itself — are reparented to init and SURVIVE, still holding the write ends.
# Proven from the fd table: emulatorlauncher held pipe:[180915] read; a
# wrapper held that same pipe write. EOF never arrives, emulatorlauncher
# never returns, ES never runs gameStop, and the guard stays up for good.
#
# The trigger is a CLOSED GAME, and the only honest signal for that is the
# WINDOW (_game_alive): process signals cannot separate a running game from
# a closed one (a wine session keeps a live launch stub AND reparents its
# daemons for the WHOLE game — measured 2026-10-11). The close, once
# decided, is the pipe-writer set (_pipe_writers), read from the fd table,
# never from a process name.
#
# Both probes are seamed so the breaker's LOGIC is testable without a live
# game (the house style: seams for live paths).
_es_pid() { # il pid di ES: il PROPRIETARIO della finestra, non un match di cmdline
	# Misurato 2026-10-18 sera: qualunque processo la cui riga di comando
	# contenga "dbus-run-session ... emulationstation" soddisfa la vecchia
	# sonda — tre eventi es-pid falsi in una serata, con ES vivo e immobile
	# dalle 19:05. Il proprietario della finestra ES e' ES per costruzione;
	# il fallback e' ANCORATO all'inizio (una shell che nomina la stringa non
	# lo soddisfa).
	local p
	if command -v xdotool >/dev/null 2>&1; then
		p=$(DISPLAY="${DISPLAY:-:0}" xdotool search --class emulationstation getwindowpid 2>/dev/null | head -1)
		[ -n "$p" ] && { printf '%s\n' "$p"; return 0; }
	fi
	pgrep -f '^dbus-run-session -- emulationstation' 2>/dev/null | head -1 || true
}

_emu_alive() { # rc 0 while the session's emulatorlauncher waits
	if [ -n "${CRT_DUAL_EMU_ALIVE_CMD:-}" ]; then
		bash -c "$CRT_DUAL_EMU_ALIVE_CMD"
		return $?
	fi
	# -f (full cmdline), NOT -x (process name): "emulatorlauncher" is 16
	# characters and comm is truncated to 15, so `pgrep -x emulatorlauncher`
	# NEVER matches — measured on the box the first time this ran, where the
	# breaker sat silent with the orphan right there. This is the same test
	# the box's own batocera-es-swissknife uses (check_emurun).
	pgrep -f -n emulatorlauncher >/dev/null 2>&1
}
_pipe_writers() { # $@ = launcher pids -> who holds a WRITE end of a pipe the launcher READS
	if [ -n "${CRT_DUAL_PIPEWRITERS_CMD:-}" ]; then
		bash -c "$CRT_DUAL_PIPEWRITERS_CMD"
		return 0
	fi
	# Who keeps emulatorlauncher from seeing EOF is decided by the fd table,
	# not by a process name or an orphan list: every process holding a WRITE
	# end of a pipe the launcher has open for READING is a blocker (measured
	# 2026-10-11, Candy Crush wedge: 13 holders — wine daemons, the launch
	# stub and the game — of which the retired PPID-1 wine-name probe named
	# only 3, so killing it never closed the pipes).
	#
	# ONE `ls` over every fd table, parsed by awk (measured 2026-10-12: the
	# per-fd fork loop cost 2.6 s — it forked once per fd of every process —
	# and the breaker paid it on the RECOVERY path, which is the latency the
	# owner sees; the single pass is 0.013 s, the same answer).
	local _emu _inodes="" _skip="" _emu_r
	for _emu in "$@"; do
		_emu_r="$(ls -l "/proc/$_emu/fd" 2>/dev/null \
			| sed -n 's/.*pipe:\[\([0-9]\{1,\}\)\].*/\1/p' | tr '\n' ' ')"
		_inodes="$_inodes $_emu_r"
		_skip="$_skip $_emu "
	done
	_inodes="$(printf '%s' "$_inodes" | tr -s ' ')"
	[ -n "${_inodes// /}" ] || return 0
	ls -l /proc/[0-9]*/fd 2>/dev/null | awk -v want=" $_inodes " -v skip="$_skip" '
		/^\/proc\/[0-9]+\/fd:$/ { n = split($0, a, "/"); pid = a[3]; next }
		/^l-w/ && / -> pipe:\[/ {
			if (index(skip, " " pid " ") > 0) next
			if (!match($0, /pipe:\[[0-9]+\]/)) next
			ino = substr($0, RSTART + 6, RLENGTH - 7)
			if (index(want, " " ino " ") > 0 && !seen[pid]++) print pid
		}' | sort -un
}
_game_alive() { # rc 0 while the session's GAME is on screen (a viewable non-ES window)
	if [ -n "${CRT_DUAL_GAME_ALIVE_CMD:-}" ]; then
		bash -c "$CRT_DUAL_GAME_ALIVE_CMD"
		return $?
	fi
	# The game's liveness is its WINDOW, not a process (measured 2026-10-11,
	# Candy Crush/adrenaline wedge). A wine session keeps its launch stub
	# (start.exe) a live descendant of emulatorlauncher AND reparents
	# wineserver/winedevice/the game to init for the WHOLE game, so no
	# process signal separates a running game from a closed one: the old
	# "non-shell descendant" test stayed true with the window gone and the
	# game frozen. The window does separate them — while the game renders, a
	# LARGE viewable X window that is not EmulationStation's exists; ALT+F4
	# unmaps it and only ES remains. Size matters: wine spawns a cloud of
	# tiny helper windows (IME 1x1, 160x20, Input 111x1) that come and go
	# during boot and would arm the latch on their own (measured 2026-10-11:
	# a relaunch was false-fired 3 s in by exactly that). Fail safe: with no
	# way to query X we assume the game is on screen, so a blind probe never
	# fires.
	command -v xdotool >/dev/null 2>&1 || return 0
	local _all _eswins _win _geo _w _h
	# Fail safe: if the X query itself fails we assume the game is on screen.
	_all="$(DISPLAY="${DISPLAY:-:0}" xdotool search --onlyvisible --class '.' 2>/dev/null)" || return 0
	# EmulationStation is identified by its WINDOW CLASS, not a pid: the window
	# is owned by the `emulationstation` process while the session launcher is
	# its `dbus-run-session` parent (measured: window pid 6859 vs launcher
	# 6844), so a pid comparison would mistake ES's own window for the game.
	_eswins=" $(DISPLAY="${DISPLAY:-:0}" xdotool search --onlyvisible --class emulationstation 2>/dev/null | tr '\n' ' ') "
	for _win in $_all; do
		case "$_eswins" in *" $_win "*) continue ;; esac
		_geo="$(DISPLAY="${DISPLAY:-:0}" xdotool getwindowgeometry "$_win" 2>/dev/null \
			| sed -n 's/.*Geometry: \([0-9]*\)x\([0-9]*\).*/\1 \2/p')"
		_w="${_geo% *}"; _h="${_geo#* }"
		case "$_w" in '' | *[!0-9]*) continue ;; esac
		case "$_h" in '' | *[!0-9]*) continue ;; esac
		if [ "$_w" -ge 320 ] && [ "$_h" -ge 240 ]; then
			return 0
		fi
	done
	return 1
}
_breaker_standsdown() { # rc 0 = la sessione NON e' un gioco: il breaker non spara
	if [ -n "${CRT_DUAL_BREAKER_STANDDOWN_CMD:-}" ]; then
		bash -c "$CRT_DUAL_BREAKER_STANDDOWN_CMD"
		return $?
	fi
	# Il menu `+rgs` (il system "Batocera config" di RGS) e' un insieme di
	# script di UTILITA' lanciati esattamente come un gioco (`/bin/bash <rom>`,
	# configgen shGenerator) e l'update di sistema stock guida una SEQUENZA di
	# xterm massimizzati di breve durata. La premessa del breaker — una sola
	# finestra di gioco per tutta la sessione — li' NON vale: il buco fra due
	# xterm e' indistinguibile da un'uscita del gioco, e il breaker ha ABORTITO
	# l'rgs update dell'owner a meta' (misurato 2026-10-12: xterm del tema
	# chiuso, il successivo non ancora mappato -> "game closed (window gone)"
	# -> pipe writer uccisi). Per questa classe si sta giu'. Il pattern non
	# tocca /userdata/roms/rgs_crt/ (serve la "/" dopo "rgs").
	pgrep -f '/userdata/roms/rgs/[^ ]*\.sh' >/dev/null 2>&1
}

SYSFS="${CRT_DUAL_SYSFS:-/sys/class/drm}"
_target_active() { # $1 = X output -> active mode AND kernel-enabled (the truth pair)
	local tm td en
	tm=$(_x | sed -n "/^$1 connected/,/^[^ ]/p" | awk '$0 ~ /\*/ { print $1; exit }')
	td=$(bash "$HERE/display-detect.sh" --list 2>/dev/null | awk -F'\t' -v x="$1" '$3 == x { print $1; exit }')
	en=$(cat "$SYSFS/card0-$td/enabled" 2>/dev/null)
	if [ -n "$tm" ] && [ -n "$td" ] && [ "$en" = "enabled" ]; then
		return 0
	fi
	log "target-active($1): mode='${tm:-}' drm='${td:-}' enabled='${en:-}'"
	return 1
}

_topology() { # crt/lcd X names, from the detect module (single source)
	local out
	out=$(bash "$HERE/display-detect.sh" --check 2>/dev/null) || return 1
	printf '%s' "$out"
}

_write_detect_state() { # compatible state for the selector/apply_profile readers
	local out crt lcd
	out=$(_topology) || return 1
	crt=$(printf '%s' "$out" | sed -n 's/.*crt=\([^ ]*\).*/\1/p')
	lcd=$(printf '%s' "$out" | sed -n 's/.*lcd=\([^ ]*\).*/\1/p')
	{
		printf 'CRT_OUTS=%s\n' "$crt"
		printf 'CRT_PRESUMED_OUTS=\n'
		printf 'LCD_OUTS=%s\n' "$lcd"
		printf 'CRT_OUT=%s\n' "$crt"
		printf 'CRT_PRESUMED_OUT=\n'
		printf 'LCD_OUT=%s\n' "$lcd"
	} >"$STATE_DIR/detect-state.tmp" 2>/dev/null && mv "$STATE_DIR/detect-state.tmp" "$STATE_DIR/detect-state" 2>/dev/null || true
}

# ── la finestra di ES deve stare sullo schermo ────────────────────────────
# Misurato 2026-10-18 (il pasticcio dell'hotplug): ES si riavvia da solo sui
# cambi di modo — e' il wrapper di Batocera — e torna con la geometria che
# trovava ALLORA. Il nostro `windowsize` non lo smuove: ES impone la sua
# (provato a mano: la finestra e' rimasta 1920x1080, e il log lo dichiarava
# fatto). Le due forme viste sul campo sono ENTRAMBE di geometria: 640x480 su
# schermo 1920x1080 (il "quadretto" in un angolo) e 1920x1080 su 640x480 (il
# menu che non appare, schermo nero). Quindi: post-condizione di geometria, e
# la riparazione che FUNZIONA — il riavvio di ES — una volta, con una pausa di
# sicurezza: un loop di riavvii sarebbe peggio del difetto.
ES_RESTART_COOLDOWN="${CRT_DUAL_ES_RESTART_COOLDOWN:-60}"
_es_win() { DISPLAY="${DISPLAY:-:0}" xdotool search --class emulationstation 2>/dev/null | head -1; }
_es_screen() { _x | sed -n 's/^Screen 0:.*current \([0-9]*\) x \([0-9]*\).*/\1x\2/p' | head -1; }
_es_ok() { # rc 0 = la finestra di ES e' grande quanto lo schermo (o non c'e' ES)
	command -v xdotool >/dev/null 2>&1 || return 0
	local wid sw ww i nwin
	# "Nessuna finestra" e' normale (ES in riavvio) ma NON e' "va bene": misurato
	# 2026-10-18 21:23 e 21:34, nell'istante del controllo la finestra non c'era
	# e il verdetto cadeva in silenzio su "non decido" -> nessuna riparazione,
	# mentre il nudge, nello stesso secondo, la finestra la vedeva. Quindi si
	# ASPETTA la finestra (tentativi brevi dentro la passata): quella che torna
	# e' quella vera, e solo allora si confronta con lo schermo.
	wid=""; i=0
	while [ "$i" -lt 4 ]; do
		wid=$(_es_win)
		[ -n "$wid" ] && break
		sleep 0.4
		i=$((i + 1))
	done
	[ -n "$wid" ] || { log "es-check: nessuna finestra ES dopo 4 tentativi — non decido"; return 0; }
	# Diagnostica: piu' finestre della classe (screensaver/overlay?) renderebbero
	# ambiguo il lookup — si usa la prima, ma lo si dice.
	nwin=$(DISPLAY="${DISPLAY:-:0}" xdotool search --class emulationstation 2>/dev/null | wc -l)
	[ "${nwin:-0}" -gt 1 ] && log "es-check: $nwin finestre della classe emulationstation — uso la prima"
	sw=$(_es_screen)
	# "non decido" NON e' "va bene": se lo schermo non si legge (X occupata da un
	# riavvio stock) lo si dice, o il difetto resta invisibile per minuti —
	# misurato 2026-10-18: 9 minuti di finestra 1920x1080 e nessuna traccia.
	[ -n "$sw" ] || { log "es-check: schermo illeggibile — non decido"; return 0; }
	ww=$(DISPLAY="${DISPLAY:-:0}" xdotool getwindowgeometry "$wid" 2>/dev/null | sed -n 's/.*Geometry: //p')
	[ -n "$ww" ] || { log "es-check: geometria di ES illeggibile — non decido"; return 0; }
	[ "$ww" = "$sw" ] && return 0
	log "es-check: finestra $ww su schermo $sw — il menu non puo' stare a schermo intero"
	return 1
}
_es_content() { # % intero di pixel NON neri DENTRO la finestra di ES; vuoto se non misurabile
	# Metodo documentato (2026-10-13): il framebuffer e' la verita' del VETRO, X no.
	# Sana: ~75-99% (misurato 2026-10-18 su due geometrie). Pagina nera: ~0-25%.
	[ -n "${CRT_DUAL_ES_CONTENT_CMD:-}" ] && { bash -c "$CRT_DUAL_ES_CONTENT_CMD"; return $?; }
	command -v ffmpeg >/dev/null 2>&1 || return 1
	local wid g pos x y w h sz f pct
	wid=$(_es_win); [ -n "$wid" ] || return 1
	g=$(DISPLAY="${DISPLAY:-:0}" xdotool getwindowgeometry "$wid" 2>/dev/null)
	pos=$(printf '%s\n' "$g" | sed -n 's/.*Position: \([0-9-]*\),\([0-9-]*\).*/\1,\2/p')
	w=$(printf '%s\n' "$g" | sed -n 's/.*Geometry: \([0-9]*\)x\([0-9]*\).*/\1/p')
	h=$(printf '%s\n' "$g" | sed -n 's/.*Geometry: \([0-9]*\)x\([0-9]*\).*/\2/p')
	[ -n "$w" ] && [ -n "$h" ] || return 1
	sz=$(_x | sed -n 's/^Screen 0:.*current \([0-9]* x [0-9]*\).*/\1/p' | tr -d ' ')
	[ -n "$sz" ] || return 1
	x=${pos%,*}; y=${pos#*,}
	# ritaglio entro lo schermo (nella forma del difetto la finestra E' piu' grande)
	[ "$((x + w))" -gt "${sz%x*}" ] && w=$(( ${sz%x*} - x ))
	[ "$((y + h))" -gt "${sz#*x}" ] && h=$(( ${sz#*x} - y ))
	[ "$w" -gt 0 ] && [ "$h" -gt 0 ] || return 1
	f=$(mktemp /tmp/crt-dual-content.XXXXXX.png) || return 1
	timeout 5 env DISPLAY="${DISPLAY:-:0}" ffmpeg -y -loglevel error -f x11grab -video_size "$sz" -i :0 -frames:v 1 "$f" 2>/dev/null || { rm -f "$f"; return 1; }
	pct=$(ffmpeg -v error -i "$f" -vf "crop=$w:$h:${x:-0}:${y:-0},format=gray" -f rawvideo - 2>/dev/null |
		od -An -tu1 -v | tr -s ' ' '\n' | awk 'NF==1 { n++; if ($1 > 8) m++ } END { if (n) printf "%d", 100*m/n }')
	rm -f "$f"
	[ -n "$pct" ] || return 1
	printf '%s\n' "$pct"
}
_es_content_gate() { # il contenuto della pagina; se e' nero lo si spinge con 'Left'
	# Il MOUSE non sveglia ES (due prove su due, 2026-10-18); la freccia sinistra
	# si' (l'owner congeda cosi' lo screensaver). Ma "Left" e' un'AZIONE
	# (indietro/naviga): si manda SOLO quando il contenuto e' nero, mai a ogni
	# passata — altrimenti la selezione scivolerebbe a ogni uscita.
	local pct
	pct=$(_es_content) || return 0
	[ -n "$pct" ] || return 0
	# Soglia misurata sul banco (2026-10-18): il difetto (pagina nera con la
	# barra) sta a 7,2%; una pagina legittima SCURA sta a 25,7% (osservata) e a
	# ~47% (un'altra); le sane piene a 75-99%. 15% lascia 8 punti dal difetto e
	# 10 dalla pagina scura piu' chiara vista: piu' in alto si rischia di
	# "spingere" una pagina sana (falso positivo — l'owner l'ha chiesto esplicito).
	if [ "$pct" -lt "${CRT_DUAL_ES_CONTENT_MIN:-15}" ]; then
		log "es-content: ${pct}% non-nero — la pagina non si e' disegnata: spingo con 'Left'"
		DISPLAY="${DISPLAY:-:0}" xdotool key --clearmodifiers Left 2>/dev/null || true
		sleep 0.5
		pct=$(_es_content) || return 0
		log "es-content: dopo lo stimolo ${pct}% non-nero"
	else
		log "es-content: ${pct}% non-nero"
	fi
}

_es_repair() { # la riparazione che funziona, UNA volta, con pausa di sicurezza
	local now last
	now=$(date +%s)
	last=$(cat "$STATE_DIR/es-restarted" 2>/dev/null)
	case "$last" in '' | *[!0-9]*) last=0 ;; esac
	if [ $((now - last)) -lt "$ES_RESTART_COOLDOWN" ]; then
		log "es-repair: cooldown ($((now - last))s < ${ES_RESTART_COOLDOWN}s) — non riavvio"
		return 1
	fi
	printf '%s\n' "$now" >"$STATE_DIR/es-restarted" 2>/dev/null || true
	log "es-repair: riavvio EmulationStation (finestra fuori misura)"
	if [ -n "${CRT_DUAL_ES_RESTART_CMD:-}" ]; then
		bash -c "$CRT_DUAL_ES_RESTART_CMD"
	else
		batocera-es-swissknife --restart >/dev/null 2>&1 || log "es-repair: il riavvio di ES e' fallito"
	fi
}

# ── una topologia per PASSATA ─────────────────────────────────────────────
# Il primo lettore della passata la dichiara (display-detect.sh --state, UN
# processo) e la esporta: modello, apply e sonde del prep la ricevono. La
# topologia non cambia dentro una passata — nemmeno dopo una scrittura di modo
# — quindi non si invalida come lo stato dei modi. Costo evitato: un detect
# intero costa ~0.5 s su dce_v6 (misurato 2026-10-18: tre per passata = 1,4 s
# a ogni uscita e a ogni avvio).
_detect_state() {
	local out
	_detect_done
	out=$(bash "$HERE/display-detect.sh" --state 2>/dev/null) || out=""
	if [ -z "$out" ]; then
		return 1 # best-effort: senza preload ogni consumatore legge da solo
	fi
	CRT_DUAL_DETECT_CHECK=$(printf '%s\n' "$out" | sed -n 's/^CHECK	//p' | head -1)
	CRT_DUAL_DETECT_LIST=$(printf '%s\n' "$out" | sed -n 's/^LIST	//p')
	export CRT_DUAL_DETECT_CHECK CRT_DUAL_DETECT_LIST
}
_detect_done() { unset CRT_DUAL_DETECT_CHECK CRT_DUAL_DETECT_LIST; }

_prep_ok() { # $1 = il piano della FASE SESSION -> rc 0 se la post-condizione regge
	# Il prep promette quattro cose e prima ne verificava due (modo attivo e
	# kernel, via _target_active). NON verificava la primary, il residuo di
	# scale, ne' lo SCREEN: un pannello che non aveva preso la primary
	# PASSAVA, e il gioco — che renderizza sull'output primary — finiva sulla
	# CRT. Una lettura di stato per tutto il controllo.
	local plan="$1" name on _m prim _p _sc x cm cs scr want
	x=$(_x)
	while IFS=$'\t' read -r name on _m prim _p _sc; do
		[ "$name" = "SCREEN" ] && continue
		cm=$(printf '%s\n' "$x" | sed -n "/^$name connected/,/^[^ ]/p" | awk '$0 ~ /\*/ { print $1; exit }')
		if [ "$on" = "on" ]; then
			[ -n "$cm" ] || { log "prep($name): nessun modo attivo"; return 1; }
			[ "$(printf '%s\n' "$x" | awk -v o="$name" '$1 == o { print ($0 ~ / primary/) ? "y" : "n"; exit }')" = "y" ] \
				|| { log "prep($name): NON primary — il gioco renderizzerebbe sull'altro output"; return 1; }
			cs=$(printf '%s\n' "$x" | awk -v o="$name" '$1 == o { for (i = 1; i <= NF; i++) if ($i ~ /^[0-9]+x[0-9]+\+[0-9]+\+[0-9]+$/) { split($i, p, "+"); print p[1]; exit } }')
			[ "$cs" = "${cm%i}" ] || { log "prep($name): scalato ($cs != ${cm%i}) — un residuo di scale manda il gioco in un framebuffer piccolo"; return 1; }
			_target_active "$name" || return 1
		else
			[ -z "$cm" ] || { log "prep($name): ancora attivo, doveva essere libero"; return 1; }
		fi
	done <<<"$plan"
	scr=$(printf '%s\n' "$plan" | awk -F'\t' '$1 == "SCREEN" { print $2; exit }')
	if [ -n "$scr" ] && [ "$scr" != "none" ]; then
		want=$(printf '%s\n' "$x" | sed -n 's/^Screen 0:.*current \([0-9]* x [0-9]*\).*/\1/p' | tr -d ' ')
		[ "$want" = "$scr" ] || { log "prep: SCREEN ${want:-?} != $scr"; return 1; }
	fi
	return 0
}

_session_start() { # $1 = crt|lcd — hand the display to the game (stock owns the raster)
	local target="$1" prep tname other rc=0 _err
	case "$target" in crt | lcd) ;; *) echo "display-reconcile: --session-start needs crt|lcd" >&2; return 2 ;; esac
	_reconcile_lock || { echo "display-reconcile: session-start: lock busy" >&2; return 1; }
	_detect_state || true # una topologia per passata, come nel giro d'uscita
	# La fase SESSION la dichiara il MODELLO (display-model.sh --session): il
	# bersaglio on+primary e NON scalato, l'altro libero, e lo SCREEN che ne
	# segue. Prima viveva solo nelle richieste qui sotto, quindi non era ne'
	# dichiarata ne' testabile.
	prep=$(bash "$HERE/display-model.sh" --session "$target") || {
		log "session-start: il modello ha rifiutato il piano di sessione (detect giu' o nessun modo offerto)"
		_reconcile_unlock
		return 1
	}
	tname=$(printf '%s\n' "$prep" | awk -F'\t' '$2 == "on" { print $1; exit }')
	other=$(printf '%s\n' "$prep" | awk -F'\t' '$2 == "off" { print $1; exit }')
	_write_detect_state
	if [ -z "$tname" ] || [ -z "$other" ]; then
		log "session-start: single-display topology — nothing to prep, stock owns the launch"
		_reconcile_unlock
		return 0
	fi
	if [ "$target" = "crt" ]; then
		_err=$(xrandr --output "$other" --off 2>&1) || { log "session-start: $other off FAILED: $_err"; rc=1; }
	else
		# Non-destructive takeover — THREE requests, panel first, CRT last
		# (owner bug 2026-10-13, measured live on the box).
		#
		# WHY NOT OFF-BOTH (what ADR-002 shipped): `--output $crt --off
		# --output $lcd --off` destroys EmulationStation's GL surface — ES
		# runs `emulationstation --windowed` under openbox ON the CRT — and
		# nothing re-creates it. After that round-trip ES content measured
		# 0% (black) and NO X stimulus recovered it: resize to a very
		# different size and back, windowmove, F5/F11/keys, mouse,
		# unmap/map, windowactivate. Only killing ES (it respawns) brought
		# the menu back. So the ORDER is the contract: the panel is taken
		# primary+native while BOTH outputs are still ON (ES's screen moves
		# to the panel, its output never disappears), and only THEN is the
		# CRT freed.
		#
		# WHY STEP 1 EXISTS: the dual plan writes `--scale-from 640x480` on
		# the panel (display-model.sh:70-72 -> display-apply.sh:232), live
		# as the panel's Transform 0.333328/0.444443 — that is what lets
		# the panel share the 640x480 screen, and the residue makes a bare
		# `--primary` a silent no-op. The OLD owner cleared it the same way
		# and called it mandatory (clone scale persists otherwise). ADR-002
		# dropped that verb and compensated with the destructive off-both.
		#
		# Three requests, never merged: `--transform` is never mixed with
		# another output's `--scale-from` in one request (NVIDIA answers
		# rc=0 and puts it on the wrong CRTC).
		_err=$(xrandr --output "$tname" --transform none 2>&1) || { log "session-start: $tname transform-clear FAILED: $_err"; rc=1; }
		if [ "$rc" = "0" ]; then
			_err=$(xrandr --output "$tname" --primary --auto 2>&1) || { log "session-start: $tname takeover FAILED: $_err"; rc=1; }
		fi
		if [ "$rc" = "0" ]; then
			_err=$(xrandr --output "$other" --off 2>&1) || { log "session-start: $other off FAILED: $_err"; rc=1; }
		fi
	fi
	if [ "$rc" = "0" ] && _prep_ok "$prep"; then
		log "session-start: $target session prepped ($other off; target on+primary+unscaled)"
		_reconcile_unlock
		return 0
	fi
	if [ "$rc" = "0" ]; then
		log "session-start: target $target not at the session plan after prep — one repair"
		xrandr --output "$tname" --off 2>/dev/null || true
		xrandr --output "$tname" --primary --auto 2>/dev/null || true # the off frees the CRTC, the takeover re-programs (measured two-step)
		if _prep_ok "$prep"; then
			log "session-start: $target session prepped (after one repair)"
			_reconcile_unlock
			return 0
		fi
	fi
	log "session-start: LOUD FAILURE — $target not at the session plan after prep+repair"
	_reconcile_unlock
	return 1
}

_sysfp() { # DRM status fingerprint (no display contact)
	local f out=""
	for f in "$SYSFS"/card*-*/status; do
		[ -f "$f" ] || continue
		out="$out $(basename "$(dirname "$f")"):$(cat "$f" 2>/dev/null)"
	done
	printf '%s' "$out" | tr ' ' '\n' | sort | tr '\n' ' '
}
_nconn() { # quanti connettori sono "connected" (stessa fonte di _sysfp)
	local f n=0
	for f in "$SYSFS"/card*-*/status; do
		[ -f "$f" ] || continue
		[ "$(cat "$f" 2>/dev/null)" = "connected" ] && n=$((n + 1))
	done
	printf '%s' "$n"
}

# The live display pass. CRT_DUAL_APPLY_CMD is a seam knob, same pattern as
# the breaker probes below: it lets a hermetic test drive the loop WITHOUT
# performing a real mode apply. Measured 2026-10-16: the deadlock-breaker
# seam paid ~2.3s per case for an apply it never asserts on (12 cases = 28s
# of an 81s seam) — a live tool inherited by a hermetic seam is exactly the
# defect test-flow names (precedent: CRT_DUAL_MODETEST).
_apply_pass() { # "$@" = --apply (from _reconcile) | nothing (settle re-check)
	if [ -n "${CRT_DUAL_APPLY_CMD:-}" ]; then
		bash -c "$CRT_DUAL_APPLY_CMD"
		return $?
	fi
	bash "$HERE/display-apply.sh" "$@"
}
_reconcile() {
	_reconcile_lock || return 1
	if _session_active; then # the guard may have gone up while we waited for the lock
		log "session started while waiting — yield (the game owns the display)"
		_reconcile_unlock
		return 0
	fi
	_detect_state || true # una topologia per passata (vedi _detect_state)
	_write_detect_state
	local out rc
	out=$(_apply_pass --apply 2>&1)
	rc=$?
	_detect_done # dopo la scrittura si rilegge tutto fresco (il settle)
	# La finestra di ES e' una post-condizione come lo SCREEN: vale anche
	# quando non abbiamo scritto niente (l'uscita in topologia singola non
	# scrive, ed e' il caso in cui il menu puo' restare nero).
	if [ "$rc" = "0" ]; then
		# A delta VUOTO la spinta la fa il riconciliatore: e' l'input che
		# sblocca il frame stantio di ES, ed e' il caso in cui il menu resta
		# nero (topologia singola: nessuna scrittura, misurato 2,3 s il
		# 2026-10-18). Quando l'apply ha scritto, la spinta l'ha gia' fatta.
		case "$out" in
		*"zero writes"*) bash "$HERE/display-apply.sh" --es-follow ;;
		esac
		_es_ok || _es_repair
	fi
	if [ "$rc" = "0" ]; then
		# La finestra di ES (geometria + frame stantio) la sistema ORA il
		# writer, dentro display-apply, subito dopo il batch e PRIMA della
		# verifica: li' costa zero e la fessura del fotogramma tagliato non
		# esiste. Qui non si tocca piu' niente (misurato 2026-10-18).
		_reconcile_unlock
		return 0
	fi
	_reconcile_unlock
	log "apply NOT verified: $(printf '%s' "$out" | tail -2 | tr '\n' ' ')"
	return 1
}
RECONCILE_LOCK_FILE="$STATE_DIR/reconcile.lock"
_reconcile_lock() {
	command -v flock >/dev/null 2>&1 || return 0
	exec 9>"$RECONCILE_LOCK_FILE" 2>/dev/null || return 0
	flock -w 5 9 2>/dev/null || return 1
}
_reconcile_unlock() {
	command -v flock >/dev/null 2>&1 || return 0
	flock -u 9 2>/dev/null || true
	exec 9>&- 2>/dev/null || true
}

case "${1:---check}" in
--check)
	if bash "$HERE/display-apply.sh" >/dev/null 2>&1; then
		echo "display-reconcile: reality matches the plan"
		exit 0
	fi
	bash "$HERE/display-apply.sh" >&2
	exit 1
	;;
--once)
	if _session_active; then
		log "session active — yield (the game owns the display)"
		exit 0
	fi
	# Exit WITH the verdict: zz_crt_dual's WARN branch exists exactly for
	# this rc. Without the explicit exit, the trailing `exit 0` made
	# "Boot layout applied" a false green (2026-09-22 tester report: a
	# LOUD FAILURE line was followed by "applied").
	_reconcile
	exit $?
	;;
--session-start)
	_session_start "${2:-}"
	exit $?
	;;
--daemon)
	log "reconcile loop started (poll ${POLL}s, state $STATE_DIR)"
	prev_fp=""
	prev_es=""
	prev_game="idle"
	_game_seen=0
	_win_on=0
	_win_gone=0
	_emu_polls=0
	_sess_pids=""
	_prev_sess=0
	_sd_logged=0
	# Minimum launcher age (polls) before the breaker may fire: it rides out
	# the whole wine boot (several seconds of a window that is still coming
	# up) so a slow launch is never aborted. Seam knob for fast tests.
	EMU_MIN_POLLS="${CRT_DUAL_BREAKER_MIN_POLLS:-16}"
	# A window that has been on screen continuously for this many polls means
	# the session is ESTABLISHED: its disappearance is the exit, so the grace
	# drops to ONE poll (the owner feels the latency). While the window has
	# only just appeared the full grace applies — that is the boot transient.
	STABLE_POLLS="${CRT_DUAL_BREAKER_STABLE_POLLS:-10}"
	_first=1
	settle=0
	debounce=0
	_prev_n=$(_nconn)
	i=0
	while true; do
		_detect_done # nessun preload sopravvive al poll: vale per UNA passata
		i=$((i + 1))
		if [ "$ITERS" -gt 0 ] && [ "$i" -gt "$ITERS" ]; then break; fi

		# ── Deadlock breaker (root cause, measured 2026-10-10/11) ───────
		# emulatorlauncher returns only on EOF of the game's pipes; a closed
		# game whose pipe-holders survive keeps it blocked for ever and the
		# guard with it. The game is "closed" when its WINDOW is gone — the
		# one signal that separates a running game from a wedged one
		# (_game_alive, measured 2026-10-11). Three guards keep a STARTING
		# game out of reach, so a slow boot is never aborted:
		#   - the latch (_game_seen) needs the window ON SCREEN first;
		#   - the latch resets on the session's rising edge (guard down->up),
		#     so a lingering launcher cannot leak it into the next launch;
		#   - a minimum launcher age (EMU_MIN_POLLS) rides out the wine boot.
		# Firing closes the pipes by killing their WRITE holders
		# (_pipe_writers); emulatorlauncher is left alone so gameStop still
		# runs — that is the point.
		#
		# Evaluated BEFORE the session short-circuit below: while a session
		# is stuck the guard is UP, so a check placed after it would never
		# run — the exact mistake this replaces.
		_sess_now=0
		_session_active && _sess_now=1
		if [ "$_sess_now" = 1 ] && [ "${_prev_sess:-0}" = 0 ]; then
			_game_seen=0
			_win_on=0
			_win_gone=0
			_emu_polls=0
			_sess_pids=""
			_sd_logged=0
		fi
		_prev_sess=$_sess_now

		if _emu_alive; then
			_emu_polls=$((_emu_polls + 1))
			if _breaker_standsdown; then
				# sessione non-gioco (+rgs): non si spezza mai (vedi la probe)
				if [ "${_sd_logged:-0}" = 0 ]; then
					log "deadlock breaker stood down: non-game session (rgs system scripts)"
					_sd_logged=1
				fi
				_game_seen=0
				_win_on=0
				_win_gone=0
			elif _game_alive; then
				_game_seen=1
				_win_on=$((_win_on + 1))
				_win_gone=0
				# I processi vivi MENTRE il gioco e' a schermo. Solo cio' che
				# esiste qui puo' reggere la pipe del gioco morto: quel che nasce
				# DOPO la sparizione della finestra e' lavoro NUOVO del launcher
				# (misurato 2026-10-18, daytona/model2: il breaker uccise il
				# `batocera-resolution setMode` che emulatorlauncher stava
				# eseguendo; videoMode.py lesse il non-zero come "set failed",
				# ritento' con max_tries=2 e il tubo prese un secondo mode-set
				# identico — causato da noi, non dallo stock).
				_sess_pids=""
				for _d in /proc/[0-9]*; do _sess_pids="$_sess_pids ${_d#/proc/}"; done
			elif [ "${_game_seen:-0}" = 1 ]; then
				_win_gone=$((_win_gone + 1))
				# adaptive grace: an ESTABLISHED session (the window was on
				# screen continuously) is the exit -> fire on the first gone
				# poll; a just-appeared window keeps the full 3-poll grace so a
				# boot transient is never read as an exit.
				if [ "$_win_on" -ge "$STABLE_POLLS" ]; then _grace=1; else _grace=3; fi
				if [ "$_win_gone" -ge "$_grace" ] && [ "$_emu_polls" -ge "$EMU_MIN_POLLS" ]; then
					_emu_pids="$(pgrep -f emulatorlauncher 2>/dev/null | tr '\n' ' ')"
					# shellcheck disable=SC2086 # a pid list is the point
					_raw="$(_pipe_writers $_emu_pids | tr '\n' ' ')"
					_writers=""
					for _w in $_raw; do
						case "${_sess_pids} " in
						*" $_w "*) _writers="${_writers:+$_writers }$_w" ;;
						esac
					done
					if [ -n "${_writers// /}" ]; then
						log "deadlock breaker: game closed (window gone) while emulatorlauncher waits — closing its pipe writers (${_writers})"
						# shellcheck disable=SC2086 # a pid list is the point
						kill $_writers 2>/dev/null || true
						sleep 0.3
						# shellcheck disable=SC2086 # wine helpers ignore SIGTERM
						kill -9 $_writers 2>/dev/null || true
					elif [ -n "${_raw// /}" ]; then
						# nessun holder preesistente: la pipe e' tenuta solo dal
						# teardown del launcher. Non si spara, e si dice perche'.
						log "deadlock breaker: holders all younger than the game's window (launcher teardown) — not reaping (${_raw% })"
					fi
					_win_gone=0
				fi
			fi
		else
			_game_seen=0
			_win_on=0
			_win_gone=0
			_emu_polls=0
		fi

		if [ "$_sess_now" = 1 ]; then
			prev_game="active"
			sleep "$POLL"
			continue
		fi
		fired=""
		[ "$_first" = "1" ] && {
			_first=0
			fired="$fired boot-first-pass"
		}
		[ "$prev_game" = "active" ] && fired="$fired game-ended"
		prev_game="idle"
		if [ -f "$STATE_DIR/udev-poke" ]; then
			rm -f "$STATE_DIR/udev-poke" 2>/dev/null || true
			fired="$fired poke"
		fi
		if [ -f "$STATE_DIR/hotplug-trigger" ]; then
			rm -f "$STATE_DIR/hotplug-trigger" 2>/dev/null || true
			fired="$fired manual"
			# Una ri-scansione DRM vera: e' il canale per l'analogico, dove il
			# kernel non emette eventi (misurato 2026-10-18: stato a
			# `disconnected` 0,5 s dopo la combo, prima di ogni scrittura).
			# CRT_DUAL_UDEVADM_CMD e' la vernice dei test: senza, la seam
			# scatenerebbe una ri-scansione vera del box.
			if [ -n "${CRT_DUAL_UDEVADM_CMD:-}" ]; then
				bash -c "$CRT_DUAL_UDEVADM_CMD"
			else
				udevadm trigger --action=change --subsystem-match=drm 2>/dev/null || true
			fi
		fi
		fp=$(_sysfp)
		if [ "$fp" != "$prev_fp" ]; then
			[ -n "$prev_fp" ] && fired="$fired sysfs"
			prev_fp="$fp"
		fi
		es=$(_es_pid)
		if [ "$es" != "$prev_es" ]; then
			[ -n "$prev_es" ] && fired="$fired es-pid"
			prev_es="$es"
		fi
		if [ -n "$fired" ]; then
			_n=$(_nconn)
			case " $fired " in
			*" game-ended "* | *" boot-first-pass "*)
				# L'uscita dal gioco e il primo giro convergono SUBITO: qui
				# l'owner sta guardando e non c'e' nessun cavo in movimento.
				_prev_n="$_n"; debounce=0
				log "event:$fired → reconcile"
				_reconcile && settle=3 || true
				case " $fired " in *" game-ended "*) _es_content_gate ;; esac
				;;
			*)
				if [ "$_n" -lt "$_prev_n" ]; then
					# UNA USCITA IN MENO: e' il gesto che precede uno
					# spostamento di cavo. Si aspetta la finestra: se l'uscita
					# rientra, non si e' scritto niente (misurato: un rimbalzo
					# costava due apply e ~1 s di pannello nero).
					debounce="$DEBOUNCE_POLLS"
					log "event:$fired → uscita in meno ($_n < $_prev_n): aspetto $debounce poll"
				elif [ "$_n" -gt "$_prev_n" ]; then
					# AGGIUNTA: cancella l'attesa e applica subito (e' quello che
					# si vuole vedere).
					debounce=0
					log "event:$fired → aggiunta: reconcile"
					_reconcile && settle=3 || true
				elif [ "$debounce" -gt 0 ]; then
					# Un evento che NON aggiunge un'uscita mentre la finestra e'
					# aperta non la chiude: il gesto e' lo stesso (misurato
					# 2026-10-18: due poke per un solo stacco, e il secondo
					# applicava subito). Si continua ad aspettare.
					log "event:$fired → nessuna aggiunta: la finestra resta aperta ($debounce poll)"
				else
					# Un'AGGIUNTA si applica subito: e' quello che si vuole vedere.
					debounce=0
					log "event:$fired → reconcile"
					_reconcile && settle=3 || true
				fi
				_prev_n="$_n"
				;;
			esac
		elif [ "$debounce" -gt 0 ]; then
			debounce=$((debounce - 1))
			if [ "$debounce" -eq 0 ]; then
				log "debounce: nessuna aggiunta entro la finestra → reconcile"
				_reconcile && settle=3 || true
			fi
		elif [ "$settle" -gt 0 ]; then
			settle=$((settle - 1))
			if ! _apply_pass >/dev/null 2>&1; then
				log "settle-recheck: broken after a converged apply → reconcile"
				_reconcile && settle=3 || true
			else
				# Anche il settle controlla la finestra di ES: esiste per lo
				# stock che atterra DOPO il nostro apply, ed e' il caso in cui il
				# menu resta fuori misura (misurato 2026-10-18: 20 righe
				# "ES window ... NOT applied" in ~9 minuti e nessuna riparazione).
				# Una lettura di stato per passata di settle.
				_es_ok || _es_repair
			fi
		fi
		sleep "$POLL"
	done
	;;
*)
	echo "usage: display-reconcile.sh [--check|--once|--daemon|--session-start crt|lcd]" >&2
	exit 2
	;;
esac
exit 0
