#!/bin/bash
# RGS+15kHz install.sh (step 7: update-resilience gate).
#
# Deploys: engine package (+ our profiles), gameStart hook, RAM hoist
# (sitecustomize), pre-X S15 hook, engine boot-service shim, our RGS
# service, udev rule, VNC, owned box keys (es.resolution = 640x480i.60.00,
# global.videomode = max-640x480 pin, first-install backup; splash trio backup-only).
# Overlay writes are manifest-tracked ($PKG/overlay-manifest) so the boot
# service re-deploys them after rgs_config / upgrades. The live
# RGS/Batocera versions are recorded ($PKG/rgs-version) so verify.sh can
# FAIL closed after an RGS update (recovery = uninstall + install).
# GPU boot pins: the amdgpu dc=0 modprobe file (7b) and the Intel i915
# 480i patch on /boot (7c — /boot is persistent, no manifest entry) are
# deployed by the zz_ service one-shots so the FIRST boot is already
# correct.
#
# Deliberately NO reboot at the end (differs from engine install.sh):
# the owner connects the CRT first, then reboots for the tube session.
#
# Contract (install-discipline.md): idempotent, reversible (uninstall.sh
# + verify.sh 0), non-destructive (foreign first_script.sh FAILS loudly).
#
# Test seams (default = live paths; /tmp-rooted in tests):
# RGS15_PKG/HOOK/SVCDIR/SITE/UDEV/S15/VNC1/VNC2,
# RGS15_SKIP_KEYS/RELOAD/ENABLE=1 to skip live-only acts.

set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PKG="${RGS15_PKG:-/userdata/system/crt-dual}"
PKG_VERSION_FILE="${PKG}.version"
PKG_VERSION="rgs-15khz step7-resilience (engine 0a05ab6)"
HOOK_SRC="$REPO/src/engine/selector/first_script.sh"
HOOK_DST="${RGS15_HOOK:-/userdata/system/scripts/first_script.sh}"
SVCDIR="${RGS15_SVCDIR:-/userdata/system/services}"
ENGINE_SVC="zz_crt_dual"
OUR_SVC="zz_rgs_15khz"
VNC_SVC="zz_crt_dual_vnc"
SITE="${RGS15_SITE:-$(python3 -c 'import site; print(site.getsitepackages()[0])' 2>/dev/null)}"
SITECUSTOMIZE_SRC="$REPO/src/engine/selector/sitecustomize.py"
S15_SRC="$REPO/src/engine/service/crt-gen-initd.sh"
S15_DST="${RGS15_S15:-/etc/init.d/S15crt-dual-gen}"
UDEV_SRC="$REPO/src/engine/udev/99-crt-dual-hotplug.rules"
UDEV_DST="${RGS15_UDEV:-/etc/udev/rules.d/99-crt-dual-hotplug.rules}"
VNC1="${RGS15_VNC1:-/usr/bin/vnc}"
VNC2="${RGS15_VNC2:-/usr/bin/vnc-scaled}"
CRT_BOOT_MODE="640x480i.60.00"
CRT_PIN_MODE="max-640x480"
LOG="${RGS15_LOG:-/userdata/system/logs/rgs-15khz.log}"
MANIFEST="$PKG/overlay-manifest"
RGS_VERSION_SRC="${RGS15_RGS_VERSION_FILE:-/userdata/system/rgs.version}"
BATOCERA_VERSION_SRC="${RGS15_BATOCERA_VERSION_FILE:-/usr/share/batocera/batocera.version}"

fail() {
	echo "ERROR: $*" >&2
	exit 1
}

[ "$(id -u)" = "0" ] || fail "run as root"
[ -n "${RGS15_SKIP_ENABLE:-}" ] || command -v batocera-services >/dev/null 2>&1 \
	|| fail "batocera-services missing — is this stock RGS/Batocera?"
[ -f "$HOOK_SRC" ] || fail "repo tree incomplete: $HOOK_SRC missing"
[ -f "$SITECUSTOMIZE_SRC" ] || fail "repo tree incomplete: $SITECUSTOMIZE_SRC missing"

save_overlay() {
	# /etc + /usr/bin live in the overlay upper: unsaved = gone at reboot.
	if ! command -v batocera-save-overlay >/dev/null 2>&1; then
		echo "  WARN: batocera-save-overlay missing — overlay writes will not survive reboot" >&2
		return 1
	fi
	batocera-save-overlay >/dev/null 2>&1 || {
		echo "  WARN: overlay save failed" >&2
		return 1
	}
	echo "  overlay saved"
	return 0
}

manifest_add() {
	# $1 = installed overlay path (absolute). Manifest = re-deploy list.
	printf '%s\n' "$1" >>"$MANIFEST"
}

echo "=== RGS+15KHZ INSTALL (CRT path) — $(date +%FT%T) ==="

# Fresh-only: this script installs onto a STOCK box, never upgrades one.
# An existing package means a previous install — remove it first
# (uninstall.sh) or sync development changes (deploy.sh). Upgrading
# inside install.sh accumulated special cases (stop/start, pruning,
# exclusion lists); that machinery lives in deploy.sh now, on purpose.
if [ -d "$PKG/src" ]; then
	fail "already installed ($PKG/src exists) — uninstall.sh first, or deploy.sh to sync repo changes"
fi

# Prerequisite (owner decision, tested by tests/seams/test_install_requires_updater.sh):
# the box must be an UPDATED stock RGS. rgs.version is created by RGS's
# own updater (absent = fullinstall never ran it); the version gate and
# the stock-originals snapshot both key on that record. Refuse loudly
# with the fix instead of a bare cp error mid-snapshot.
[ -f "$RGS_VERSION_SRC" ] || fail "RGS version record absent ($RGS_VERSION_SRC) — run the RGS update tool once (in EmulationStation: Batocera config list, the RGS upgrade script), then re-run ./install.sh"

# ── 0. Stock originals snapshot (install-on-fresh = the only chance) ──
# batocera.conf has NO stock copy on disk: rgs/fix/ does not carry it and
# the RGS updater reassembles the live conf from itself (rgs_upgrade
# re-echoes BEGINCONF/RGSTUNING/ENDCONF — a fresh TUNING zone never
# arrives). This install-time snapshot is the only local original.
# rgs.version likewise (its only source is the RGS update repo).
STOCK_BACKUP="$PKG/backups/stock-originals"
mkdir -p "$STOCK_BACKUP"
cp -a "${RGS15_CONF:-/userdata/system/batocera.conf}" "$STOCK_BACKUP/batocera.conf.stock" \
	|| fail "stock batocera.conf snapshot failed"
cp -a "$RGS_VERSION_SRC" "$STOCK_BACKUP/rgs.version.stock" \
	|| fail "stock rgs.version snapshot failed"
echo "  stock originals snapshot -> $STOCK_BACKUP"

# ── 1. Engine package (code dirs of src/engine; the engine's dev entries
# docs/ tests/ never deploy — a new upstream code dir deploys itself;
# vnc blobs on disk included) ──
mkdir -p "$PKG" "$PKG/src"
for _d in "$REPO"/src/engine/*/; do
	_b="$(basename "$_d")"
	case "$_b" in docs|tests) continue ;; esac
	mkdir -p "$PKG/src/$_b"
	cp -a "$REPO/src/engine/$_b/." "$PKG/src/$_b/"
done
find "$PKG/src" -type f -name "*.sh" -exec chmod +x {} \;
find "$PKG/src/selector" "$PKG/src/api" -type f -name "*.py" -exec chmod +x {} \;
chmod +x "$PKG/src/vnc/vnc" "$PKG/src/vnc/vnc-scaled" "$PKG/src/vnc/binaries/x11vnc" 2>/dev/null || true
mkdir -p "$PKG/profiles"
cp -a "$REPO/src/profiles/." "$PKG/profiles/"
echo "  package -> $PKG (src + profiles)"
# per-code-dir byte-identity (src/engine also carries the engine's dev
# entries, which are deliberately NOT in the package — the package's dirs
# are the checklist)
_engine_drift=""
for _d in "$PKG"/src/*/; do
	_b="$(basename "$_d")"
	diff -r --exclude=overlay-manifest --exclude=backups "$REPO/src/engine/$_b" "$_d" >/dev/null 2>&1 \
		|| _engine_drift="$_engine_drift $_b"
done
[ -n "$_engine_drift" ] \
	&& fail "package drift:$_engine_drift differs from repo (re-run install.sh)"
diff -r "$REPO/src/profiles" "$PKG/profiles" >/dev/null 2>&1 \
	|| fail "package drift: $PKG/profiles differs from repo (re-run install.sh)"
echo "  package byte-identical to repo"
printf '%s\n' "$PKG_VERSION" >"$PKG_VERSION_FILE"
: >"$MANIFEST" # install is authoritative: fresh manifest every run
# RGS-version record (step 7 gate): the install is validated against the
# LIVE versions. An RGS update restores stock files, so verify.sh FAILS
# closed on mismatch (recovery = uninstall.sh + install.sh). Kept in
# $PKG root: outside deploy.sh code trees, removed by uninstall.sh.
_RGS_LIVE="$(cat "$RGS_VERSION_SRC" 2>/dev/null || true)"
_BAT_LIVE="$(cat "$BATOCERA_VERSION_SRC" 2>/dev/null || true)"
[ -n "$_RGS_LIVE" ] || fail "cannot read RGS version ($RGS_VERSION_SRC)"
[ -n "$_BAT_LIVE" ] || fail "cannot read Batocera version ($BATOCERA_VERSION_SRC)"
printf 'rgs.version=%s\nbatocera.version=%s\n' "$_RGS_LIVE" "$_BAT_LIVE" >"$PKG/rgs-version"
echo "  RGS version recorded: rgs.version=$_RGS_LIVE / batocera.version=$_BAT_LIVE"

# ── 2. Spec validation (errors HERE, never at gameStart) ──
for _spec in "$REPO"/src/profiles/*/spec.conf; do
	[ -f "$_spec" ] || continue
	_name="$(basename "$(dirname "$_spec")")"
	python3 "$REPO/src/engine/selector/merge.py" validate "$(dirname "$_spec")" "$_name" /userdata/system >/dev/null \
		|| fail "spec validation failed: $_name (fix the spec, never deploy broken)"
	echo "  spec OK: $_name"
done

# ── 3. gameStart hook (NEW file; foreign one FAILS the install) ──
mkdir -p "$(dirname "$HOOK_DST")"
if [ -e "$HOOK_DST" ] && ! cmp -s "$HOOK_DST" "$HOOK_SRC"; then
	fail "$HOOK_DST exists and differs — NOT overwriting (foreign hook)"
elif [ -e "$HOOK_DST" ]; then
	echo "  hook already installed (identical)"
else
	cp "$HOOK_SRC" "$HOOK_DST"
	chmod +x "$HOOK_DST"
	echo "  hook -> $HOOK_DST"
fi

# ── 4. RAM hoist (overlay, manifest-tracked; patterns vs RGS generators
#      are probed by verify.sh — a mismatch FAILS loud, never silent) ──
[ -n "$SITE" ] || fail "no python site-packages found"
cp "$SITECUSTOMIZE_SRC" "$SITE/sitecustomize.py" \
	|| fail "sitecustomize deploy failed"
manifest_add "$SITE/sitecustomize.py"
echo "  sitecustomize.py -> $SITE/sitecustomize.py (RAM hoist)"

# ── 5. Pre-X S15 hook (overlay, manifest-tracked) ──
cp "$S15_SRC" "$S15_DST" || fail "S15 deploy failed"
chmod +x "$S15_DST"
manifest_add "$S15_DST"
echo "  PRE-X hook -> $S15_DST"

# ── 6. Engine boot service — THIN SHIM (never a logic copy) ──
mkdir -p "$SVCDIR"
cat >"$SVCDIR/$ENGINE_SVC" <<EOF
#!/bin/bash
# $ENGINE_SVC — thin launcher written by rgs-15khz install.sh (never edit;
# re-run install.sh instead). The REAL service: $PKG/src/service/$ENGINE_SVC
exec bash "$PKG/src/service/$ENGINE_SVC" "\$@"
EOF
chmod +x "$SVCDIR/$ENGINE_SVC"
echo "  engine service shim -> $SVCDIR/$ENGINE_SVC"

# ── 7. Our RGS service (full copy, single logic copy in repo) ──
cp "$REPO/src/service/zz_rgs_15khz" "$SVCDIR/$OUR_SVC" || fail "service copy failed"
chmod +x "$SVCDIR/$OUR_SVC"
cmp -s "$REPO/src/service/zz_rgs_15khz" "$SVCDIR/$OUR_SVC" || fail "service copy drift"
echo "  RGS service -> $SVCDIR/$OUR_SVC"

# ── 7b. amdgpu legacy pin (one-shot NOW so the FIRST boot after install
#    already pins dc=0 before amdgpu binds; the boot service recomputes
#    every boot). dc=1 on kernels < 6.19 has no analog encoders — a
#    DC-class AMD tube stays black (tester R9 380 case, 2026-09-10).
bash "$SVCDIR/$OUR_SVC" amdgpu-legacy || echo "  WARN: amdgpu-legacy pin failed (see $LOG)"
echo "  amdgpu legacy pin recomputed (service log: $LOG)"

# ── 7c. Intel i915 480i patch (one-shot NOW so the FIRST boot after
#    install already boots with the patched module; the boot service
#    recomputes every boot and the /boot hook swaps the module BEFORE
#    udev). The binary is taken user-procured from the repo binaries dir
#    or fetched from the amxcs release for this exact kernel
#    (public URL, vermagic-checked; a foreign /boot hook or a mismatched
#    module is REFUSED — loud WARN, verify.sh flags it). See
#    zz_rgs_15khz i915-patch + THIRD-PARTY.md.
RGS15_I915_REPO="$REPO" RGS15_I915_ALLOW_FETCH=1 \
	bash "$SVCDIR/$OUR_SVC" i915-patch \
	|| echo "  WARN: i915 patch setup refused (see $LOG)" >&2
echo "  i915 patch recomputed (service log: $LOG)"

# ── 7d. rgs_crt_check tool (ES-launchable from the Batocera config menu;
#    foreign file FAILS the install) + install-source record (the tool's
#    deliberate uninstall runs THIS folder's uninstall.sh) ──
TOOL_SRC="$REPO/src/service/rgs_crt_check.sh"
TOOL_DST="${RGS15_TOOL:-/userdata/roms/rgs/rgs_crt_check.sh}"
mkdir -p "$(dirname "$TOOL_DST")"
if [ -e "$TOOL_DST" ] && ! cmp -s "$TOOL_DST" "$TOOL_SRC"; then
	fail "$TOOL_DST exists and differs — NOT overwriting (foreign file)"
elif [ -e "$TOOL_DST" ]; then
	echo "  check tool already installed (identical)"
else
	cp "$TOOL_SRC" "$TOOL_DST"
	chmod +x "$TOOL_DST"
	echo "  check tool -> $TOOL_DST (Batocera config menu)"
fi
printf '%s\n' "$REPO" >"$PKG/install-source"
echo "  install-source -> $PKG/install-source ($REPO)"

# ── 7e. gamelist entry + tile (single logic copy in the service) ──
bash "$SVCDIR/$OUR_SVC" gamelist-ensure \
	&& echo "  gamelist entry + tile ensured" \
	|| echo "  WARN: gamelist ensure failed (entry skipped)"

# ── 8. udev hotplug rule (overlay, manifest-tracked) ──
cp "$UDEV_SRC" "$UDEV_DST" || fail "udev rule deploy failed"
manifest_add "$UDEV_DST"
if [ -z "${RGS15_SKIP_RELOAD:-}" ]; then
	udevadm control --reload-rules 2>/dev/null || echo "  WARN: udev reload failed" >&2
fi
echo "  udev rule -> $UDEV_DST"

# ── 9. VNC (launchers + service copy + symlinks + registration) ──
ln -sf "$PKG/src/vnc/vnc" "$VNC1"
ln -sf "$PKG/src/vnc/vnc-scaled" "$VNC2"
cp "$PKG/src/service/$VNC_SVC" "$SVCDIR/$VNC_SVC" || fail "VNC service copy failed"
chmod +x "$SVCDIR/$VNC_SVC"
cmp -s "$PKG/src/service/$VNC_SVC" "$SVCDIR/$VNC_SVC" || fail "VNC service copy drift"
echo "  VNC commands -> $VNC1, $VNC2 + service $VNC_SVC"

# ── 10. Service registration ──
if [ -z "${RGS15_SKIP_ENABLE:-}" ]; then
	for _s in "$ENGINE_SVC" "$OUR_SVC" "$VNC_SVC"; do
		batocera-services enable "$_s" >/dev/null 2>&1 \
			|| fail "batocera-services enable $_s failed"
	done
	echo "  services registered: $ENGINE_SVC $OUR_SVC $VNC_SVC"
else
	echo "  service registration skipped (seam test)"
fi

# ── 11. Box keys (owned: set; splash trio: backup-only, generator-owned) ──
BOX_KEYS_BACKUP="$PKG/backups/box-keys"
if [ -z "${RGS15_SKIP_KEYS:-}" ]; then
	mkdir -p "$BOX_KEYS_BACKUP"
	for _key in es.resolution global.videomode global.videooutput splash.screen.resize global.videooutput2; do
		_bak="$BOX_KEYS_BACKUP/$_key"
		if [ ! -f "$_bak" ]; then
			_old="$(batocera-settings-get "$_key" 2>/dev/null || true)"
			if [ -z "$_old" ]; then
				echo "UNSET" >"$_bak"
			else
				printf '%s\n' "$_old" >"$_bak"
			fi
		fi
		case "$_key" in
		global.videooutput|splash.screen.resize|global.videooutput2)
			echo "  box key $_key backup-only (backup: $(cat "$_bak"))"
			continue
			;;
		esac
		# global.videomode is a max-form PIN (gate passes, setMode no-ops on
		# dual); es.resolution keeps the real boot mode name. See spec: all
		# *.videomode keys are max-640x480 since 2026-09-06 (gate-dead
		# specific forms error-noised every launch).
		_val="$CRT_BOOT_MODE"
		[ "$_key" = "global.videomode" ] && _val="$CRT_PIN_MODE"
		batocera-settings-set "$_key" "$_val" >/dev/null 2>&1 \
			|| fail "batocera-settings-set $_key failed"
		echo "  box key $_key=$_val (backup: $(cat "$_bak"))"
	done
else
	echo "  box keys skipped (seam test)"
fi

# ── 12. Persist overlay (loud fail: unsaved = half-installed) ──
if [ -n "${RGS15_SKIP_SAVE:-}" ]; then
	echo "  overlay save skipped (seam test)"
else
	save_overlay || fail "overlay save failed — re-run ./install.sh"
fi

echo ""
echo "Installed (CRT path). NO automatic reboot: connect the CRT, then"
echo "reboot for the tube session (desktop comes up 480i-managed)."
echo "Next:  ./verify.sh   (exit 0 = clean)"
