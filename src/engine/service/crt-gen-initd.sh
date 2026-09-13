#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
# Copyright (C) 2026 FreZeeN
# Part of crt-dual — https://github.com/frezeen
# S15crt-dual-gen - PRE-X conf generation hook (crt-dual).
#
# Thin launcher: the ONE true generator is crt-x11-generator.sh. This hook
# only execs it at the PRE-X position (after S12mergerfs so /userdata is
# mounted, before S31emulationstation so X's first read is correct on any
# card / ports / boot topology).
#
# Why a wrapper instead of a second generator: the previous standalone
# minimal emitter duplicated the generation logic and drifted (it lacked
# the universal analog cushion, so an LCD-only boot left X with an empty
# mode pool on the analog output - a later hotplug could never light the
# tube; verified 2026-08-24 GTX 970). One generator, one conf format,
# zero drift by construction.
#
# Pre-X safety of the generator (verified): DISPLAY unset ->
# detect_outputs uses the sysfs path (disconnected analogs land in
# CRT_PRESUMED -> crt_all includes them -> their Monitor sections +
# 480i modelines are emitted); modelines come from the switchres API
# dummy-screen calc (no X needed); structural validation is file-only.
# ── AMD pre-X block (wrapper + BOOT_TRACE switch + OutputClass fix) ──
# Why HERE and not in the boot service: the service starts AFTER the boot
# force-requery callers are already executing xrandr -> "Text file busy"
# (ETXTBSY, boot 2026-08-31 22:39:46) and after the first glitch-capable
# calls. At S15 /userdata is mounted (S12mergerfs) and NOTHING executes
# xrandr yet: the wrapper is in place before X and before every burst
# caller. Re-placed from the package at every AMD boot, no backup, no
# uninstall branch (owner directive 2026-08-31) — and RECLAIMED on non-AMD
# boots when provably ours: deploy's overlay save persists /usr, so the
# wrapper fossilizes across a GPU swap otherwise (stale AMD wrapper
# shadowed stock xrandr on NVIDIA, verify ANOMALY 2026-09-03).
source /userdata/system/crt-dual/src/lib/gpu-lib.sh 2>/dev/null || true
detect_gpu 2>/dev/null || true
# BOOT_TRACE (temporary instrument, 2026-08-31): a file in the package
# root turns the wrapper's gated FULL logging on BEFORE the burst, so one
# boot's complete call inventory lands in display-trace.log. Create it to
# investigate, remove it when done.
if [ -f /userdata/system/crt-dual/BOOT_TRACE ]; then
	mkdir -p /userdata/system/logs /tmp/crt-dual 2>/dev/null || true
	: >/userdata/system/logs/display-trace.log 2>/dev/null || true
	touch /tmp/crt-dual/display-trace-on 2>/dev/null || true
fi

if [ "${GPU_VENDOR:-}" = "amd" ] && [ -f /userdata/system/crt-dual/src/tools/xrandr-wrapper.sh ]; then
	cp -f /userdata/system/crt-dual/src/tools/xrandr-wrapper.sh /usr/bin/xrandr && chmod +x /usr/bin/xrandr &&
		echo "crt-dual: xrandr wrapper active (AMD, volatile, pre-X)" ||
		echo "crt-dual: WARN xrandr wrapper placement failed (boot force-requery calls will glitch)" >&2
elif grep -qm1 'xrandr-wrapper\.sh' /usr/bin/xrandr 2>/dev/null; then
	# Stale-wrapper reclamation (swap AMD->NVIDIA 2026-09-03): "volatile"
	# assumed /usr resets per boot, but deploy's overlay save persists the
	# upper — the AMD wrapper fossilized and shadowed stock xrandr on
	# NVIDIA (verify ANOMALY). Symmetric lifecycle: this hook placed it,
	# this hook removes it — but ONLY when provably ours (marker), and
	# NEVER without a stock binary to restore (overlay lower).
	_stock=""; for _b in /overlay/base*/usr/bin/xrandr; do [ -x "$_b" ] && { _stock="$_b"; break; }; done
	if [ -n "$_stock" ]; then
		cp -f "$_stock" /usr/bin/xrandr && chmod +x /usr/bin/xrandr &&
			echo "crt-dual: stale xrandr wrapper reclaimed (stock restored from $_stock)" ||
			echo "crt-dual: WARN wrapper reclamation copy failed" >&2
	else
		echo "crt-dual: WARN stale wrapper present but no stock xrandr found — left in place (never strand the box)" >&2
	fi
	unset _stock _b
fi

# ── AMD X11 OutputClass neutralization — pre-X, VOLATILE ──
# Stock Batocera's 20-amdgpu.conf OutputClass kills X on ANY AMD card
# ("Failed to load module amdgpu ... no screens found", verified
# 2026-08-11 R9 270X). get_xorg_configs backs up + removes the stock AMD
# OutputClasses and forces the modesetting DDX (the official CRT Script
# v43 approach, lines 4664-4686) — idempotent in every restore state
# (stock present / already neutralized / mixed). It belongs HERE (pre-X):
# the previous location (the boot service) ran AFTER X had already parsed
# the conf — it only worked because a past save persisted the fix; from
# here it is re-applied every boot and X can never see the stock state.
# Nothing is persisted: the RAM root re-derives stock, this hook
# re-derives the fix (volatile, like the wrapper).
if [ "${GPU_VENDOR:-}" = "amd" ] && command -v get_xorg_configs >/dev/null 2>&1; then
	get_xorg_configs
fi

exec bash /userdata/system/crt-dual/src/x11/crt-x11-generator.sh --force
