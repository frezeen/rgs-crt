#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
# Copyright (C) 2026 FreZeeN
# Part of crt-dual — https://github.com/frezeen
# crash-clean.sh — CRT-DUAL: boot crash recovery, level 2
#
# Restores the EXACT pre-game stock state left by a crash (power loss /
# kill without gameStop):
# 1. marked profile blocks in the tracked config files (flat +
# section-aware) — removed
# 2. full-file configs (e.g. the CRT profile's mame.ini) — restored
# from the persistent backup (merge.py remove)
# 3. swapped binaries (e.g. GroovyMAME over /usr/bin/mame/mame) —
# retargeted back to the immutable stock (merge.py remove)
# 4. stale runtime state (/tmp/crt-dual-*) — removed
#
# Level 1 (next gameStart pre-clean) is inside merge.py apply. This
# script is the level 2 boot cleanup, run by zz_crt_dual at boot.
#
# The engine's merge.py remove IS the recovery (idempotent, no-op when
# nothing active): for every profile that has a persistent backup, run
# remove. The awk fallback below covers marked blocks whose profile was
# deleted between sessions (defensive, byte-for-byte removal).
#
# Atomic write: temp + fsync + mv in the same directory (temp-files rule).
#
# Env: CRT_DUAL_PKG_ROOT (default /userdata/system/crt-dual),
# CRT_DUAL_TRACKED_ROOT (default /userdata/system) and
# CRT_DUAL_STATE_ROOT (default /tmp) — overridable for dry-run tests
# against a copy — tests never touch the live box.

set -uo pipefail

PKG_ROOT="${CRT_DUAL_PKG_ROOT:-/userdata/system/crt-dual}"
ROOT="${CRT_DUAL_TRACKED_ROOT:-/userdata/system}"
STATE_ROOT="${CRT_DUAL_STATE_ROOT:-/tmp}"

# Tracked config files (defensive fallback only — the real
# removal is merge.py): retroarchcustom.cfg (flat), per-core .opt (flat),
# mame.ini (section-aware — the marker removes injected keys regardless).
# NOTE: the real MAME inipath (mameGenerator.py:188) is
# configs/mame + configs/mame/ini — the FIRST entry is the target.
TRACKED_FILES=(
	"$ROOT/configs/retroarch/retroarchcustom.cfg"
	"$ROOT/configs/mame/mame.ini"
	"$ROOT/configs/mame/ini/mame.ini"
)
OPT_GLOB="$ROOT/configs/retroarch/config/*/*.opt"

# Removes the marked block from one file (atomic). Returns 0 whether or
# not a block was found (idempotent cleanup).
clean_file() {
	local file="$1" tmp
	[ -f "$file" ] || return 0
	# Key marker (flat files configgen rewrites) OR comment marker
	# (mame.ini, not rewritten). Either is residue to remove.
	if ! grep -qE '^(# --- CRT-DUAL PROFILE:|crt_dual_profile\s*=)' "$file"; then
		return 0 # no marker — untouched
	fi
	# Drop comment blocks AND the key-marker line(s).
	tmp="$(dirname "$file")/.crash-clean.$$"
	if ! awk '/^# --- CRT-DUAL PROFILE:/{skip=1; next}
		skip && /^# --- \/CRT-DUAL PROFILE ---/{skip=0; next}
		!skip && $0 !~ /^crt_dual_profile\s*=/{print}' "$file" >"$tmp"; then
		rm -f "$tmp"
		return 1
	fi
	sync -d "$tmp" 2>/dev/null || true # fsync best-effort; mv is atomic regardless
	if ! mv "$tmp" "$file"; then
		rm -f "$tmp"
		return 1
	fi
	echo "CRT-DUAL-CRASH-CLEAN: removed marked block from $file"
}

# ── 1. Engine recovery: profiles with a persistent backup ──
# merge.py remove is idempotent and restores blocks + configs + binaries.
MERGE="$PKG_ROOT/src/selector/merge.py"
if [ -f "$MERGE" ] && [ -d "$PKG_ROOT/profiles" ] && [ -d "$PKG_ROOT/backups" ]; then
	for _backup in "$PKG_ROOT/backups"/*/; do
		[ -d "$_backup" ] || continue
		_name="$(basename "$_backup")"
		if [ -d "$PKG_ROOT/profiles/$_name" ]; then
			echo "CRT-DUAL-CRASH-CLEAN: recovering profile $_name (backup found)"
			python3 "$MERGE" remove "$PKG_ROOT/profiles/$_name" "$_name" "$ROOT" "$PKG_ROOT/backups" \
				>/dev/null 2>&1 || echo "CRT-DUAL-CRASH-CLEAN: WARN — recovery of $_name failed" >&2
		fi
	done
fi

# ── 2. Defensive fallback: marked blocks without a profile (deleted
# between sessions) — awk removal, byte-for-byte. ──
# $OPT_GLOB is intentionally unquoted: it must expand as a glob; a glob
# with no match stays a literal path and is skipped by the -f test below.
for _f in "${TRACKED_FILES[@]}" $OPT_GLOB; do
	[ -f "$_f" ] || continue
	clean_file "$_f" || echo "CRT-DUAL-CRASH-CLEAN: WARN — failed to clean $_f" >&2
done

# ── 3. Stale runtime state (a boot must start clean) ──
for _s in crt-dual-mode crt-dual-profile crt-dual-probe-ok; do
	if [ -f "$STATE_ROOT/$_s" ]; then
		rm -f "$STATE_ROOT/$_s" || true # best-effort; absence is the clean state
		echo "CRT-DUAL-CRASH-CLEAN: removed stale state $STATE_ROOT/$_s"
	fi
done

exit 0
