#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
# Copyright (C) 2026 FreZeeN
# Part of crt-dual — https://github.com/frezeen
# edid-info.sh — per-connector EDID/DPCD forensics for problem reports.
#
# FACTS ONLY, no classification decision: the `class` line comes from
# display-detect.sh (the single source of truth). This tool answers, for
# every connector: what the EDID says (identity, input type, sizes,
# descriptor tags, extension, first DTD) and — on DP connectors — what
# the DPCD branch block says (downstream port type + OUI) read through
# the DRM aux chardev (/dev/drm_dp_auxN, read-only, offset = DPCD
# register; a converter that fabricates its EDID still declares itself
# here: downstream port type Analog VGA, 2026-09-20 Intel box).
#
# Why it exists: user reports must show whether an EDID is a real
# display or an adapter's fabrication, and which chip sits in between.
#
# Usage: edid-info.sh
# Env:   CRT_DUAL_SYSFS (sysfs root; tests), CRT_DUAL_AUX_DIR (default /dev)
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SYSFS="${CRT_DUAL_SYSFS:-/sys/class/drm}"
AUXDIR="${CRT_DUAL_AUX_DIR:-/dev}"
DETECT="$HERE/../display/display-detect.sh"

_bytes() { od -An -tu1 -v "$1" 2>/dev/null | tr '\n' ' '; }
_chr() { printf "\\$(printf '%03o' "$1")"; }
_pnp() { # $1,$2 = EDID bytes 8,9 -> 3-letter PNP id (5-bit packed)
	printf '%s%s%s' \
		"$(_chr $(( (($1 >> 2) & 0x1f) + 64 )))" \
		"$(_chr $(( (((($1 & 3) << 3) | ($2 >> 5))) + 64 )))" \
		"$(_chr $(( ($2 & 0x1f) + 64 )))"
}
_dpcd() { # $1 node, $2 offset, $3 count -> hex bytes (no spaces)
	timeout 2 dd if="$1" bs=1 skip="$2" count="$3" 2>/dev/null | od -An -tx1 | tr -d ' \n'
}
_dpcd_type() { # $1 = DPCD 0x05 -> downstream port type
	case "$(( ($1 >> 1) & 3 ))" in
	0) echo "DisplayPort" ;;
	1) echo "Analog VGA" ;;
	2) echo "TMDS (DVI/HDMI)" ;;
	3) echo "Other" ;;
	esac
}

echo "== adapter / EDID forensics (edid-info.sh) =="
echo "date: $(date '+%F %T')  sysfs: $SYSFS  aux: $AUXDIR"
classes="$(bash "$DETECT" --list 2>/dev/null || true)"
echo ""

for d in "$SYSFS"/card*-*/; do
	[ -f "$d/status" ] || continue
	drm=$(basename "$d")
	drm=${drm#card*-}
	st=$(cat "$d/status" 2>/dev/null)
	cls=$(printf '%s\n' "$classes" | awk -F'\t' -v k="$drm" '$1 == k { print $2; exit }')
	echo "== connector: $drm ($(basename "$d")) =="
	echo "  status:      $st"
	[ -n "$cls" ] && echo "  class:       $cls  (display-detect)"

	e="$d/edid"
	n=0
	[ -r "$e" ] && n=$(wc -c <"$e" 2>/dev/null | tr -d ' ')
	if [ "${n:-0}" -gt 0 ]; then
		echo "  edid:        $n bytes"
		read -r -a b <<<"$(_bytes "$e")"
		if [ "${#b[@]}" -ge 128 ]; then
			printf '  identity:    PNP=%s product=0x%02x%02x serial=%d week=%d/%d\n' \
				"$(_pnp "${b[8]}" "${b[9]}")" "${b[11]}" "${b[10]}" \
				"$(( b[12] | (b[13] << 8) | (b[14] << 16) | (b[15] << 24) ))" \
				"${b[16]}" "$(( b[17] + 1990 ))"
			if [ $(( b[20] & 0x80 )) -ne 0 ]; then
				# EDID 1.4 moved the digital interface to bits 3-0
				# (bits 6-4 became the color bit depth)
				if [ "${b[18]}" -ge 1 ] && [ "${b[19]}" -ge 4 ]; then
					iface_code=$(( b[20] & 15 ))
				else
					iface_code=$(( (b[20] >> 4) & 7 ))
				fi
				case "$iface_code" in
				0) iface="undefined" ;;
				1) iface="DVI" ;;
				2) iface="HDMI-a" ;;
				3) iface="HDMI-b" ;;
				4) iface="MDDI" ;;
				5) iface="DisplayPort" ;;
				*) iface="reserved" ;;
				esac
				echo "  input:       digital / $iface"
			else
				echo "  input:       ANALOG (a VGA display's own EDID)"
			fi
			bh="${b[21]}"
			bv="${b[22]}"
			dh=$(( b[66] | ((b[68] >> 4) << 8) ))
			dv=$(( b[67] | ((b[68] & 15) << 8) ))
			echo "  size:        base ${bh}x${bv} cm; first DTD ${dh}x${dv} mm"
			tags=""
			has_nr="no"
			for off in 54 72 90 108; do
				if [ "${b[$off]}" = "0" ] && [ "${b[$off + 1]}" = "0" ] && [ "${b[$off + 2]}" = "0" ]; then
					case "${b[$off + 3]}" in
					252) tags="$tags name"; has_nr="yes" ;;
					253) tags="$tags range"; has_nr="yes" ;;
					254) tags="$tags text" ;;
					255) tags="$tags serial" ;;
					0) tags="$tags pad" ;;
					*) tags="$tags desc(0x$(printf '%02x' "${b[$off + 3]}"))" ;;
					esac
				elif [ $(( b[$off] | (b[$off + 1] << 8) )) -gt 0 ]; then
					tags="$tags DTD"
				else
					tags="$tags pad"
				fi
			done
			ext="${b[126]}"
			exttag=""
			[ "$ext" -gt 0 ] && [ "${#b[@]}" -ge 129 ] && exttag=$(printf ' (first tag=0x%02x)' "${b[128]}")
			echo "  descriptors:$tags"
			echo "  extension:   ${ext} block(s)$exttag"
			# descriptor offsets: base slots + (when present) the CTA
			# extension's DTD/descriptor area (byte 130 = DTD offset)
			offs="54 72 90 108"
			if [ "$ext" -gt 0 ] && [ "${#b[@]}" -ge 256 ]; then
				o=$(( 128 + ${b[130]:-0} ))
				while [ "$o" -le 236 ]; do
					offs="$offs $o"
					o=$((o + 18))
				done
			fi
			feat="${b[24]}" # feature support byte (0x18)
			fcont="no"
			[ $(( feat & 128 )) -ne 0 ] && fcont="yes"
			fnative="no"
			[ $(( feat & 64 )) -ne 0 ] && fnative="yes"
			case $(( (feat >> 3) & 3 )) in
			0) ftype="mono" ;;
			1) ftype="RGB" ;;
			2) ftype="non-RGB" ;;
			3) ftype="undefined" ;;
			esac
			echo "  feature:     continuous-frequency=$fcont preferred-native=$fnative display-type=$ftype"
			# CRT signals: sub-25 kHz timing (no LCD does 15 kHz) or an
			# interlaced DTD (panels never declare interlace). Facts only —
			# on a fabricated adapter EDID these describe the template.
			rng=""
			sub25="no"
			ilace="no"
			for off in $offs; do
				if [ "${b[$off]:-x}" = "0" ] && [ "${b[$off + 1]:-x}" = "0" ] && [ "${b[$off + 2]:-x}" = "0" ]; then
					[ "${b[$off + 3]:-0}" = "253" ] && [ -z "$rng" ] && rng="$off"
					continue
				fi
				clk10=$(( ${b[$off]:-0} | (${b[$off + 1]:-0} << 8) ))
				[ "$clk10" -gt 0 ] || continue
				ha=$(( ${b[$off + 2]:-0} | ((${b[$off + 4]:-0} >> 4) << 8) ))
				hb=$(( ${b[$off + 3]:-0} | ((${b[$off + 4]:-0} & 15) << 8) ))
				ht=$(( ha + hb ))
				[ "$ht" -gt 0 ] && [ $(( clk10 * 10 / ht )) -lt 25 ] && sub25="yes"
				[ $(( ${b[$off + 17]:-0} & 128 )) -ne 0 ] && ilace="yes"
			done
			if [ -n "$rng" ]; then
				echo "  range:       hsync ${b[$rng + 7]}-${b[$rng + 8]}kHz, vrefresh ${b[$rng + 5]}-${b[$rng + 6]}Hz, max-clock $(( ${b[$rng + 9]} * 10 ))MHz"
				[ "${b[$rng + 7]}" -lt 25 ] && sub25="yes"
			fi
			if [ "$sub25" = "yes" ]; then
				echo "  edid-hint:   sub-25kHz=yes interlaced=$ilace -> 15kHz-capable (CRT/TV)"
			elif [ "$ilace" = "yes" ]; then
				echo "  edid-hint:   sub-25kHz=no interlaced=yes -> CRT-like, NOT 15 kHz (a 31 kHz+ CRT uses the panel path like an LCD)"
			else
				echo "  edid-hint:   sub-25kHz=no interlaced=no -> no 15kHz signal (LCD-like or 31kHz+ display)"
			fi
			if [ "$has_nr" = "yes" ]; then
				echo "  edid-nature: display descriptors present (the display's own EDID)"
			else
				echo "  edid-nature: no name/range descriptor (template/fabricated block — the real display's EDID is not exposed)"
			fi
			if [ $(( b[54] | (b[55] << 8) )) -gt 0 ]; then
				clk10=$(( b[54] | (b[55] << 8) ))
				ha=$(( b[56] | ((b[58] >> 4) << 8) ))
				hb=$(( b[57] | ((b[58] & 15) << 8) ))
				va=$(( b[59] | ((b[61] >> 4) << 8) ))
				vb=$(( b[60] | ((b[61] & 15) << 8) ))
				ht=$(( ha + hb ))
				vt=$(( va + vb ))
				pol=""
				[ $(( b[71] & 2 )) -ne 0 ] && pol="+H" || pol="-H"
				[ $(( b[71] & 4 )) -ne 0 ] && pol="$pol +V" || pol="$pol -V"
				il=""
				[ $(( b[71] & 128 )) -ne 0 ] && il="i"
				read -r fclk fhs fvr <<<"$(awk -v c="$clk10" -v ht="$ht" -v vt="$vt" \
					'BEGIN { printf "%.2f %.2f %.2f", c / 100, (c * 10) / ht, (c * 10000) / (ht * vt) }')"
				echo "  dtd1:        ${ha}x${va}${il} clock=${fclk}MHz hsync=${fhs}kHz vrefresh=${fvr}Hz sync=${pol}"
			fi
		fi
		echo "  edid-hex:    $(xxd -p "$e" 2>/dev/null | tr -d '\n')"
	else
		echo "  edid:        0 bytes (no DDC / no display)"
	fi

	aux=""
	for a in "$d"/drm_dp_aux*; do
		[ -e "$a" ] || continue
		aux="$AUXDIR/$(basename "$a")"
		break
	done
	if [ -n "$aux" ]; then
		if [ -r "$aux" ]; then
			caps=$(_dpcd "$aux" 0 16)
			read -r -a c <<<"$(printf '%s' "$caps" | fold -w2 | tr '\n' ' ')"
			down="none"
			[ $(( 16#${c[5]:-00} & 1 )) -ne 0 ] && down="present, type=$(_dpcd_type "$(( 16#${c[5]:-00} ))")"
			oui=$(_dpcd "$aux" 1280 3)
			echo "  dpcd:        rev=0x${c[0]:-??} rate=0x${c[1]:-??} lanes=$(( 16#${c[2]:-00} & 0x1f )) | downstream: $down | branch OUI=${oui:-none} | raw=$caps"
		else
			echo "  dpcd:        $aux present but not readable (root needed)"
		fi
	else
		echo "  dpcd:        no aux channel (not a DP connector, or driver without the chardev)"
	fi
	echo ""
done
