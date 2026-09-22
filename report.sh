#!/bin/bash
# report.sh — one-command diagnostic bundle (user-facing, exported).
# Run from the extracted project folder after a problem is observed:
#     ./report.sh
# It writes rgs-crt-report-YYYYmmdd-HHMM.zip next to itself and prints
# the path; send that file to the developers. Everything is COPIED —
# the script moves/resets/deletes nothing on the box (only its own
# previous staging dir and the new zip). Safe to run any time; close a
# stuck game first with: batocera-es-swissknife --emukill
#
# Collects (state files documented here — who writes them is the
# component named):
#   diag-dump.txt      engine src/engine/tools/diag-dump.sh (versions,
#                      GPU, XORG errors, XRANDR all-outputs, EDID,
#                      SYSFS connectors, mode file, classification)
#   adapters.txt       engine src/engine/tools/edid-info.sh (per-connector
#                      EDID forensics: identity, descriptor structure,
#                      sizes, first DTD, and on DP the DPCD branch block
#                      + OUI from the DRM aux chardev — tells a real
#                      display's EDID from an adapter's fabrication)
#   verify.txt         ./verify.sh full output + exit code (the gate)
#   logs/              our runtime logs (/userdata/system/logs/:
#                      rgs-15khz.log <- zz service, selector-core.log <-
#                      selector, selector.log, sr-owner.log (legacy
#                      residue), service.log = engine writers;
#                      display-reconcile.log <- the reconciler's event
#                      narrative, gamepad-reprobe.log; display-detect.log
#                      = engine writers) + stock (display.log,
#                      es_launch_stdout/stderr.log,
#                      es_script_stdout/stderr.log, udev.log <- the stock
#                      controller-connection rule, boot.log tmpfs)
#   package/           state of the live install: rgs-version,
#                      install-source, overlay-manifest, backups
#                      inventory + box-keys originals (the values the
#                      layer must hand back), held profiles, $PKG/logs
#   engine-tmp/        /tmp/crt-dual* markers (engine-owned, read here
#                      for consultation only — never written)
#   boot/              /boot CRT pieces (Intel i915 480i patch): the hook
#                      copy (written by install.sh + zz_rgs_15khz) + a
#                      listing with sha256 + vermagic of i915-patched.ko
#                      (the binary itself is NOT zipped — MBs) + the
#                      tmpfs swap log (written by the /boot hook)
#   xorg/              complete X server log (stock, current boot)
#   dmesg-display.txt  kernel display lines (drm/gpu drivers), bounded
#   metadata.txt       host, dates, free space, our version marker
#
# Env seams (tests): RGS15_REPORT_DIR staging/zip parent (default =
# this folder), RGS15_LOGS_DIR, RGS15_PKG, RGS15_TMPMARK. Defaults are
# the live paths. ASCII only (product surface).
set -u

REPO="$(cd "$(dirname "$0")" && pwd)"
OUTDIR="${RGS15_REPORT_DIR:-$REPO}"
LOGS_DIR="${RGS15_LOGS_DIR:-/userdata/system/logs}"
PKG="${RGS15_PKG:-/userdata/system/crt-dual}"
STAGE="$OUTDIR/report-staging"
STAMP="$(date +%Y%m%d-%H%M%S)"
ZIP="$OUTDIR/rgs-crt-report-$STAMP.zip"

[ "$(id -u)" = "0" ] || echo "NOTE: not root — package/tmp state may be partial (run as root over SSH)"

rm -rf "$STAGE"
mkdir -p "$STAGE/logs" "$STAGE/package" "$STAGE/engine-tmp"

echo "collecting (this takes a few seconds)..."

# 1. The engine diagnostic snapshot (self-sufficient; read from the
#    extracted repo so it works even if the deploy folder moved).
bash "$REPO/src/engine/tools/diag-dump.sh" >"$STAGE/diag-dump.txt" 2>&1 \
	|| echo "diag-dump exited $? (kept its output anyway)" >>"$STAGE/diag-dump.txt"

# 1b. Adapter/EDID forensics (2026-09-20, adapter incident): which adapter
#     sits between the box and the tube, and whether an EDID is a real
#     display's or a fabrication. Facts only; the class line comes from
#     display-detect.sh (single source of truth).
bash "$REPO/src/engine/tools/edid-info.sh" >"$STAGE/adapters.txt" 2>&1 \
	|| echo "edid-info exited $? (kept its output anyway)" >>"$STAGE/adapters.txt"

# 2. The gate verdict.
bash "$REPO/verify.sh" >"$STAGE/verify.txt" 2>&1
echo "verify.sh exit code: $?" >>"$STAGE/verify.txt"

# 3. Runtime logs — ours and the stock display/launch ones (full copies;
#    missing ones are benign: some never exist before first use).
for _f in rgs-15khz.log selector-core.log selector.log sr-owner.log \
	display-reconcile.log gamepad-reprobe.log \
	display-detect.log service.log display.log udev.log es_launch_stdout.log \
	es_launch_stderr.log es_script_stdout.log es_script_stderr.log \
	rgs_download.log; do
	[ -f "$LOGS_DIR/$_f" ] && cp -a "$LOGS_DIR/$_f" "$STAGE/logs/$_f" || true
done
[ -f /var/run/boot.log ] && cp -a /var/run/boot.log "$STAGE/logs/boot.log" || true

# 4. Live-install state (root-owned; skip silently if unreadable).
for _f in rgs-version install-source overlay-manifest; do
	[ -f "$PKG/$_f" ] && cp -a "$PKG/$_f" "$STAGE/package/$_f" || true
done
[ -d "$PKG/backups" ] && find "$PKG/backups" -type f \
	>"$STAGE/package/backups-inventory.txt" 2>/dev/null || true
[ -d "$PKG/backups/box-keys" ] && cp -a "$PKG/backups/box-keys" \
	"$STAGE/package/box-keys" 2>/dev/null || true
find "$PKG/profiles" -maxdepth 2 -name spec.conf -o -maxdepth 2 -name 'spec.conf.hold' \
	>"$STAGE/package/profiles-inventory.txt" 2>/dev/null || true
[ -d "$PKG/logs" ] && cp -a "$PKG/logs" "$STAGE/package/pkg-logs" 2>/dev/null || true

# 5. Engine markers (/tmp/crt-dual*, engine-owned; read-only consult).
for _m in /tmp/crt-dual /tmp/crt-dual-mode /tmp/crt-dual*; do
	[ -e "$_m" ] || continue
	if [ -f "$_m" ]; then
		cp -a "$_m" "$STAGE/engine-tmp/$(basename "$_m")" 2>/dev/null || true
	else
		find "$_m" -maxdepth 1 -type f -exec cp -a {} "$STAGE/engine-tmp/" \; 2>/dev/null || true
	fi
done

# 5b. /boot CRT pieces (Intel i915 480i patch) + the swap-hook log. The
#     2026-09-12 tester bundle left these out, which blocked the
#     confirmation that the module was ever deployed (writers: install.sh
#     + zz_rgs_15khz i915-patch for both /boot files; the boot hook writes
#     the tmpfs swap log). The module binary is NOT zipped (MBs): listing
#     + sha256 + vermagic answer the deployment question.
mkdir -p "$STAGE/boot"
{
	echo "== /boot CRT pieces (rgs-15khz layer) =="
	for _f in /boot/boot-custom.sh /boot/i915-patched.ko; do
		if [ -e "$_f" ]; then
			ls -l "$_f" 2>&1
			sha256sum "$_f" 2>/dev/null || true
		else
			echo "$_f: ABSENT"
		fi
	done
	if [ -f /boot/i915-patched.ko ]; then
		echo "module vermagic: $(modinfo -F vermagic /boot/i915-patched.ko 2>/dev/null || echo unreadable)"
	fi
	echo "running kernel:  $(uname -r)"
} >"$STAGE/boot/listing.txt"
[ -f /boot/boot-custom.sh ] && cp -a /boot/boot-custom.sh "$STAGE/boot/boot-custom.sh" 2>/dev/null || true
[ -f /tmp/i915-boot-swap.log ] && cp -a /tmp/i915-boot-swap.log "$STAGE/boot/i915-boot-swap.log" 2>/dev/null || true

# 5c. Complete X server log (stock; diag-dump keeps only its error tail).
#     Absent/unreadable is benign (same contract as the log copies above).
mkdir -p "$STAGE/xorg"
[ -f /var/log/Xorg.0.log ] && cp -a /var/log/Xorg.0.log "$STAGE/xorg/Xorg.0.log" 2>/dev/null || true

# 6. Kernel display truth, bounded.
dmesg 2>/dev/null | grep -iE "drm|amdgpu|radeon|nvidia|i915" | tail -400 \
	>"$STAGE/dmesg-display.txt" || echo "(dmesg unavailable to this user)" >"$STAGE/dmesg-display.txt"

# 7. Host metadata.
{
	echo "date:            $(date '+%F %T')"
	echo "kernel:          $(uname -a)"
	echo "rgs.version:     $(cat /userdata/system/rgs.version 2>/dev/null || echo absent)"
	echo "batocera.version:$(cat /usr/share/batocera/batocera.version 2>/dev/null || echo absent)"
	echo "layer version:   $(cat /userdata/system/crt-dual.version 2>/dev/null || echo unknown)"
	echo "userdata free:"
	df -h /userdata 2>/dev/null || true
	echo "root mount (overlay layout):"
	mount | grep -E " / |overlay|squashfs" || true
} >"$STAGE/metadata.txt"

# 8. Pack (python3 is guaranteed present on RGS; zip CLI is not).
python3 - "$STAGE" "$ZIP" <<'PY'
import os, pathlib, sys, zipfile
stage, out = pathlib.Path(sys.argv[1]), sys.argv[2]
with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
    for p in sorted(stage.rglob("*")):
        if p.is_file():
            z.write(p, p.relative_to(stage))
PY
rc=$?
rm -rf "$STAGE"
if [ "$rc" = "0" ] && [ -s "$ZIP" ]; then
	echo ""
	echo "DONE — send this single file to the developers:"
	echo "  $ZIP  ($(wc -c <"$ZIP") bytes)"
else
	echo "ERROR: packaging failed (rc=$rc) — keep $OUTDIR/report-staging and report this" >&2
	[ -d "$STAGE" ] && exit 1
fi
