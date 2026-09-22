#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
# Copyright (C) 2026 FreZeeN
# Part of crt-dual — https://github.com/frezeen
# crtc-owner.sh — which DRM connector actually OWNS a CRTC (kernel truth).
#
# Why this exists (2026-09-22 tester report, AMD R9 380, CRT-only box):
# the drm sysfs `enabled` flag means "an encoder is attached", NOT "a CRTC
# is assigned" (drm_sysfs.c: enabled = connector->encoder != NULL; AMD
# dce_v6/DCE10 keeps an encoder on the digital ports at boot). The
# 2026-09-19 stale-CRTC invariant must still catch a connector that KEEPS
# a CRTC after its output goes away, but an encoder-only attach must not
# be treated as one: on the tester box the phantom `unplanned(DVI-D-1)`
# failed every apply and the bounded repair blinked the tube forever.
# modetest (stock Batocera 43.1) exposes the mapping:
#   connector -> current encoder -> crtc   (crtc 0 = no CRTC).
# Read-only: no forced probes, no writes, one call per run.
#
# API:
#   crtc_refresh           drop the cached snapshot (long-lived callers
#                          like the rig: connectors change under force)
#   crtc_snapshot          cache the kernel snapshot (idempotent per run)
#   crtc_of <connector>    -> "<crtc-id>" | "" (no CRTC) | "?" (unknown)
# Env seam (tests): CRT_DUAL_MODETEST overrides the tool.
set -uo pipefail
MODETEST="${CRT_DUAL_MODETEST:-modetest}"

_crtc_snapshot=""
_crtc_snapshot_state=""
crtc_refresh() { # forget the snapshot; the next crtc_of re-reads the kernel
	_crtc_snapshot=""
	_crtc_snapshot_state=""
}
crtc_snapshot() { # one modetest call per run; a broken/absent tool = unknown
	[ "$_crtc_snapshot_state" = "done" ] && return 0
	_crtc_snapshot_state="done"
	_crtc_snapshot=$(timeout 5 "$MODETEST" -c -e 2>/dev/null) || _crtc_snapshot=""
	case "$_crtc_snapshot" in
	*Connectors:*Encoders:* | *Encoders:*Connectors:*) ;;
	*) _crtc_snapshot="" ;; # structural sanity: both tables must be present
	esac
}

crtc_of() { # $1 = DRM connector name (e.g. DVI-D-1)
	local name="$1"
	crtc_snapshot
	[ -n "$_crtc_snapshot" ] || {
		printf '?'
		return 0
	}
	printf '%s\n' "$_crtc_snapshot" | awk -F'\t' -v n="$name" '
		/^Connectors:/ { sec = "c"; next }
		/^Encoders:/   { sec = "e"; next }
		/^[A-Z][A-Za-z]*:/ { sec = ""; next }
		sec == "c" && NF >= 4 {
			nm = $4; gsub(/[[:space:]]+$/, "", nm)
			if (nm == n && !found) { enc = $2; found = 1 }
		}
		sec == "e" && NF >= 2 { crtc[$1] = $2 }
		END {
			if (!found) { print "?"; exit }
			if (enc == "" || enc == "0") { print ""; exit }
			if (!(enc in crtc)) { print "?"; exit }
			print (crtc[enc] == "0" ? "" : crtc[enc])
		}'
}
