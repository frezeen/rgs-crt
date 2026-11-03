#!/bin/bash
# report.sh — one-command diagnostic bundle (user-facing, exported).
# Run from the extracted project folder after a problem is observed:
#     ./report.sh
#     ./report.sh --version     (print the project version; collect nothing)
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
#                      selector, selector.log, service.log = engine writers;
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
#   status.txt         the bundle self-check: STATUS: OK|BROKEN + one
#                      reason per line (U1b). A missing decisive field
#                      (no Transform: line while X is up, empty
#                      detect-state while the reconciler ran, empty
#                      reconcile log while the daemon runs) makes the
#                      collector exit non-zero AFTER writing the zip.
#   99-crt.conf        convenience copy of /etc/X11/xorg.conf.d/99-crt.conf
#   switchres.ini      convenience copy of /etc/switchres.ini (both are
#                      already inside diag-dump.txt; own files are for diff)
#
# Env seams (tests): RGS15_REPORT_DIR staging/zip parent (default =
# this folder), RGS15_LOGS_DIR, RGS15_PKG, RGS15_TMPMARK (the engine
# state dir for the self-check), RGS15_DIAG_DUMP (diag-dump.sh under
# test), RGS15_X11_CONF, RGS15_SYS_SWITCHRES, RGS15_PGREP. Defaults are
# the live paths. ASCII only (product surface).
set -u

REPO="$(cd "$(dirname "$0")" && pwd)"

# --version: print the project version — the root VERSION file is the
# single source of truth and ships beside this script — and exit WITHOUT
# collecting anything. Any other argument is a typo: refuse loud instead
# of silently building a bundle the caller did not ask for.
case "${1:-}" in
--version)
	if [ -s "$REPO/VERSION" ]; then
		echo "report.sh $(cat "$REPO/VERSION")"
	else
		echo "ERROR: VERSION missing or empty beside report.sh ($REPO/VERSION)" >&2
		exit 1
	fi
	exit 0
	;;
"") ;;
*) echo "usage: report.sh [--version]" >&2; exit 2 ;;
esac

OUTDIR="${RGS15_REPORT_DIR:-$REPO}"
LOGS_DIR="${RGS15_LOGS_DIR:-/userdata/system/logs}"
PKG="${RGS15_PKG:-/userdata/system/crt-dual}"
DIAG_DUMP="${RGS15_DIAG_DUMP:-$REPO/src/engine/tools/diag-dump.sh}"
MARK_DIR="${RGS15_TMPMARK:-/tmp/crt-dual}"
X11_CONF="${RGS15_X11_CONF:-/etc/X11/xorg.conf.d/99-crt.conf}"
SYS_SWITCHRES="${RGS15_SYS_SWITCHRES:-/etc/switchres.ini}"
PGREP="${RGS15_PGREP:-pgrep}"
STAGE="$OUTDIR/report-staging"
STAMP="$(date +%Y%m%d-%H%M%S)"
ZIP="$OUTDIR/rgs-crt-report-$STAMP.zip"

[ "$(id -u)" = "0" ] || echo "NOTE: not root — package/tmp state may be partial (run as root over SSH)"

rm -rf "$STAGE"
mkdir -p "$STAGE/logs" "$STAGE/package" "$STAGE/engine-tmp"

echo "collecting (this takes a few seconds)..."

# The three collectors below are READ-ONLY and write to DIFFERENT files, so
# they run CONCURRENTLY (2026-10-16): a bundle build was 4.4s of pure sequence
# (diag-dump 1.4 + edid-info 0.4 + verify.sh 2.2), and this is the script the
# OWNER runs while a bug is still fresh — and the seam that certifies it.
# Same members, same content, same exit notes; the staging copies in steps
# 3-5b run while they work, and `wait` below joins them before anything READS
# their output (step 7c reads diag-dump.txt).
# 1. The engine diagnostic snapshot (self-sufficient; read from the
#    extracted repo so it works even if the deploy folder moved).
( bash "$DIAG_DUMP" >"$STAGE/diag-dump.txt" 2>&1 \
	|| echo "diag-dump exited $? (kept its output anyway)" >>"$STAGE/diag-dump.txt" ) &

# 1b. Adapter/EDID forensics (2026-09-20, adapter incident): which adapter
#     sits between the box and the tube, and whether an EDID is a real
#     display's or a fabrication. Facts only; the class line comes from
#     display-detect.sh (single source of truth).
( bash "$REPO/src/engine/tools/edid-info.sh" >"$STAGE/adapters.txt" 2>&1 \
	|| echo "edid-info exited $? (kept its output anyway)" >>"$STAGE/adapters.txt" ) &

# 2. The gate verdict.
( bash "$REPO/verify.sh" >"$STAGE/verify.txt" 2>&1
  echo "verify.sh exit code: $?" >>"$STAGE/verify.txt" ) &

# 3. Runtime logs — ours and the stock display/launch ones (full copies;
#    missing ones are benign: some never exist before first use).
for _f in rgs-15khz.log selector-core.log selector.log \
	display-reconcile.log gamepad-reprobe.log \
	display-detect.log service.log display.log udev.log es_launch_stdout.log \
	es_launch_stderr.log es_script_stdout.log es_script_stderr.log \
	rgs_download.log vnc.log; do
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

# The three collectors launched at step 1-2 are joined HERE — before any step
# that READS their output (7c reads diag-dump.txt) — so the overlap above is
# the copies (3-5b), never a race on a half-written file.
wait

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

# 7b. Convenience copies of the two living display configs (read-only). Both
#     already live inside diag-dump.txt; their OWN files make a direct diff
#     possible without cutting a section out by hand.
[ -f "$X11_CONF" ] && cp -a "$X11_CONF" "$STAGE/99-crt.conf" 2>/dev/null || true
[ -f "$SYS_SWITCHRES" ] && cp -a "$SYS_SWITCHRES" "$STAGE/switchres.ini" 2>/dev/null || true

# 7c. Self-check (U1b): a bundle must not look OK when a decisive field is
#     missing. Reasons are ACCUMULATED (never stop at the first), written
#     into status.txt (zip root) and reported on stderr AFTER the bundle is
#     packed, with a non-zero exit: the zip is still produced (it is the
#     evidence), but the collector refuses to exit green. Reason set:
#       - X answered an xrandr query (XRANDR FULL section present, no
#         "not available") but diag-dump has no Transform: line;
#       - detect-state exists with no CRT/LCD role while the reconcile log
#         shows the reconciler ran (RECONCILE lines);
#       - the reconcile log is empty while the daemon is running.
_report_reasons=()
_report_broken=0
_report_section() { # $1 = start header, $2 = next header
	awk -v s="$1" -v e="$2" 'index($0,s){f=1;next} f&&index($0,e){exit} f{print}' \
		"$STAGE/diag-dump.txt" 2>/dev/null
}
_dump="$STAGE/diag-dump.txt"
_x_full="$(_report_section 'XRANDR (FULL' 'XRANDR VERBOSE')"
if [ -n "$_x_full" ] && ! printf '%s' "$_x_full" | grep -q 'not available'; then
	grep -q 'Transform:' "$_dump" \
		|| _report_reasons+=("X is up but diag-dump has no Transform: line (xrandr --verbose missing — the scaling truth)")
fi
if [ -e "$MARK_DIR/detect-state" ] \
	&& ! grep -qE '^(CRT_OUTS|CRT_OUT)=[^[:space:]]' "$MARK_DIR/detect-state" 2>/dev/null \
	&& grep -q 'RECONCILE' "$LOGS_DIR/display-reconcile.log" 2>/dev/null; then
	_report_reasons+=("detect-state holds no role while the reconciler ran ($MARK_DIR/detect-state)")
fi
if ! [ -s "$LOGS_DIR/display-reconcile.log" ]; then
	_v_daemons="$("$PGREP" -f 'display-reconcil[e].sh --daemon' 2>/dev/null | wc -l)"
	[ "${_v_daemons:-0}" -ge 1 ] \
		&& _report_reasons+=("display-reconcile.log is empty while the daemon is running ($_v_daemons process)")
fi
if [ "${#_report_reasons[@]}" -gt 0 ]; then
	{ echo "STATUS: BROKEN"; printf '%s\n' "${_report_reasons[@]}"; } >"$STAGE/status.txt"
	_report_broken=1
else
	echo "STATUS: OK" >"$STAGE/status.txt"
fi

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
	if [ "$_report_broken" = "1" ]; then
		echo "" >&2
		echo "STATUS: BROKEN — the bundle is missing decisive fields (send it anyway):" >&2
		for _r in "${_report_reasons[@]}"; do echo "  - $_r" >&2; done
		exit 1
	fi
else
	echo "ERROR: packaging failed (rc=$rc) — keep $OUTDIR/report-staging and report this" >&2
	[ -d "$STAGE" ] && exit 1
fi
