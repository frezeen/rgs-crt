#!/bin/bash
# /boot hook — patched i915 swap for Intel 480i (deployed by install.sh).
#
# Stock Batocera runs this file from S00bootcustom ("bash /boot/boot-custom.sh
# start") BEFORE udev loads kernel modules. /lib/modules lives on the RAM
# overlay and reverts at every boot, so the swap must be repeated each boot
# (i915 itself cannot be unloaded live). Mechanism per the community patch
# set amxcs/batocera-crt-15khz-intel — see THIRD-PARTY.md for the credit.
#
# WHY the patch: gen9 Intel (DISPLAY_VER 9 — Skylake HD 530 .. Coffee Lake
# UHD 630) rejects Y-tiled scanout while a pipe runs in IF-ID interlace mode,
# and Mesa/glamor allocates Y-tiled buffers, so every 480i modeset dies with
# -EINVAL before the mode is ever set. The patched driver advertises only
# LINEAR/X_TILED on gen9, userspace allocates X-tiled, interlace scans out.
# Without the patch this layer still gets progressive 15kHz (240p) on Intel;
# interlaced 480i does not exist.
#
# Update safety: the module is swapped ONLY when its vermagic matches the
# RUNNING kernel. A kernel update therefore leaves stock i915 loading —
# the display survives, and verify.sh flags the stale module instead of a
# black tube. (amxcs's own hook swaps unconditionally and documents the
# resulting "upgrade = no display" caveat; this check is the update-safe
# variant.) Recovery if a patched module misbehaves: delete
# /boot/i915-patched.ko (and, for a full revert, /boot/boot-custom.sh),
# then reboot — the stock module loads again.
#
# State files (shell-quality.md §7): /tmp/i915-boot-swap.log — swap log;
# writer = THIS hook at boot, reader = humans + verify.sh, cleaning =
# tmpfs (recreated each boot). /boot/i915-patched.ko — writer =
# install.sh / the zz_rgs_15khz i915-patch duty, reader = this hook;
# removed by uninstall.sh.

[ "$1" = "start" ] || exit 0

KVER="$(uname -r)"
SRC=/boot/i915-patched.ko
DST="/lib/modules/$KVER/kernel/drivers/gpu/drm/i915/i915.ko"
LOG=/tmp/i915-boot-swap.log

if [ ! -f "$SRC" ]; then
	echo "$(date +%FT%T): i915 patch absent — stock module kept" >>"$LOG"
	exit 0
fi
if [ ! -f "$DST" ]; then
	echo "$(date +%FT%T): target i915 module absent for kernel $KVER — stock layout kept" >>"$LOG"
	exit 0
fi
_vm="$(modinfo -F vermagic "$SRC" 2>/dev/null)"
case "$_vm" in
"$KVER"*)
	if cp "$SRC" "$DST"; then
		echo "$(date +%FT%T): patched i915 swapped in (vermagic $_vm)" >>"$LOG"
	else
		echo "$(date +%FT%T): FAILED to copy patched i915 — stock kept" >>"$LOG"
	fi
	;;
"")
	echo "$(date +%FT%T): vermagic unreadable on $SRC — not a module for this kernel, stock kept" >>"$LOG"
	;;
*)
	echo "$(date +%FT%T): vermagic mismatch (module '$_vm' vs kernel '$KVER') — stock kept" >>"$LOG"
	;;
esac
