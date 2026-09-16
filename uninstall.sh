#!/bin/bash
# RGS+15kHz uninstall.sh (step 6: full CRT-path integration).
#
# Restores the exact stock state, reverse order: services off, overlay
# files out, RAM hoist out, hook out (byte-identical only), box keys
# restored from first-install backups (value or exact absence), package
# + logs + session files out. Overlay removal is save-attempted (warn on
# fail — a reboot heals to stock image anyway).
# Refuses while a game session is active.

set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PKG="${RGS15_PKG:-/userdata/system/crt-dual}"
PKG_VERSION_FILE="${PKG}.version"
HOOK_SRC="$REPO/src/engine/selector/first_script.sh"
HOOK_DST="${RGS15_HOOK:-/userdata/system/scripts/first_script.sh}"
SVCDIR="${RGS15_SVCDIR:-/userdata/system/services}"
ENGINE_SVC="zz_crt_dual"
OUR_SVC="zz_rgs_15khz"
VNC_SVC="zz_crt_dual_vnc"
SITE="${RGS15_SITE:-$(python3 -c 'import site; print(site.getsitepackages()[0])' 2>/dev/null)}"
S15_DST="${RGS15_S15:-/etc/init.d/S15crt-dual-gen}"
UDEV_DST="${RGS15_UDEV:-/etc/udev/rules.d/99-crt-dual-hotplug.rules}"
VNC1="${RGS15_VNC1:-/usr/bin/vnc}"
VNC2="${RGS15_VNC2:-/usr/bin/vnc-scaled}"
# Logs dir is a PATH SEAM like every other live target (the 2026-09-10
# seam-leak incident: a hermetic uninstall must never delete the LIVE
# runtime logs — tests override this; defaults = live paths).
LOGS_DIR="${RGS15_LOGS_DIR:-/userdata/system/logs}"
OWN_LOGS="rgs-15khz.log selector-core.log"

fail() {
	echo "ERROR: $*" >&2
	exit 1
}

[ "$(id -u)" = "0" ] || fail "run as root"

# ── Guard: no game session may be active ──
if [ -f /tmp/crt-dual/profile ] || [ -f /tmp/crt-dual-mode ]; then
	if pgrep -x retroarch >/dev/null 2>&1 || pgrep -f "[e]mulatorlauncher -system" >/dev/null 2>&1; then
		fail "a game session is active — quit the game first (refusing to pull the runtime)"
	fi
fi

echo "=== RGS+15KHZ UNINSTALL (CRT path) — $(date +%FT%T) ==="

# ── 1. Services: stop running instances, disable, remove files ──
# (stop FIRST: x11vnc/watcher execute from the package — removing files
# under them orphans headless processes; disable alone does not stop.)
if [ -z "${RGS15_SKIP_ENABLE:-}" ]; then
	for _s in "$VNC_SVC" "$ENGINE_SVC" "$OUR_SVC"; do
		batocera-services stop "$_s" >/dev/null 2>&1 || true
	done
	sleep 2
	for _s in "$ENGINE_SVC" "$OUR_SVC" "$VNC_SVC"; do
		if batocera-settings-get system.services 2>/dev/null | tr ' ' '\n' | grep -qx "$_s"; then
			batocera-services disable "$_s" >/dev/null 2>&1 \
				|| fail "batocera-services disable $_s failed"
			echo "  service unregistered: $_s"
		fi
	done
else
	echo "  service unregistration skipped (seam test)"
fi
rm -f "$SVCDIR/$ENGINE_SVC" "$SVCDIR/$OUR_SVC" "$SVCDIR/$VNC_SVC"
echo "  service files removed"

# ── 2. VNC symlinks ──
rm -f "$VNC1" "$VNC2"
echo "  VNC symlinks removed"

# ── 2b. GPU dotclock floor pieces: the RA config-dir switchres.ini WE
#      created (stock has none; restoring stock = removing it) + the
#      measurement cache ($PKG/state/dotclock — removed with the package
#      tree below). /etc/switchres.ini is NEVER written by the current
#      architecture (read-only base + measurement math); the restore
#      below stays for LEGACY installs (older duties edited that one
#      line in place) and is idle when the file is already stock.
RA_SWITCHRES="${RGS15_RA_SWITCHRES:-/userdata/system/configs/retroarch/switchres.ini}"
SYS_SWITCHRES="${RGS15_SYS_SWITCHRES:-/etc/switchres.ini}"
rm -f "$RA_SWITCHRES" && echo "  RA config-dir switchres.ini removed (stock has none)"
if [ -f "$SYS_SWITCHRES" ]; then
	if grep -qE '^[[:space:]]*dotclock_min[[:space:]]+0$' "$SYS_SWITCHRES" 2>/dev/null; then
		echo "  /etc/switchres.ini already stock (dotclock_min 0)"
	else
		sed -i -E 's/^([[:space:]]*dotclock_min[[:space:]]+).*/\10/' "$SYS_SWITCHRES" \
			&& echo "  /etc/switchres.ini dotclock_min restored to stock (0)" \
			|| echo "  WARN: could not restore $SYS_SWITCHRES dotclock_min (inspect by hand)" >&2
	fi
fi

# ── 3. Overlay files: udev + S15 + amdgpu-legacy modprobe pin
#      (removal persisted below) ──
MODPROBE_DST="${RGS15_MODPROBE_CONF:-/etc/modprobe.d/rgs-15khz-amdgpu-legacy.conf}"
rm -f "$UDEV_DST" "$S15_DST" "$MODPROBE_DST"
if [ -z "${RGS15_SKIP_RELOAD:-}" ]; then
	udevadm control --reload-rules 2>/dev/null || true
fi
echo "  udev rule + S15 hook + amdgpu-legacy pin removed"

# ── 3b. /boot i915 pieces (persistent files, no overlay save needed):
#      hook removed ONLY if byte-identical to ours (foreign = left in
#      place, loud — never destroy someone else's boot hook), module is
#      ours and always removed. /lib/modules is the RAM overlay: the
#      stock i915 is back at the next boot by itself. ──
BOOT_HOOK="${RGS15_BOOT_HOOK:-/boot/boot-custom.sh}"
BOOT_MOD="${RGS15_BOOT_MOD:-/boot/i915-patched.ko}"
if [ -e "$BOOT_HOOK" ] || [ -e "$BOOT_MOD" ]; then
	if ! (
		mount -o remount,rw /boot 2>/dev/null || exit 9
		trap 'sync; mount -o remount,ro /boot 2>/dev/null' EXIT
		if [ -e "$BOOT_HOOK" ]; then
			if cmp -s "$BOOT_HOOK" "$REPO/src/service/i915/boot-custom.sh"; then
				rm -f "$BOOT_HOOK"
				echo "  boot hook removed"
			else
				echo "ERROR: $BOOT_HOOK differs from ours — NOT removing (foreign boot hook left in place)" >&2
				exit 1
			fi
		fi
		if [ -e "$BOOT_MOD" ]; then
			rm -f "$BOOT_MOD" && echo "  i915 patch removed (next boot loads stock i915)"
		fi
	); then
		fail "i915 /boot cleanup failed (foreign boot hook — inspect by hand; ours NOT removed)"
	fi
else
	echo "  boot hook + i915 patch already absent"
fi

# ── 4. RAM hoist (+ probe bytecode cache) ──
if [ -n "$SITE" ]; then
	rm -f "$SITE/sitecustomize.py"
	rm -f "$SITE/__pycache__/sitecustomize."*.pyc 2>/dev/null || true
	echo "  sitecustomize.py removed"
fi

# ── 5. Hook: remove ONLY if byte-identical to ours ──
if [ -e "$HOOK_DST" ]; then
	if cmp -s "$HOOK_DST" "$HOOK_SRC"; then
		rm -f "$HOOK_DST"
		echo "  hook removed"
	else
		fail "$HOOK_DST differs from ours — NOT removing (foreign hook left in place)"
	fi
else
	echo "  hook already absent"
fi

# ── 5b. Check tool: remove ONLY if byte-identical to ours ──
TOOL_DST="${RGS15_TOOL:-/userdata/roms/rgs/rgs_crt_check.sh}"
TOOL_SRC="$REPO/src/service/rgs_crt_check.sh"
if [ -e "$TOOL_DST" ]; then
	if cmp -s "$TOOL_DST" "$TOOL_SRC"; then
		rm -f "$TOOL_DST"
		echo "  check tool removed"
	else
		fail "$TOOL_DST differs from ours — NOT removing (foreign file left in place)"
	fi
fi

# ── 5c. gamelist: restore first-install backup, remove our tile image ──
GL="/userdata/roms/rgs/gamelist.xml"
GLB="$PKG/backups/rgs-gamelist.xml"
if [ -f "$GLB" ] && [ -f "$GL" ]; then
	if grep -q 'rgs_crt_check.sh' "$GL"; then
		cp "$GLB" "$GL"
		echo "  gamelist restored from first-install backup"
	fi
fi
rm -f /userdata/roms/rgs/media/images/rgs_crt_check.png

# ── 6. Box keys: restore value-or-absence from first-install backups ──
# + our own written key (rgs-15khz.dotclock_min — the probe's measured
# value; uninstall removes it, stock = absent).
BOX_KEYS_BACKUP="$PKG/backups/box-keys"
if [ -z "${RGS15_SKIP_KEYS:-}" ]; then
	sed -i '/^rgs-15khz\.dotclock_min[[:space:]]*=/d' /userdata/system/batocera.conf 2>/dev/null || true
	echo "  our key rgs-15khz.dotclock_min removed (a manual floor can be re-set after install)"
	for _key in es.resolution global.videomode global.videooutput splash.screen.resize global.videooutput2; do
		_bak="$BOX_KEYS_BACKUP/$_key"
		[ -f "$_bak" ] || continue
		_old="$(cat "$_bak")"
		if [ "$_old" = "UNSET" ]; then
			sed -i "/^$(printf '%s' "$_key" | sed 's/\./\\./g')=/d" /userdata/system/batocera.conf 2>/dev/null || true
			echo "  box key $_key removed (was absent before install)"
		else
			batocera-settings-set "$_key" "$_old" >/dev/null 2>&1 \
				&& echo "  box key $_key restored to $_old" \
				|| echo "  WARN: restore $_key=$_old failed — fix by hand" >&2
		fi
	done
else
	echo "  box keys skipped (seam test)"
fi

# ── 3c. launcher restore (the raster hunks: stock snapshot, byte-exact;
#      snapshot-only, same rule as 3b: a foreign file is never destroyed) ──
RES_BAK="${RGS15_RES_BAK:-$PKG/backups/stock-originals/batocera-resolution}"
RES_DST="${RGS15_RES_TARGET:-/usr/bin/batocera-resolution}"
if [ -f "$RES_BAK" ]; then
	if grep -q "RGS-15KHZ-EXT (stock raster channel" "$RES_DST" 2>/dev/null; then
		cp "$RES_BAK" "$RES_DST" \
			&& echo "  launcher restored to stock (raster hunks removed)" \
			|| echo "  WARN: launcher restore failed (verify flags it)" >&2
	else
		echo "  launcher already stock (hunks absent — nothing to restore)"
	fi
elif grep -q "RGS-15KHZ-EXT (stock raster channel" "$RES_DST" 2>/dev/null; then
	echo "  WARN: launcher hunks present but NO stock snapshot found — left in place (never strand the box; reinstall to re-snapshot)" >&2
fi

# ── 7. Package + version marker (kills manifest + key backups) ──
# The stock-originals snapshot is NOT layer data: it is the only local
# copy of the stock batocera.conf (no rgs/fix copy exists and the RGS
# updater reassembles the live conf from itself). Rescue it outside the
# package before the kill; a later install snapshots the then-current
# conf again.
STOCK_RESCUE="/userdata/system/rgs-15khz-stock-originals"
if [ -d "$PKG/backups/stock-originals" ]; then
	mkdir -p "$STOCK_RESCUE"
	if cp -a "$PKG/backups/stock-originals/." "$STOCK_RESCUE/"; then
		echo "  stock originals rescued -> $STOCK_RESCUE (only local copy of the stock conf, kept)"
	else
		echo "  WARN: stock originals rescue failed" >&2
	fi
fi
rm -rf "$PKG" "$PKG_VERSION_FILE"
echo "  package removed"

# ── 8. Own runtime logs (explicit list, LOGS_DIR seam) ──
for _l in $OWN_LOGS; do
	rm -f "$LOGS_DIR/$_l" && echo "  log removed: $_l"
done

# ── 9. Session ephemera (safe: guard above proved no live game) ──
rm -rf /tmp/crt-dual /tmp/crt-dual-mode /tmp/crt-dual-profile-options
echo "  session files cleared"

# ── 10. Persist overlay removal (warn-only: a reboot heals to stock) ──
if [ -n "${RGS15_SKIP_SAVE:-}" ]; then
	echo "  overlay save skipped (seam test)"
elif command -v batocera-save-overlay >/dev/null 2>&1; then
	batocera-save-overlay >/dev/null 2>&1 \
		&& echo "  overlay saved" \
		|| echo "  WARN: overlay save failed (reboot restores stock anyway)" >&2
fi

echo ""
echo "Uninstalled. Next:  ./verify.sh   (exit 0 = stock restored)"
