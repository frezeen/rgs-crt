#!/bin/bash
# RGS+15kHz verify.sh (step 7: update-resilience gate).
#
# Exactly TWO states are clean (anything mixed = FAIL with a listing):
#   INSTALLED — every deployed piece present and byte-identical to the
#     repo, specs valid, monkey-patch patterns matched, box keys never
#     written (backup-only), RGS version unchanged since install, zero
#     residue;
#   STOCK — nothing of ours left (pre-install or post-uninstall).
# An RGS update restores stock files (install-discipline.md §8): a
# version mismatch FAILS closed — recovery is uninstall.sh + install.sh
# (reapply-all), never silent drift.
# Always checked (both states): no marked blocks / stranded marker keys
# in living configs.
# Static only (no X needed): the sitecustomize probe imports the hook and
# reads _PATCHER_RESULTS (read-only: a mismatch FAILS loud, never silent).
# PYTHONPATH carries the SITE under test so seam installs probe the seam
# copy against the live configgen (RGS-generator compatibility signal).
# Exit 0 = CLEAN. Run after install, after uninstall, before any claim.

set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PKG="${RGS15_PKG:-/userdata/system/crt-dual}"
PKG_VERSION_FILE="${PKG}.version"
# Single source of truth: the root VERSION file (read here, judged below
# once bad() exists — verify reports every defect, never exits mid-preamble).
if [ -f "$REPO/VERSION" ] && [ -n "$(cat "$REPO/VERSION" 2>/dev/null)" ]; then
	PKG_VERSION="$(cat "$REPO/VERSION")"
else
	PKG_VERSION=""
fi
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
MERGE="$REPO/src/engine/selector/merge.py"
MARK="# --- CRT-DUAL PROFILE:"
RGS_VERSION_SRC="${RGS15_RGS_VERSION_FILE:-/userdata/system/rgs.version}"
BATOCERA_VERSION_SRC="${RGS15_BATOCERA_VERSION_FILE:-/usr/share/batocera/batocera.version}"
MODPROBE_DST="${RGS15_MODPROBE_CONF:-/etc/modprobe.d/rgs-15khz-amdgpu-legacy.conf}"
# The RGS read contract rows are checked against the fix/ tree (fix/ IS the
# future configgen state — measured update model, zz_rgs_15khz header).
RGS_FIX_SRC="${RGS15_FIX_DIR:-/userdata/system/rgs/fix}"

# User-facing anchor for the reporting procedure: README step "collector"
# uses exactly this printed value as the path prefix (printing the real
# path is allowed in scripts; hardcoding it in docs is not).
echo "Package location: $PKG"

FAIL=0
PRESENT=0
bad() {
	echo "FAIL: $*" >&2
	FAIL=1
}
ok() {
	echo "  OK: $*"
}
have() {
	PRESENT=$((PRESENT + 1))
}

# Single-source version gate (judged here: bad() exists from this point).
[ -n "$PKG_VERSION" ] \
	|| bad "repo VERSION missing or empty ($REPO/VERSION — the single source of truth)"

is_registered() {
	batocera-settings-get system.services 2>/dev/null | tr ' ' '\n' | grep -qx "$1"
}

# ── 0. Spec validation (repo specs AND the package copies — the package
#      is what the selector actually runs; user-added profiles included,
#      merge.py WARNs surfaced with their real paths) ──
for _spec in "$REPO"/src/profiles/*/spec.conf; do
	[ -f "$_spec" ] || continue
	_name="$(basename "$(dirname "$_spec")")"
	if python3 "$MERGE" validate "$(dirname "$_spec")" "$_name" /userdata/system >/dev/null 2>&1; then
		ok "repo spec valid: $_name"
	else
		bad "repo spec invalid: $_name (fix the spec — never reaches gameStart)"
	fi
done
if [ -d "$PKG/profiles" ]; then
	for _spec in "$PKG"/profiles/*/spec.conf; do
		[ -f "$_spec" ] || continue
		_name="$(basename "$(dirname "$_spec")")"
		_out="$(python3 "$MERGE" validate "$(dirname "$_spec")" "$_name" /userdata/system 2>&1)"; _rc=$?
		if [ "$_rc" = "0" ]; then
			ok "package spec valid: $_name"
			printf '%s\n' "$_out" | grep "WARN" || true
		else
			bad "package spec invalid: $_name (fix it — a game launch would hit it)"
			printf '%s\n' "$_out" | tail -3 >&2
		fi
	done
fi

# ── 1. Package (dir + byte-identity + marker) ──
if [ -d "$PKG/src" ]; then
	have
	# per-code-dir byte-identity BOTH ways (repo code dirs vs package dirs;
	# src/engine's dev entries docs/tests are deliberately not deployed)
	_engine_drift=""
	for _d in "$REPO"/src/engine/*/; do
		_b="$(basename "$_d")"
		case "$_b" in docs|tests) continue ;; esac
		diff -r --exclude=overlay-manifest --exclude=backups --exclude=__pycache__ --exclude=libcrypt.so.1 \
			"$REPO/src/engine/$_b" "$PKG/src/$_b" >/dev/null 2>&1 \
			|| _engine_drift="$_engine_drift $_b"
	done
	for _d in "$PKG"/src/*/; do
		_b="$(basename "$_d")"
		[ -d "$REPO/src/engine/$_b" ] || _engine_drift="$_engine_drift extra:$_b"
	done
	# NOTE: libcrypt.so.1 excluded — engine VNC runtime compat symlink,
	# created inside the package by vnc-env.sh at first VNC start
	# (documented engine behavior, not drift).
	[ -n "$_engine_drift" ] \
		&& bad "package src DRIFT ($_engine_drift)" \
		|| ok "package src byte-identical"
	# engine layout tripwire: the tree is deployed flat (src/engine/*) and
	# carries no demo profiles — a slip must fail HERE.
	[ -e "$REPO/src/engine/src" ] && bad "repo: nested src/engine/src present (engine tree must stay flat)"
	[ -e "$REPO/src/engine/profiles" ] && bad "repo: engine demo profiles present (not part of the product)"
	# Repo profiles must be byte-identical in the package; user-added
	# profile folders are legitimate (documented on-box authoring) — they
	# are validated in section 0, never drift.
	_pkg_drift=""
	for _d in "$REPO"/src/profiles/*/; do
		_b="$(basename "$_d")"
		if [ ! -d "$PKG/profiles/$_b" ] || ! diff -r "$_d" "$PKG/profiles/$_b" >/dev/null 2>&1; then
			_pkg_drift="$_pkg_drift $_b"
		fi
	done
	[ -n "$_pkg_drift" ] \
		&& bad "package profiles DRIFT (repo copy differs:$_pkg_drift)" \
		|| ok "repo profiles byte-identical in the package"
	for _d in "$PKG"/profiles/*/; do
		_b="$(basename "$_d")"
		[ -d "$REPO/src/profiles/$_b" ] || ok "user profile present: $_b (validated above)"
	done
	[ -f "$PKG_VERSION_FILE" ] && [ "$(cat "$PKG_VERSION_FILE" 2>/dev/null)" = "$PKG_VERSION" ] \
		&& ok "version marker" \
		|| bad "version marker missing/wrong ($PKG_VERSION_FILE)"
	[ -f "$PKG/overlay-manifest" ] \
		&& ok "overlay manifest present" \
		|| bad "overlay manifest missing ($PKG/overlay-manifest)"
	# Step 7: RGS-version drift gate (install-discipline.md §8). An RGS
	# update restores stock files while /userdata parts survive — a
	# mismatch means this install predates the box. Recovery is
	# uninstall.sh + install.sh (reapply-all), never silent drift.
	if [ -f "$PKG/rgs-version" ]; then
		_rec_rgs="$(sed -n 's/^rgs\.version=//p' "$PKG/rgs-version")"
		_rec_bat="$(sed -n 's/^batocera\.version=//p' "$PKG/rgs-version")"
		_live_rgs="$(cat "$RGS_VERSION_SRC" 2>/dev/null || true)"
		_live_bat="$(cat "$BATOCERA_VERSION_SRC" 2>/dev/null || true)"
		if [ -n "$_rec_rgs" ] && [ "$_rec_rgs" = "$_live_rgs" ] \
			&& [ -n "$_rec_bat" ] && [ "$_rec_bat" = "$_live_bat" ]; then
			ok "RGS version unchanged (rgs.version=$_live_rgs)"
		else
			bad "RGS updated under us (recorded rgs.version=${_rec_rgs:-?} / batocera.version=${_rec_bat:-?}, live ${_live_rgs:-?} / ${_live_bat:-?}) — uninstall.sh + install.sh to reapply"
		fi
	else
		bad "RGS version record missing ($PKG/rgs-version — pre-step7 install? uninstall.sh + install.sh to reapply)"
	fi
	# RGS READ CONTRACT (src/service/guard-readers.tsv — the rows the boot
	# guard re-checks on a version bump): every stock read our profile
	# depends on must still be present in the LIVE fix/ tree. A dropped read
	# is NOT a drift to adopt, it means the layer is already incompatible
	# (our profile block is inert on this RGS) -> bad, not ok. Re-derived
	# here from the live tree (a verifier never shares the service's copy).
	# Env seam: RGS15_FIX_DIR. Absent tree = nothing to check on this box
	# (the gate above already judges the RGS record).
	_rc_contract="$REPO/src/service/guard-readers.tsv"
	if [ ! -f "$_rc_contract" ]; then
		bad "read contract missing ($_rc_contract — repo defect: the guard would read nothing)"
	elif [ ! -d "$RGS_FIX_SRC" ]; then
		ok "read contract skipped (no live fix/ tree at $RGS_FIX_SRC — nothing to check)"
	else
		while IFS=$'\t' read -r _rkey _rnote _rexpr || [ -n "${_rkey:-}" ]; do
			case "${_rkey:-}" in '' | \#*) continue ;; esac
			if [ -z "${_rexpr:-}" ]; then
				bad "read contract row for '$_rkey' carries no read expression ($_rc_contract)"
				continue
			fi
			# -F literal, -l drains to EOF (never -q: SIGPIPE under
			# pipefail, shell-quality).
			if grep -rFl -- "$_rexpr" "$RGS_FIX_SRC" >/dev/null 2>&1; then
				ok "RGS still reads $_rkey ($_rnote)"
			else
				bad "RGS no longer reads $_rkey ($_rnote) — our profile block is inert on this RGS"
			fi
		done <"$_rc_contract"
	fi
else
	ok "package absent (stock state)"
fi

# ── 2. Hook ──
if [ -e "$HOOK_DST" ]; then
	have
	cmp -s "$HOOK_DST" "$HOOK_SRC" \
		&& ok "hook byte-identical" \
		|| bad "hook DRIFT/foreign ($HOOK_DST differs from engine hook)"
else
	ok "hook absent (stock state)"
fi

# ── 3. RAM hoist: file + pattern match against live configgen ──
if [ -n "$SITE" ] && [ -f "$SITE/sitecustomize.py" ]; then
	have
	cmp -s "$SITE/sitecustomize.py" "$SITECUSTOMIZE_SRC" \
		&& ok "sitecustomize.py byte-identical" \
		|| bad "sitecustomize.py DRIFT (re-run install.sh)"
	if PYTHONPATH="$SITE" python3 -c \
		"import sitecustomize, sys; r = sitecustomize._PATCHER_RESULTS; " \
		"bad = [m for m in sitecustomize._PATCHERS if r.get(m) is not True]; " \
		"sys.exit(1 if bad else 0)" 2>/dev/null; then
		ok "monkey-patch patterns matched live configgen"
	else
		bad "monkey-patch patterns did NOT match (RGS generators changed? fix upstream, never silent)"
	fi
else
	ok "sitecustomize.py absent (stock state)"
fi

# ── 4. Overlay files: S15 + udev (byte-identity) ──
for _pair in "$S15_SRC:$S15_DST" "$UDEV_SRC:$UDEV_DST"; do
	_src="${_pair%%:*}"
	_dst="${_pair##*:}"
	_name="$(basename "$_dst")"
	if [ -e "$_dst" ]; then
		have
		cmp -s "$_dst" "$_src" \
			&& ok "$_name byte-identical" \
			|| bad "$_name DRIFT ($_dst differs from repo)"
	else
		ok "$_name absent (stock state)"
	fi
done

# ── 4b. amdgpu legacy pin (dc=0 modprobe file): re-derived, never shared
#      with the service logic (a verifier re-derives from facts). Expected
#      INSTALLED: the pin exactly when the box is below kernel 6.19 AND a
#      sysfs AMD display device inside the DC-default DCE id ranges
#      (Tonga/Fiji/Polaris10-12/Vega10/12/20/VEGAM — the shipped kernel's
#      amdgpu table, collision-checked; the same derivation the boot duty
#      runs, RGS15_PCI_SYS seam) AND the rgs-15khz.amdgpu-legacy knob is
#      not off; content = the dc=0 line. Expected STOCK (no package): absent.
#      Env seams: RGS15_MODPROBE_CONF/RGS15_UNAME_R/RGS15_PCI_SYS.
if [ "$PRESENT" -gt 0 ]; then
	_v_kernel="${RGS15_UNAME_R:-$(uname -r 2>/dev/null || true)}"
	if [ -n "${RGS15_PCI_SYS:-}" ]; then _v_pci="$RGS15_PCI_SYS"; else _v_pci="/sys/bus/pci/devices"; fi
	_v_id=""
	for _d in "$_v_pci"/*; do
		[ -r "$_d/vendor" ] || continue
		[ "$(cat "$_d/vendor" 2>/dev/null)" = "0x1002" ] || continue
		case "$(cat "$_d/class" 2>/dev/null)" in
		0x0300* | 0x0380*) ;;
		*) continue ;;
		esac
		_v_id="$(cat "$_d/device" 2>/dev/null | tr 'a-f' 'A-F')"
		_v_id="${_v_id#0X}"; _v_id="${_v_id#0x}"
		if printf '%s\n' "$_v_id" | awk -v R="66A0-66AF 67C0-67FF 6860-687F 6920-6939 694C-694F 6980-699F 69A0-69AF 7300-730F" '
			BEGIN { n = split(R, r, " "); ok = 0 }
			{ for (i = 1; i <= n; i++) { split(r[i], p, "-")
				if ($0 >= p[1] && $0 <= p[2]) ok = 1 }
			  if ($0 == "6FDF") ok = 1; exit !ok }'; then
			break
		else
			_v_id=""
		fi
	done
	_v_expect=0
	if [ "$_v_kernel" != "$(printf '%s\n' '6.19' "$_v_kernel" | sort -V | tail -1)" ] && [ -n "$_v_id" ]; then
		_v_expect=1
	fi
	# the knob is read from the same conf the service reads (the boot duty
	# re-derives it too); the conf path seam keeps seam tests hermetic
	_v_knob="$(grep -E '^rgs-15khz\.amdgpu-legacy[[:space:]]*=' "${RGS15_CONF:-/userdata/system/batocera.conf}" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '[:space:]')"
	[ "$_v_knob" = "off" ] && _v_expect=0
	if [ "$_v_expect" = "1" ]; then
		if [ -f "$MODPROBE_DST" ]; then
			# NOT counted in PRESENT (§10): the pin exists only on DC-class
			# AMD boxes — a conditional component would break the fixed
			# full-install count (mixed-state false FAIL). This branch owns
			# its presence verdict.
			grep -q "^options amdgpu dc=0$" "$MODPROBE_DST" \
				&& ok "amdgpu legacy pin present with dc=0 (kernel=${RGS15_UNAME_R:-$(uname -r)} id=${_v_id:-none})" \
				|| bad "amdgpu legacy pin present but WRONG content ($MODPROBE_DST)"
		else
			bad "amdgpu legacy pin MISSING for a DC-class AMD box below kernel 6.19 ($MODPROBE_DST — run install.sh; tube would stay black on dc=1)"
		fi
	elif [ -e "$MODPROBE_DST" ]; then
		bad "amdgpu legacy pin present but NOT applicable (kernel=${RGS15_UNAME_R:-$(uname -r)} id=${_v_id:-none} knob=${_v_knob:-auto}) — remove it (uninstall.sh or the service amdgpu-legacy one-shot)"
	else
		ok "amdgpu legacy pin absent (not applicable: kernel=${RGS15_UNAME_R:-$(uname -r)} id=${_v_id:-none})"
	fi
else
	# stock state: the pin must be gone too (uninstall removes it)
	if [ -e "$MODPROBE_DST" ]; then
		bad "amdgpu legacy pin LEFT OVER in stock state ($MODPROBE_DST)"
	else
		ok "amdgpu legacy pin absent (stock state)"
	fi
fi

# ── 4c. Intel i915 480i patch (/boot hook + module): re-derived from
#      facts, same discipline as 4b (NOT counted in PRESENT — the branch
#      owns its presence verdict; a conditional component would break the
#      fixed §10 count). Applicable when the boot dmesg shows i915
#      initialized (the Intel iGPU bound this boot). Expected INSTALLED:
#      hook present and byte-identical to the repo hook; module present
#      with vermagic == running kernel — module ABSENT is a WARN (offline
#      install: progressive 15kHz still works, 480i needs the module).
#      Expected STOCK (no package): both gone.
#      Env seams: RGS15_BOOT_HOOK/RGS15_BOOT_MOD/RGS15_I915_PRESENT/
#      RGS15_UNAME_R (+ RGS15_DMESG_SRC; 4b moved to the RGS15_PCI_SYS seam).
if [ "$PRESENT" -gt 0 ]; then
	_v_i915="${RGS15_I915_PRESENT:-}"
	if [ -z "$_v_i915" ]; then
		# Read the boot log ONCE and match with case — never `dmesg |
		# grep -q` under pipefail: grep -q exits at the first match, a
		# >64 KiB dmesg dies on SIGPIPE, the pipeline reports 141 and the
		# &&/|| idiom reads "no i915" while the boot line IS present
		# (tester Intel HD 530 bundle, 2026-09-12: verify said "non-Intel
		# GPU"). Same shape as 4b above; seam test_intel_i915_patch case 9.
		if [ -n "${RGS15_DMESG_SRC:-}" ]; then
			_v_dmesg="$(cat "$RGS15_DMESG_SRC" 2>/dev/null || true)"
		else
			_v_dmesg="$(dmesg 2>/dev/null || true)"
		fi
		case "$_v_dmesg" in
		*"Initialized i915"*) _v_i915=1 ;;
		*) _v_i915=0 ;;
		esac
	fi
	BOOT_HOOK="${RGS15_BOOT_HOOK:-/boot/boot-custom.sh}"
	BOOT_MOD="${RGS15_BOOT_MOD:-/boot/i915-patched.ko}"
	if [ "$_v_i915" = "1" ]; then
		if [ -e "$BOOT_HOOK" ]; then
			cmp -s "$BOOT_HOOK" "$REPO/src/service/i915/boot-custom.sh" \
				&& ok "i915 boot hook byte-identical" \
				|| bad "i915 boot hook DRIFT/foreign ($BOOT_HOOK differs from repo — install.sh; a foreign CRT tool hook would fight this layer)"
		else
			bad "i915 boot hook MISSING on an Intel-iGPU box ($BOOT_HOOK — reinstall; the module would never be swapped before udev)"
		fi
		if [ -f "$BOOT_MOD" ]; then
			_vm="$(modinfo -F vermagic "$BOOT_MOD" 2>/dev/null || true)"
			case "$_vm" in
			"${RGS15_UNAME_R:-$(uname -r)}"*)
				ok "i915 patch vermagic matches kernel ($_vm)"
				;;
			"")
				bad "i915 patch present but vermagic unreadable ($BOOT_MOD — not a module for this kernel; replace it)"
				;;
			*)
				bad "i915 patch vermagic STALE (module '$_vm' vs kernel '${RGS15_UNAME_R:-$(uname -r)}') — kernel updated under us; build/procure i915-patched-$(uname -r).ko and reinstall"
				;;
			esac
		else
			echo "WARN: i915 patch module absent ($BOOT_MOD — offline install? place i915-patched-$(uname -r).ko in src/service/i915/binaries/ and reinstall; 480i needs it)" >&2
		fi
	else
		if [ -e "$BOOT_HOOK" ] || [ -e "$BOOT_MOD" ]; then
			bad "i915 /boot piece present but NOT applicable (no i915 this boot: $BOOT_HOOK $BOOT_MOD) — remove it (uninstall.sh)"
		else
			ok "i915 patch absent (not applicable: non-Intel GPU)"
		fi
	fi
else
	if [ -e "${RGS15_BOOT_HOOK:-/boot/boot-custom.sh}" ] || [ -e "${RGS15_BOOT_MOD:-/boot/i915-patched.ko}" ]; then
		bad "i915 /boot piece LEFT OVER in stock state (${RGS15_BOOT_HOOK:-/boot/boot-custom.sh} ${RGS15_BOOT_MOD:-/boot/i915-patched.ko})"
	else
		ok "i915 patch absent (stock state)"
	fi
fi

# ── 4d. launcher raster hunks (/usr/bin/batocera-resolution): same
#      discipline as 4c (NOT counted in PRESENT — owns its verdict).
#      Expected INSTALLED: the hunks present AND the stock snapshot exists
#      (uninstall's restore source). Expected STOCK: hunks absent.
if [ "$PRESENT" -gt 0 ]; then
	RES_DST="${RGS15_RES_TARGET:-/usr/bin/batocera-resolution}"
	RES_BAK="${RGS15_RES_BAK:-$PKG/backups/stock-originals/batocera-resolution}"
	if grep -q "RGS-15KHZ-EXT (stock raster channel" "$RES_DST" 2>/dev/null; then
		if [ -f "$RES_BAK" ]; then
			ok "launcher raster hunks applied + stock snapshot present"
		else
			bad "launcher raster hunks applied but NO stock snapshot ($RES_BAK) — uninstall could not restore stock"
		fi
	else
		bad "launcher raster hunks MISSING ($RES_DST — run install.sh; the videomode-key channel would be refused by configgen)"
	fi
else
	if grep -q "RGS-15KHZ-EXT (stock raster channel" "${RGS15_RES_TARGET:-/usr/bin/batocera-resolution}" 2>/dev/null; then
		bad "launcher raster hunks LEFT OVER in stock state"
	else
		ok "launcher raster hunks absent (stock state)"
	fi
fi

# ── 4e. GPU dotclock floor (architecture 2026-09-20): same discipline as
#      4b-4d (NOT counted in PRESENT — owns its verdict). ONE truth
#      source — the BOOT measurement (the S30z hook, KMS-native: mode set
#      + WAIT_VBLANK) or the manual knob; the floor is written into BOTH
#      switchres inis FRESH every boot (the /etc write is volatile: it
#      lives in the RAM overlay, no overlay save — a reboot heals it to
#      stock). Expected INSTALLED: the S30z hook installed; /etc carries
#      a valid floor (the knob wins when set); the RA override matches
#      when the floor is non-zero. Expected STOCK: RA ini + S30z hook
#      absent, /etc back at 0.
#      Env seams: RGS15_RA_SWITCHRES / RGS15_SYS_SWITCHRES / RGS15_CONF /
#      RGS15_S30Z.
if [ "$PRESENT" -gt 0 ]; then
	RA_SWITCHRES="${RGS15_RA_SWITCHRES:-/userdata/system/configs/retroarch/switchres.ini}"
	_V_CONF="${RGS15_CONF:-/userdata/system/batocera.conf}"
	_V_SYS_INI="${RGS15_SYS_SWITCHRES:-/etc/switchres.ini}"
	_V_S30Z="${RGS15_S30Z:-/etc/init.d/S30z-crt-dual-measure}"
	_v_knob="$(grep -E '^rgs-15khz\.dotclock_min[[:space:]]*=' "$_V_CONF" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '[:space:]"\r')"
	if [ -n "$_v_knob" ] && [ "$_v_knob" != "off" ] && ! printf '%s' "$_v_knob" | grep -qE '^[0-9]+([.][0-9]+)?$'; then
		bad "rgs-15khz.dotclock_min invalid value '$_v_knob' (number or off) — fix by hand (the measurement path stays)"
	fi
	[ -x "$_V_S30Z" ] \
		&& ok "dotclock boot hook installed ($_V_S30Z)" \
		|| bad "dotclock boot hook missing ($_V_S30Z — reinstall)"
	_v_sys_dc=""
	[ -f "$_V_SYS_INI" ] && _v_sys_dc="$(grep -E '^[[:space:]]*dotclock_min[[:space:]]' "$_V_SYS_INI" 2>/dev/null | head -1 | awk '{print $NF}' | tr -d '\r')"
	_v_sys_n="$(printf '%s' "$_v_sys_dc" | awk '{ if ($0 ~ /^[0-9]+([.][0-9]+)?$/) { f = $0 + 0; if (f == 0) print "0"; else printf "%.1f", f } }')"
	if [ -z "$_v_sys_dc" ]; then
		bad "$_V_SYS_INI has no dotclock_min line (the boot hook never wrote it?)"
	elif [ -z "$_v_sys_n" ]; then
		bad "$_V_SYS_INI dotclock_min='$_v_sys_dc' is not a number"
	elif [ "$_v_knob" = "off" ] && [ "$_v_sys_n" != "0" ]; then
		bad "knob off but $_V_SYS_INI floor is $_v_sys_dc (expected 0)"
	else
		ok "system switchres.ini floor=$_v_sys_dc (written at boot, volatile; knob=${_v_knob:-unset})"
	fi
	if [ -n "$_v_sys_n" ] && [ "$_v_sys_n" != "0" ]; then
		_v_ra_dc=""
		[ -f "$RA_SWITCHRES" ] && _v_ra_dc="$(grep -E '^[[:space:]]*dotclock_min[[:space:]]' "$RA_SWITCHRES" 2>/dev/null | head -1 | awk '{print $NF}' | tr -d '\r')"
		[ "$_v_ra_dc" = "$_v_sys_dc" ] \
			&& ok "RA override floor matches ($_v_ra_dc)" \
			|| bad "RA override floor '${_v_ra_dc:-absent}' != /etc floor $_v_sys_dc (run: zz_rgs_15khz dotclock-write $_v_sys_dc)"
	else
		ok "dotclock floor 0 (no CRT / knob off / not measured — the stock default)"
	fi
else
	_v_stk="${RGS15_RA_SWITCHRES:-/userdata/system/configs/retroarch/switchres.ini}"
	_v_stk2="${RGS15_S30Z:-/etc/init.d/S30z-crt-dual-measure}"
	_v_stk3="${RGS15_SYS_SWITCHRES:-/etc/switchres.ini}"
	_v_stk3dc=""
	[ -f "$_v_stk3" ] && _v_stk3dc="$(grep -E '^[[:space:]]*dotclock_min[[:space:]]' "$_v_stk3" 2>/dev/null | head -1 | awk '{print $NF}' | tr -d '\r')"
	if [ -e "$_v_stk" ] || [ -e "$_v_stk2" ]; then
		bad "dotclock pieces LEFT OVER in stock state ($_v_stk / $_v_stk2)"
	elif [ -n "$_v_stk3dc" ] && [ "$_v_stk3dc" != "0" ]; then
		bad "$_v_stk3 floor $_v_stk3dc left in stock state (uninstall restore incomplete; a reboot heals)"
	else
		ok "dotclock pieces absent (stock state)"
	fi
fi

# ── 5. Services: engine shim + ours + VNC (file + registration) ──
if [ -e "$SVCDIR/$ENGINE_SVC" ]; then
	have
	grep -q "exec bash \"$PKG/src/service/$ENGINE_SVC\"" "$SVCDIR/$ENGINE_SVC" 2>/dev/null \
		&& bash -n "$SVCDIR/$ENGINE_SVC" 2>/dev/null \
		&& ok "engine service shim points at package" \
		|| bad "engine service shim DRIFT (not the expected launcher)"
else
	ok "engine service absent (stock state)"
fi
if [ -e "$SVCDIR/$OUR_SVC" ]; then
	have
	cmp -s "$SVCDIR/$OUR_SVC" "$REPO/src/service/zz_rgs_15khz" \
		&& ok "RGS service byte-identical" \
		|| bad "RGS service DRIFT"
else
	ok "RGS service absent (stock state)"
fi
TOOL_DST="${RGS15_TOOL:-/userdata/roms/rgs/rgs_crt_check.sh}"
if [ -e "$TOOL_DST" ]; then
	have
	cmp -s "$TOOL_DST" "$REPO/src/service/rgs_crt_check.sh" \
		&& ok "check tool byte-identical" \
		|| bad "check tool DRIFT/foreign"
else
	ok "check tool absent (stock state)"
fi
MARQUEE_SRC="$REPO/src/service/media/rgs_crt_check_marquee.png"
MARQUEE_DST="${RGS15_MARQUEE:-${RGS15_RGS_DIR:-/userdata/roms/rgs}/media/marquee/rgs_crt_check.png}"
# Both states are legitimate: INSTALLED must carry the wheel, STOCK must not.
# `have` marks it as an installed component, so a missing wheel reads as an
# anomaly (mixed state) instead of quietly passing on an installed box.
if [ -e "$MARQUEE_DST" ]; then
	have
	cmp -s "$MARQUEE_DST" "$MARQUEE_SRC" \
		&& ok "ES wheel byte-identical" \
		|| bad "ES wheel DRIFT/foreign (re-run install.sh or deploy.sh)"
else
	ok "ES wheel absent (stock state)"
fi
# The wheel LINE, not just the file: ES silently deletes a <marquee> placed
# before <video> (measured 2026-10-09), so a present file with the line in
# the wrong place is a broken asset that still verifies clean on file bytes.
_GL="${RGS15_RGS_DIR:-/userdata/roms/rgs}/gamelist.xml"
if [ -f "$_GL" ]; then
	# awk PRINTS a verdict; the shell decides ok/bad. Putting ok()/bad()
	# inside the awk program would be a shell function called from awk —
	# it does not exist there, so the check could never fire.
	_ws="$(awk '
		/<path>\.\/rgs_crt_check\.sh<\/path>/ { f=1; next }
		f && /<video>/ { v=NR }
		f && /<marquee>[^<]*rgs_crt_check\.png<\/marquee>/ { m=NR }
		f && /<\/game>/ { print (m==0 ? "none" : (v && m>v ? "after" : "before")); exit }
	' "$_GL")"
	case "$_ws" in
	after) ok "ES wheel line after <video> (ES keeps it)" ;;
	before) bad "ES wheel line BEFORE <video> — ES deletes it on the next gamelist save (re-run deploy.sh)" ;;
	none) bad "ES wheel line missing from our gamelist entry (re-run deploy.sh)" ;;
	*) bad "ES wheel line unreadable in gamelist (state='${_ws:-empty}')" ;;
	esac
fi
if [ -e "$SVCDIR/$VNC_SVC" ]; then
	have
	cmp -s "$SVCDIR/$VNC_SVC" "$PKG/src/service/$VNC_SVC" 2>/dev/null \
		&& ok "VNC service byte-identical" \
		|| bad "VNC service DRIFT"
else
	ok "VNC service absent (stock state)"
fi
if [ -z "${RGS15_SKIP_ENABLE:-}" ]; then
	for _s in "$ENGINE_SVC" "$OUR_SVC" "$VNC_SVC"; do
		if [ -e "$SVCDIR/$_s" ]; then
			is_registered "$_s" \
				&& ok "service registered: $_s" \
				|| bad "service file present but NOT registered: $_s"
		elif is_registered "$_s"; then
			bad "service registered but file missing: $_s"
		fi
	done
fi

# ── 6. VNC symlinks + shipped payload ──
# The payload (x11vnc + its libs) SHIPS in the bundle — GPL-2+/CMU-BSD,
# notices + written source offer in THIRD-PARTY.md. Content drift is
# already caught by the package byte-identity check above; modes are not
# compared, and the launcher exec()s the binary, so a lost +x is a real
# break that must fail here. No `have` call: the payload is part of the
# package component counted above, not a component of its own.
if [ -d "$PKG/src/vnc" ]; then
	for _v in x11vnc libvncserver.so.1 libvncclient.so.1 libsasl2.so.2; do
		if [ -e "$PKG/src/vnc/binaries/$_v" ]; then
			ok "VNC payload present: $_v"
		else
			bad "VNC payload missing: $_v (shipped component — reinstall)"
		fi
	done
	if [ -e "$PKG/src/vnc/binaries/x11vnc" ]; then
		[ -x "$PKG/src/vnc/binaries/x11vnc" ] \
			&& ok "VNC payload executable" \
			|| bad "VNC payload x11vnc not executable"
	fi
fi
for _pair in "$VNC1:$PKG/src/vnc/vnc" "$VNC2:$PKG/src/vnc/vnc-scaled"; do
	_link="${_pair%%:*}"
	_target="${_pair##*:}"
	_name="$(basename "$_link")"
	if [ -L "$_link" ]; then
		have
		[ "$(readlink "$_link")" = "$_target" ] \
			&& ok "symlink $_name -> package" \
			|| bad "symlink $_name points elsewhere ($(readlink "$_link"))"
	elif [ -e "$_link" ]; then
		have
		bad "$_link exists but is NOT our symlink (foreign file)"
	else
		ok "symlink absent: $_name (stock state)"
	fi
done

# ── 7. Box keys (skipped under RGS15_SKIP_KEYS: seam tests must not
#      read live keys — key logic is reviewed + tube-deployed instead) ──
if [ -z "${RGS15_SKIP_KEYS:-}" ]; then
if [ "$PRESENT" -gt 0 ]; then
	# Backup-only since 2026-09-17: the layer pins NO boot key (stock ES
	# owns them; auto = 640x480i *current on the CRT and native on
	# LCD-only, verbose-proven 2026-09-14). Values are reported, never
	# judged; what IS checked: the backups uninstall needs to restore.
	for _key in es.resolution global.videomode; do
		_val="$(batocera-settings-get "$_key" 2>/dev/null || true)"
		ok "box key $_key=${_val:-absent} (informational)"
	done
	_missing=""
	for _key in es.resolution global.videomode global.videooutput splash.screen.resize global.videooutput2; do
		[ -f "$PKG/backups/box-keys/$_key" ] || _missing="$_missing $_key"
	done
	[ -n "$_missing" ] \
		&& bad "box-key backups missing:$_missing (uninstall cannot restore byte-exact)" \
		|| ok "box-key backups present (uninstall can restore)"
	_vo2="$(batocera-settings-get global.videooutput2 2>/dev/null || true)"
	# GPU family, re-derived from the kernel's own boot lines (the same
	# facts channel as 4b/4c): the generator writes videooutput2=none on
	# amd/intel (stock auto-selects a backglass output onto the CRT) and
	# leaves it ABSENT on nvidia. False-FAIL bug 2026-09-10 (tester Intel
	# report): the branch below was nvidia-only, so amd/intel installs
	# read DIRTY with the CORRECT value in place. Seam: RGS15_GPU_VENDOR
	# (+ RGS15_DMESG_SRC); live = dmesg i915/amdgpu, default nvidia.
	if [ -n "${RGS15_GPU_VENDOR:-}" ]; then
		_v_gpu="$RGS15_GPU_VENDOR"
	else
		if [ -n "${RGS15_DMESG_SRC:-}" ]; then
			_v_dmesg="$(cat "$RGS15_DMESG_SRC" 2>/dev/null || true)"
		else
			_v_dmesg="$(dmesg 2>/dev/null || true)"
		fi
		case "$_v_dmesg" in
		*"Initialized i915"*) _v_gpu="intel" ;;
		*"kernel modesetting ("*|*"Initialized amdgpu"*) _v_gpu="amd" ;;
		*) _v_gpu="nvidia" ;;
		esac
	fi
	if [ "$_v_gpu" = "nvidia" ]; then
		if [ -z "$_vo2" ]; then
			ok "box key global.videooutput2 absent (nvidia keeps stock auto)"
		else
			bad "box key global.videooutput2: expected absent on nvidia, got '$_vo2'"
		fi
	elif [ "$_vo2" = "none" ]; then
		ok "box key global.videooutput2=none (stock second-screen opt-out on $_v_gpu)"
	else
		bad "box key global.videooutput2: expected none on $_v_gpu, got '${_vo2:-absent}' (stock would pick a backglass output onto the CRT; the BOOT generator writes it — reboot once after a fresh install)"
	fi
	for _key in es.resolution global.videomode global.videooutput splash.screen.resize global.videooutput2; do
		if [ -f "$PKG/backups/box-keys/$_key" ]; then
			ok "key backup archived: $_key"
		else
			bad "key backup MISSING: $_key ($PKG/backups/box-keys)"
		fi
	done
	if [ -f "$PKG/backups/stock-originals/batocera.conf.stock" ] \
		&& [ -f "$PKG/backups/stock-originals/rgs.version.stock" ]; then
		ok "stock originals snapshot present (only local copy of the stock conf)"
	else
		bad "stock originals snapshot MISSING ($PKG/backups/stock-originals/batocera.conf.stock + rgs.version.stock)"
	fi
else
	# Stock state: the package (with its key backups) is gone, so no
	# reference value survives to judge against — report the current
	# values, never gate (a residue-free stock box is CLEAN).
	for _key in es.resolution global.videomode; do
		_val="$(batocera-settings-get "$_key" 2>/dev/null || true)"
		ok "box key $_key=${_val:-absent} (informational, stock state)"
	done
	ok "box keys unchecked in stock state (no reference left to judge)"
fi
fi # RGS15_SKIP_KEYS

# ── 8. Zero residue: marked blocks + stranded marker keys ──
for _cfg in /userdata/system/batocera.conf /userdata/system/configs/retroarch/retroarchcustom.cfg; do
	if [ -f "$_cfg" ] && grep -qF "$MARK" "$_cfg" 2>/dev/null; then
		bad "residue: marked block in $_cfg (run gameStop cycle or uninstall.sh)"
	elif [ -f "$_cfg" ] && grep -qE '^crt_dual_profile[[:space:]]*=' "$_cfg" 2>/dev/null; then
		bad "residue: stranded marker key in $_cfg (crashed session? remove the line)"
	else
		ok "no marked blocks in $(basename "$_cfg")"
	fi
done

# ── 8b. Conf preserved-zone invariants (measured update model). An RGS
# update rebuilds batocera.conf keeping everything BEFORE "RGS TUNING"
# and AFTER "END RGS"; inside that zone the PACK decides. Our owned keys
# and our services registration must never sit there (a future pack would
# silently rewrite/unregister them at the next boot). ──
_conf="/userdata/system/batocera.conf"
_tun="$(grep -n 'RGS TUNING' "$_conf" 2>/dev/null | head -1 | cut -d: -f1 || true)"
_end="$(grep -n 'END RGS' "$_conf" 2>/dev/null | head -1 | cut -d: -f1 || true)"
if [ -f "$_conf" ] && [ -n "$_tun" ] && [ -n "$_end" ]; then
	_zone_bad=0
	for _key in es.resolution global.videomode global.videooutput2; do
		_line="$(grep -n "^${_key}=" "$_conf" | head -1 | cut -d: -f1 || true)"
		if [ -n "$_line" ] && [ "$_line" -gt "$_tun" ] && [ "$_line" -lt "$_end" ]; then
			bad "conf zone: $_key sits INSIDE the RGS TUNING zone ($_tun..$_end) — an update would rewrite it; move after END RGS"
			_zone_bad=1
		fi
	done
	_sline="$(grep -n '^system\.services=' "$_conf" | head -1 | cut -d: -f1 || true)"
	if [ -n "$_sline" ] && [ "$_sline" -gt "$_tun" ] && [ "$_sline" -lt "$_end" ]; then
		bad "conf zone: system.services INSIDE the RGS TUNING zone — an update would unregister our services; move before RGS TUNING"
		_zone_bad=1
	fi
	[ "$_zone_bad" = "0" ] && ok "conf zones: owned keys + services in preserved zones ($_tun..$_end protected)"
else
	ok "conf zones: no RGS TUNING markers to check against (stock conf)"
fi

# ── 9. Zero residue: no stale game-guard while no game runs ──
if [ -f /tmp/crt-dual/profile ] || [ -f /tmp/crt-dual-mode ]; then
	if pgrep -x retroarch >/dev/null 2>&1 || pgrep -f "[e]mulatorlauncher -p1" >/dev/null 2>&1; then
		ok "game guard present but a game IS running (live session)"
	else
		bad "stale game guard (/tmp/crt-dual/profile or /tmp/crt-dual-mode) with no game running"
	fi
else
	ok "no game guard (no live session)"
fi

# ── 10. Mixed installed/absent = anomaly ──
# Installed components counted above: package, hook, guard hook,
# sitecustomize, S15, udev, 3 services, 2 symlinks, ES wheel = 12 when
# fully installed. A partial set means a half-finished install or a stale
# deploy: either way the box is not in a state we can vouch for.
if [ "$PRESENT" != "0" ] && [ "$PRESENT" != "12" ]; then
	bad "mixed state ($PRESENT/12 components present — deploy.sh to sync, or uninstall.sh for a clean slate)"
fi

if [ "$FAIL" = "0" ]; then
	echo "verify.sh: CLEAN (exit 0)"
	exit 0
fi
echo "verify.sh: DIRTY (exit 1)" >&2
exit 1
