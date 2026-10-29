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
# Session owner record (2026-10-19): "pid starttime", written by
# apply_profile at gameStart. The supervisor reads it to end a session by
# ending the process ES waits for; the kernel start time makes a recycled pid
# impossible to mistake for the session.
LAUNCHER_FILE="${CRT_DUAL_LAUNCHER_FILE:-$STATE_DIR/launcher}"
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

# ── Session supervisor: one owner, three facts, one remedy ──────────────
# The session IS ES's wait() on emulatorlauncher (ADR-002). Measured
# 2026-10-19 (nesicax / Psychic Force 2012, rgs-15khz): the old deadlock
# breaker read the game's window correctly but tried to release the launcher
# by killing the WRITE holders of the pipes it reads. At 21:34:58 it fired
# and the chain did not dissolve — the holders were visible only in the
# per-THREAD fd tables (defunct leaders) — so no EOF ever arrived, ES never
# ran gameStop, the guard stayed up, ES died at 21:35:30 and the stock
# wrapper re-applied the boot (HDMI 1080p). With the guard up the reconciler
# exited every pass: the desktop stayed 1080p until a manual restore. A
# manual `batocera-es-swissknife --emukill` (kill the tree) returned ES
# twice out of two.
#
# So the end of a session is neither inferred nor negotiated: it is the end
# of the process ES waits for. Three structural facts decide it —
#   1. the launcher recorded at gameStart is gone (the normal end);
#   2. it no longer has ES above it — ES died or restarted, so that gameStop
#      will never come and the guard would outlive it;
#   3. the game's window was on screen and is now gone, or no window ever
#      came within the launch budget (a payload that died on startup).
# The remedy is one path: end the launcher's tree (TERM, then KILL: the
# loader ignores TERM), then run the ONE restore (the gameStop path).
# The probes are seamed so the LOGIC is testable without a live game.
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

# The session's launcher: written by apply_profile at gameStart (the hook
# runs inside emulatorlauncher, so it records the pid of the process ES
# waits for) together with the kernel start time, which makes a recycled
# pid impossible to mistake for the session.
_launcher_pid() {
	if [ -n "${CRT_DUAL_LAUNCHER_PID_CMD:-}" ]; then
		bash -c "$CRT_DUAL_LAUNCHER_PID_CMD"
		return $?
	fi
	local pid start cur
	read -r pid start <"$LAUNCHER_FILE" 2>/dev/null || true
	if [ -n "${pid:-}" ]; then
		if [ -r "/proc/$pid/stat" ]; then
			cur="$(sed 's/.*) //' "/proc/$pid/stat" 2>/dev/null | awk '{print $20}')"
			if [ -n "${start:-}" ] && [ "$cur" = "$start" ]; then
				printf '%s\n' "$pid"
			fi
		fi
		return 0
	fi
	# A guard written by an older build carries no record: fall back to the
	# box's launcher (the test batocera-es-swissknife uses; `pgrep -x` never
	# matches because comm is truncated to 15 characters).
	pgrep -f -n '(^|/)emulatorlauncher(\.py)?([[:space:]]|$)' 2>/dev/null | head -1
}

_under_es() { # $1 = pid -> rc 0 when walking up the parents reaches ES
	if [ -n "${CRT_DUAL_UNDER_ES_CMD:-}" ]; then
		bash -c "$CRT_DUAL_UNDER_ES_CMD"
		return $?
	fi
	local pp="${1:-}" i=0
	[ -n "$pp" ] || return 1
	while [ "$pp" -gt 1 ] && [ "$i" -lt 8 ]; do
		# The ancestor must BE EmulationStation, not merely mention it: the
		# kernel truncates comm to 15 chars ('emulationstatio'), which covers
		# both the wrapper script and the binary, while a full-cmdline match
		# counted any shell whose argv names it (measured 2026-10-20 in the
		# live demo: the test shell itself read as "ES above").
		case "$(cat "/proc/$pp/comm" 2>/dev/null)" in *emulationstatio*) return 0 ;; esac
		# comm may contain spaces: cut to the LAST ')' so the fields shift
		# correctly (an awk on field 4 would lie).
		pp="$(sed 's/.*) //' "/proc/$pp/stat" 2>/dev/null | awk '{print $2}')"
		case "$pp" in '' | *[!0-9]*) return 1 ;; esac
		i=$((i + 1))
	done
	return 1
}

_is_rgs_menu() { # $1 = launcher pid -> rc 0 when its argv runs a +rgs utility script
	if [ -n "${CRT_DUAL_IS_RGS_MENU_CMD:-}" ]; then
		bash -c "$CRT_DUAL_IS_RGS_MENU_CMD" _ "$1"
		return $?
	fi
	case "$(tr '\0' ' ' <"/proc/$1/cmdline" 2>/dev/null)" in
	*/userdata/roms/rgs/*.sh*) return 0 ;;
	esac
	return 1
}

_tree_pids() { # $1 = root -> the root and its live (non-zombie) descendants
	ps -eo pid=,ppid=,stat= | awk -v root="$1" '
		{ n++; p[n] = $1; pp[n] = $2; st[n] = $3 }
		END {
			inc[root] = 1
			# iterate to a fixed point: no depth limit to outgrow (audit
			# 2026-10-20: a fixed 8 would silently miss deeper descendants)
			do {
				changed = 0
				for (i = 1; i <= n; i++)
					# `in` does NOT create the key: a bare inc[pp[i]] reference
					# creates it empty, and then `p[i] in inc` is true for every
					# PARENT on the box (measured 2026-10-19: the kill took the
					# whole box down, X and ES included).
					if ((pp[i] in inc) && inc[pp[i]] && st[i] !~ /^Z/ && (p[i] in inc) == 0) {
						inc[p[i]] = 1
						changed = 1
					}
			} while (changed)
			for (i = 1; i <= n; i++) if (p[i] in inc) print p[i]
		}'
}

_end_tree() { # $1 = launcher pid: TERM the tree, KILL what survives
	local lp="$1" pids pg es_pg my_pg left n=0 count
	if [ -n "${CRT_DUAL_END_TREE_CMD:-}" ]; then
		bash -c "$CRT_DUAL_END_TREE_CMD" _ "$lp"
		return $?
	fi
	case "$lp" in
	'' | *[!0-9]* | 1 | 2)
		log "end-tree: refusing pid '${lp}' (never init, never kthreadd)"
		return 1
		;;
	esac
	pids="$(_tree_pids "$lp" | tr '\n' ' ')"
	[ -n "${pids// /}" ] || return 0
	# A session tree never contains init or kthreadd: a set that does means
	# the walk went wrong, and the box comes before the session (measured
	# 2026-10-19: a bug in the walk killed every parent, X and ES included).
	case " $pids " in
	*" 1 "* | *" 2 "*)
		log "end-tree: refusing a walk that reached init (${pids% })"
		return 1
		;;
	esac
	count=$(printf '%s\n' $pids | wc -l)
	if [ "$count" -gt 128 ]; then
		log "end-tree: refusing a walk of $count pids"
		return 1
	fi
	log "end-tree: ending ${pids% }"
	# A distinct process group also catches what wine reparented to init
	# (measured 2026-10-11). ES's group and our own are never touched.
	# The group-kill strikes ONLY if the group leader belongs to the launcher's
	# tree (e.g. the launcher itself or a descendant wine that called setsid/setpgid).
	# If $pg is NOT in $pids, the group was inherited from an ancestor (such as
	# openbox/xinit/the X session) and must NEVER be signaled as a group.
	pg="$(ps -o pgid= -p "$lp" 2>/dev/null | tr -d ' ')"
	es_pg="$(ps -o pgid= -p "$(_es_pid)" 2>/dev/null | tr -d ' ')"
	my_pg="$(ps -o pgid= -p "$$" 2>/dev/null | tr -d ' ')"
	_pg_in_tree=0
	case " $pids " in *" $pg "*) _pg_in_tree=1 ;; esac
	if [ "$_pg_in_tree" -eq 1 ] && [ -n "$pg" ] && [ "$pg" -gt 1 ] && [ "$pg" != "$es_pg" ] && [ "$pg" != "$my_pg" ]; then
		kill -TERM -- "-$pg" 2>/dev/null || true
	fi
	# shellcheck disable=SC2086 # a pid list is the point
	kill -TERM $pids 2>/dev/null || true
	while [ "$n" -lt 6 ] && kill -0 "$lp" 2>/dev/null; do
		sleep 0.5
		n=$((n + 1))
	done
	left="$(_tree_pids "$lp" | tr '\n' ' ')"
	if [ -n "${left// /}" ]; then
		# shellcheck disable=SC2086 # wine and the loader ignore TERM
		kill -KILL $left 2>/dev/null || true
	fi
	# The group needs its own KILL: a wine daemon reparented to init is NOT a
	# descendant of $lp, so it never lands in $left, and TERM is ignored by
	# design (audit 2026-10-20). Same guards as the TERM above.
	if [ "$_pg_in_tree" -eq 1 ] && [ -n "$pg" ] && [ "$pg" -gt 1 ] && [ "$pg" != "$es_pg" ] && [ "$pg" != "$my_pg" ]; then
		kill -KILL -- "-$pg" 2>/dev/null || true
	fi
	# Gamescope / Wine daemons and input mappers reparented to init outside the launcher's PGID
	# (gamescopereaper, wineserver, winedevice, evmapy): holding open files in /run/wine
	# blocks squashfs loop-device autoclear, and holding stdout hangs the ES launch pipeline.
	killall -9 gamescopereaper wineserver winedevice.exe evmapy 2>/dev/null || true
	return 0
}


_stale_session_clean() { # il gameStop che non c'e' stato (latchato dal chiamante)
	if [ -n "${CRT_DUAL_STALE_CLEAN_CMD:-}" ]; then
		bash -c "$CRT_DUAL_STALE_CLEAN_CMD"
		return $?
	fi
	local name
	name="$(cat "$PROFILE_FILE" 2>/dev/null)"
	if [ -n "$name" ]; then
		# lo STESSO percorso del gameStop, senza system: merge.py remove con
		# system vuoto e' il contratto di ripristino (l'ARCHIVIO e' la
		# verita' — una chiave mai applicata non ha archivio e viene saltata).
		bash "$HERE/../selector/remove_profile.sh" "$name"
	else
		# nessun profilo registrato: la riparazione di BOOT (crash-clean),
		# scritta per lo stesso caso (kill senza gameStop).
		bash "$HERE/../service/crash-clean.sh"
	fi
	# Unmount lingering squashfs and overlay mounts left in /run/wine
	for _m in $(awk '{print $2}' /proc/mounts 2>/dev/null | grep -E '^/(var/)?run/wine/' | tac); do
		umount -f -l "$_m" 2>/dev/null || true
	done
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
	# a relaunch was false-fired 3 s in by exactly that). The floor is
	# RELATIVE to the screen, not absolute (audit 2026-10-20): a native low
	# raster puts the screen itself at 256x224 (pyxel.videomode = 256x256 is
	# in our own spec) and a TATE title on a rotated raster is 240x320 -- an
	# absolute 320x240 floor read both as "no game" and the launch budget then
	# killed a LIVE game at 120 s. Half the screen's area separates a game
	# from a helper window on any raster. Fail safe: with no way to query X we
	# assume the game is on screen, so a blind probe never fires.
	command -v xdotool >/dev/null 2>&1 || return 0
	local _all _eswins _win _geo _w _h _sz _sw _sh
	# Fail safe: if the X query itself fails we assume the game is on screen.
	_all="$(DISPLAY="${DISPLAY:-:0}" xdotool search --onlyvisible --class '.' 2>/dev/null)" || return 0
	# EmulationStation is identified by its WINDOW CLASS, not a pid: the window
	# is owned by the `emulationstation` process while the session launcher is
	# its `dbus-run-session` parent (measured: window pid 6859 vs launcher
	# 6844), so a pid comparison would mistake ES's own window for the game.
	_eswins=" $(DISPLAY="${DISPLAY:-:0}" xdotool search --onlyvisible --class emulationstation 2>/dev/null | tr '\n' ' ') "
	# Read the screen bounding box ONCE outside the window loop (measured:
	# _x costs ~150 ms on dce_v6, so inside the loop it multiplied by the window count).
	_sz="$(_x | sed -n 's/^Screen 0:.*current \([0-9]* x [0-9]*\).*/\1/p')"
	_sw="${_sz%% x *}"; _sh="${_sz##* x }"
	case "$_sw" in '' | *[!0-9]*) _sw=0 ;; esac
	case "$_sh" in '' | *[!0-9]*) _sh=0 ;; esac
	for _win in $_all; do
		case "$_eswins" in *" $_win "*) continue ;; esac
		_geo="$(DISPLAY="${DISPLAY:-:0}" xdotool getwindowgeometry "$_win" 2>/dev/null \
			| sed -n 's/.*Geometry: \([0-9]*\)x\([0-9]*\).*/\1 \2/p')"
		_w="${_geo% *}"; _h="${_geo#* }"
		case "$_w" in '' | *[!0-9]*) continue ;; esac
		case "$_h" in '' | *[!0-9]*) continue ;; esac
		if [ "$_sw" -gt 0 ] && [ "$_sh" -gt 0 ]; then
			# Real game window: either occupies >= half of the screen raster (native low-res
			# like 256x224, 320x240, TATE 240x320) OR has standard game dimensions (>=640x480,
			# 720p, 1080p, super-res) while strictly rejecting tiny wine helper windows (1x1, 160x20).
			if [ $(( _w * _h * 2 )) -ge $(( _sw * _sh )) ] || { [ "$_w" -ge 640 ] && [ "$_h" -ge 480 ]; }; then
				return 0
			fi
		elif [ "$_w" -ge 320 ] && [ "$_h" -ge 240 ]; then
			# no readable screen: the old absolute floor, fail-safe
			return 0
		fi
	done
	return 1
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
	_prev_sess=0
	# Session supervisor state (2026-10-19): _seen counts the polls the game's
	# window has been on screen, _gone the polls it has been absent. The
	# window must be ESTABLISHED (SEEN_POLLS) before its disappearance counts
	# as the exit, so a boot transient is never read as one; then GONE_POLLS of
	# absence end the session. The launch budget (seconds, seam-knob
	# CRT_DUAL_SESSION_BUDGET) applies only while no window was ever
	# established: a payload that died on startup shows nothing at all.
	SEEN_POLLS=10
	GONE_POLLS="${CRT_DUAL_GONE_POLLS:-16}"
	_seen=0
	_gone=0
	_sess_start=0
	_budget="${CRT_DUAL_SESSION_BUDGET:-120}"
	_lost_budget="${CRT_DUAL_SESSION_LOST_BUDGET:-12}"
	_seen_at=0
	_first=1
	settle=0
	debounce=0
	_prev_n=$(_nconn)
	i=0
	while true; do
		_detect_done # nessun preload sopravvive al poll: vale per UNA passata
		i=$((i + 1))
		if [ "$ITERS" -gt 0 ] && [ "$i" -gt "$ITERS" ]; then break; fi

		# ── Session lifecycle: one owner, three facts, one remedy ───────
		# The session is ES's wait() on the launcher (probes above). Read
		# BEFORE the guard short-circuit: while a session is stuck the guard
		# is up, so a check placed after it would never run.
		_sess_now=0
		_session_active && _sess_now=1
		if [ "$_sess_now" = 1 ] && [ "${_prev_sess:-0}" = 0 ]; then
			_seen=0
			_gone=0
			# _seen_at is PER SESSION: carried over, a new launch inherits the
			# previous game's picture time and the lost-deadline fires on its
			# FIRST pass (measured 2026-10-20 in the live demo: 60 ms, wrong
			# reason, a false kill for every launch after a 12 s gap).
			_seen_at=0
			# the launch budget starts with the launch, not with the daemon
			_sess_start="$(stat -c %Y "$LAUNCHER_FILE" 2>/dev/null || date +%s)"
		fi
		_prev_sess=$_sess_now

		if [ "$_sess_now" = 1 ]; then
			_lp="$(_launcher_pid)"
			_end_why=""
			if [ -z "$_lp" ]; then
				_end_why="launcher gone"
			elif _is_rgs_menu "$_lp"; then
				# the RGS utility menu is a SEQUENCE of script windows: the gap
				# between two xterms is not an exit (measured 2026-10-12: the
				# breaker aborted the owner's update between two windows); even
				# if an update script reloads ES (killall -9 emulationstation),
				# the utility run is not an orphaned game session.
				:
			elif ! _under_es "$_lp"; then
				_end_why="launcher orphaned (ES gone)"
			elif _game_alive; then
				_seen=$((_seen + 1))
				_seen_at="$(date +%s)"
				_gone=0
			elif [ "$_seen" -ge "$SEEN_POLLS" ]; then
				_gone=$((_gone + 1))
				[ "$_gone" -ge "$GONE_POLLS" ] && _end_why="game window gone"
			else
				# A window that came and went before it was established is not
				# an exit on its own (a boot transient), but a session that HAD
				# a picture and lost it must not wait the whole launch budget:
				# measured risk (audit 2026-10-20): a game that crashes 3 s in
				# kept the screen frozen for the full 120 s. Two deadlines.
				_now="$(date +%s)"
				if [ "${_seen_at:-0}" -gt 0 ] && [ "$(( _now - _seen_at ))" -ge "$_lost_budget" ]; then
					_end_why="picture lost for ${_lost_budget}s"
				elif [ "$(( _now - _sess_start ))" -ge "$_budget" ]; then
					_end_why="no picture within ${_budget}s"
				fi
			fi
			if [ -n "$_end_why" ]; then
				log "session end: $_end_why — ending the launcher tree, then one restore"
				if [ -n "$_lp" ] && ! _end_tree "$_lp"; then
					# the walk refused (init reached / >128 pids): the processes
					# stay, and they are NOT supervised by anything else. The
					# desktop still comes first, but never silently (audit P3).
					log "session end: _end_tree REFUSED for pid $_lp — tree left running, desktop restored anyway"
				fi
				if _stale_session_clean; then
					log "session end: restore done (this pass is its game-ended)"
				else
					log "session end: restore FAILED — guard cleared anyway (the desktop comes first)"
				fi
				rm -f "$MODE_FILE" "$PROFILE_FILE" "$LAUNCHER_FILE" 2>/dev/null || true
				_sess_now=0
				_seen=0
				_seen_at=0
				_gone=0
			fi
			if [ "$_sess_now" = 1 ]; then
				prev_game="active"
				sleep "$POLL"
				continue
			fi
		else
			_seen=0
			_seen_at=0
			_gone=0
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
