#!/bin/bash
# get.sh — the ONE install/update entry for rgs-crt (feed foundation).
#
# Usage (fresh box or update, one line, no git on the box):
#   curl -fsSL https://raw.githubusercontent.com/frezeen/rgs-crt/main/get.sh | sudo bash
#
# What it does: fetches VERSION, fetches the release archive for that
# version (tag tarball, main-branch tarball as fallback), refuses when the
# extracted VERSION differs (a publish race aborts before anything is
# touched), runs the OLD uninstall.sh when a layer is installed, replaces
# the source tree (preserving user-procured binaries/), fetches procured
# binaries per the NEW binaries.lock (sha256-verified, skipped when the
# file on disk is already exact), then runs the NEW install.sh + verify.sh.
#
# Fail-safe direction: everything before the uninstall touches only a temp
# dir; a failed install leaves a working stock box (the old uninstall
# already restored stock). NEVER reboots — it prints the reboot
# instruction (same wording as install.sh).
#
# Test seams (defaults = live paths; /tmp-rooted in tests): RGS15_SRC,
# RGS15_PKG, RGS15_TMPDIR, RGS15_VERSION_URL, RGS15_TAG_BASE,
# RGS15_MAIN_URL, RGS15_FETCH_BIN (default curl), RGS15_FETCH_TIMEOUT.
#
# Source resolution: $RGS15_SRC when set, else the recorded install folder
# ($PKG/install-source, written by install.sh), else the default folder.
# Either way the OLD uninstall below runs from the resolved tree.

set -uo pipefail

VERSION_URL="${RGS15_VERSION_URL:-https://raw.githubusercontent.com/frezeen/rgs-crt/main/VERSION}"
TAG_BASE="${RGS15_TAG_BASE:-https://codeload.github.com/frezeen/rgs-crt/tar.gz/refs/tags}"
MAIN_URL="${RGS15_MAIN_URL:-https://codeload.github.com/frezeen/rgs-crt/tar.gz/refs/heads/main}"
PKG="${RGS15_PKG:-/userdata/system/crt-dual}"
SRC="${RGS15_SRC:-}"
if [ -z "$SRC" ]; then
	_rec="$(cat "$PKG/install-source" 2>/dev/null || true)" # || true: absent on fresh boxes, the default covers it
	if [ -n "$_rec" ] && [ -d "$_rec" ] && [ -f "$_rec/install.sh" ]; then
		SRC="$_rec"
	else
		SRC="/userdata/roms/rgs_crt"
	fi
fi
FETCH="${RGS15_FETCH_BIN:-curl}"
TIMEOUT="${RGS15_FETCH_TIMEOUT:-30}"
TMPDIR_SEAM="${RGS15_TMPDIR:-}"

fail() { echo "ERROR: $*" >&2; exit 1; }
warn() { echo "WARN: $*" >&2; }
log() { echo "  $*"; }

[ "$(id -u)" = "0" ] || fail "run as root (pipe through sudo bash)"

# Guard: a developer worktree syncs with deploy.sh, never with get.sh.
if [ -e "$SRC/.git" ]; then
	fail "developer worktree ($SRC/.git exists); use deploy.sh"
fi

# Every fetch carries a timeout: a bare fetch with no timeout can hang a
# headless box forever (the i915 fetch without one is the anti-pattern).
fetch() { # $1 = URL, $2 = outfile
	"$FETCH" -fsS --max-time "$TIMEOUT" -o "$2" "$1"
}

if [ -n "$TMPDIR_SEAM" ]; then
	TMPDIR="$TMPDIR_SEAM"
	mkdir -p "$TMPDIR" || fail "cannot use RGS15_TMPDIR=$TMPDIR"
	TMP_OWN=0
else
	TMPDIR="$(mktemp -d /tmp/rgs-crt-get.XXXXXX)" || fail "cannot create temp dir"
	TMP_OWN=1
fi
cleanup() { [ "$TMP_OWN" = "1" ] && rm -rf "$TMPDIR"; }
trap cleanup EXIT

echo "=== RGS-CRT GET (install/update entry) ==="
log "source: $SRC"

# ── a) version + archive into the temp dir only (nothing touched yet) ──
fetch "$VERSION_URL" "$TMPDIR/VERSION.remote" \
	|| fail "cannot fetch VERSION ($VERSION_URL)"
VERSION="$(cat "$TMPDIR/VERSION.remote" 2>/dev/null)"
[ -n "$VERSION" ] || fail "fetched VERSION is empty ($VERSION_URL)"
printf '%s' "$VERSION" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$' \
	|| fail "fetched VERSION '$VERSION' is not MAJOR.MINOR.REV"
log "version: $VERSION"

TAG_URL="$TAG_BASE/v$VERSION"
ARCH="$TMPDIR/pkg.tar.gz"
if fetch "$TAG_URL" "$ARCH"; then
	log "archive: tag v$VERSION"
else
	warn "tag archive missed ($TAG_URL); retrying once"
	if fetch "$TAG_URL" "$ARCH"; then
		log "archive: tag v$VERSION (retry)"
	else
		warn "tag v$VERSION unavailable; falling back to the main branch"
		fetch "$MAIN_URL" "$ARCH" \
			|| fail "cannot fetch the archive (tag $TAG_URL and main $MAIN_URL both failed)"
		log "archive: main branch (fallback)"
	fi
fi

NEWDIR="$TMPDIR/new"
mkdir -p "$NEWDIR" || fail "cannot create $NEWDIR"
tar -xzf "$ARCH" -C "$NEWDIR" || fail "archive is not a valid tar.gz ($TAG_URL)"
# Codeload wraps the tree in one top-level dir; accept flat or wrapped.
TREEDIR=""
if [ -f "$NEWDIR/VERSION" ]; then
	TREEDIR="$NEWDIR"
else
	for _d in "$NEWDIR"/*/; do
		[ -d "$_d" ] || continue
		if [ -f "${_d}VERSION" ]; then TREEDIR="${_d%/}"; break; fi
	done
	[ -n "$TREEDIR" ] || fail "archive has no VERSION (not a release tree?)"
fi

# ── b) coherence: extracted VERSION must equal fetched VERSION (else a
# publish race is in flight — abort BEFORE any uninstall) ──
GOT="$(cat "$TREEDIR/VERSION" 2>/dev/null)"
[ "$GOT" = "$VERSION" ] \
	|| fail "publish race: archive VERSION (${GOT:-empty}) != fetched VERSION ($VERSION) — nothing touched, retry later"
log "coherence: archive VERSION matches ($VERSION)"

# ── c) installed? run the OLD uninstall from $SRC first ($SRC resolved
# to the recorded install folder above, so this is the right old tree) ──
if [ -d "$PKG/src" ]; then
	[ -x "$SRC/uninstall.sh" ] \
		|| fail "installed ($PKG/src exists) but $SRC/uninstall.sh is missing — refusing to strand the box (inspect by hand)"
	log "installed tree found — running the OLD uninstall first"
	bash "$SRC/uninstall.sh" \
		|| fail "OLD uninstall failed — nothing replaced (inspect by hand)"
else
	log "no installed tree ($PKG/src absent — fresh install)"
fi

# ── d) replace the $SRC content: clean stale files, keep procured
# binaries (copied aside first, restored after) ──
[ -n "$SRC" ] && [ "$SRC" != "/" ] || fail "refusing an empty/root SRC"
mkdir -p "$SRC" || fail "cannot create $SRC"
KEPT="$TMPDIR/kept-binaries"
mkdir -p "$KEPT" || fail "cannot create $KEPT"
for _b in "$SRC"/src/profiles/*/binaries "$SRC"/src/service/i915/binaries; do
	[ -d "$_b" ] || continue
	_rel="${_b#"$SRC"/}"
	mkdir -p "$KEPT/$(dirname "$_rel")" || fail "cannot stage $_rel"
	cp -a "$_b" "$KEPT/$_rel" || fail "cannot preserve $_rel"
	log "preserved procured: $_rel"
done
find "$SRC" -mindepth 1 -delete || fail "cannot clean $SRC"
cp -a "$TREEDIR/." "$SRC/" || fail "cannot place the new tree in $SRC"
if [ -d "$KEPT/src" ]; then
	cp -a "$KEPT/src/." "$SRC/src/" || fail "cannot restore procured binaries"
	log "restored procured binaries"
fi
log "source tree replaced: $SRC ($VERSION)"

# ── e) procured binaries per the NEW lock: exact on disk = skip (no
# download); otherwise download, verify sha256, place executable.
# Offline with a binary missing = LOUD warn, layer still installs
# (verify.sh warns on absent user-procured binaries, same contract). ──
LOCK="$SRC/binaries.lock"
if [ -f "$LOCK" ]; then
	while IFS= read -r _line || [ -n "$_line" ]; do # keep the last line when unterminated
		case "$_line" in ''|\#*) continue ;; esac
		_path="$(printf '%s' "$_line" | cut -d'|' -f1 | tr -d ' \t\r\n')"
		_url="$(printf '%s' "$_line" | cut -d'|' -f2 | tr -d ' \t\r\n')"
		_sha="$(printf '%s' "$_line" | cut -d'|' -f3 | tr -d ' \t\r\n' | tr 'A-Z' 'a-z')"
		if [ -z "$_path" ] || [ -z "$_url" ] || [ -z "$_sha" ]; then
			warn "binaries.lock: skipping malformed line: $_line"
			continue
		fi
		_dst="$SRC/$_path"
		if [ -f "$_dst" ] && [ "$(sha256sum "$_dst" | cut -d' ' -f1)" = "$_sha" ]; then
			log "procured exact, skip (no download): $_path"
			continue
		fi
		_tmpbin="$TMPDIR/bin.$$"
		if fetch "$_url" "$_tmpbin"; then
			_got="$(sha256sum "$_tmpbin" | cut -d' ' -f1)"
			if [ "$_got" = "$_sha" ]; then
				mkdir -p "$(dirname "$_dst")" || fail "cannot create $(dirname "$_dst")"
				mv -f "$_tmpbin" "$_dst" || fail "cannot place $_dst"
				chmod +x "$_dst" || fail "cannot chmod $_dst"
				log "procured: $_path (sha256 verified)"
			else
				warn "procured $_path sha MISMATCH (got $_got, want $_sha) — NOT placed (layer continues without it)"
				rm -f "$_tmpbin"
			fi
		else
			warn "procured $_path not downloaded (offline?) — layer installs without it (fetch it by hand, see binaries.lock)"
			rm -f "$_tmpbin"
		fi
	done < "$LOCK"
else
	warn "no binaries.lock in the new tree — skipping procured binaries"
fi

# ── f) the NEW install + verify ──
[ -x "$SRC/install.sh" ] || fail "new tree has no install.sh ($SRC/install.sh)"
bash "$SRC/install.sh" \
	|| fail "install.sh failed — the box is stock-safe (the old uninstall already restored stock), inspect by hand"
[ -x "$SRC/verify.sh" ] || fail "new tree has no verify.sh ($SRC/verify.sh)"
if bash "$SRC/verify.sh"; then
	log "verify: CLEAN"
else
	_vrc=$?
	fail "verify.sh reported DIRTY (rc=$_vrc) — inspect by hand"
fi

echo ""
echo "Installed (CRT path). NO automatic reboot: connect the CRT, then"
echo "reboot for the tube session (desktop comes up 480i-managed)."
echo "Next:  ./verify.sh   (exit 0 = clean)"
