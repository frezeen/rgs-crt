#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0
# resolution-crt-patch — apply/verify the stock batocera-resolution raster
# hunks (RGS-15KHZ-EXT).
#
# Writers: zz_rgs_15khz (resolution-patch duty, every boot — rgs_config
# re-copies the stock file BEFORE this service) + install.sh (one-shot,
# first apply takes the whole-file backup). Readers: verify.sh (drift =
# the live file must carry the marker when the layer is installed),
# uninstall.sh (restores the backup byte-exact).
#
# The hunks are the upstream batocera-crt-proposal's patch 0003 logic,
# adapted to this RGS's stock launcher (470-line variant): the listModes
# announce of the conf-declared rasters, the generate-at-request in BOTH
# setMode branches, the interlaced fallback for the dotted restore. Every
# block is gated on the engine bridge's presence: without the layer each
# action is byte-for-byte stock. Owner authorization 2026-09-13 — when
# the proposal lands upstream, this file, the duty glue and the backup
# dance are DELETED (the file arrives already carrying the hunks).
#
# Usage: resolution-crt-patch.py apply|check <target> [backup-path]
import sys
from pathlib import Path

MARKER = "# RGS-15KHZ-EXT (stock raster channel"
BRIDGE = "/userdata/system/crt-dual/src/api/switchres_api.py"

_POOL = (
    "_POOL=$(xrandr --current 2>/dev/null | awk -v out=\"${OUTPUT}\" '\n"
    "                            $1 == out && $2 == \"connected\" { grab = 1; next }\n"
    "                            /^[A-Za-z]/ { grab = 0 }\n"
    "                            grab && /^   / { print $1 }\n"
    "                        ')"
)

_H1 = '''        @MARKER@ — upstream batocera-crt-proposal patch 0003, adapted):
        # rasters declared by the user in batocera.conf videomode keys are
        # providable on demand. Announcing them lets the configgen
        # validation accept the key, and setMode generates the modeline at
        # application time. The bridge presence is the layer's presence:
        # without the engine nothing is announced and this action is
        # exactly the stock one.
        if [ -f @BRIDGE@ ]; then
            for _raster in $(grep -E '^[a-zA-Z0-9_.]+\\.videomode=[^[:space:]]+' /userdata/system/batocera.conf 2>/dev/null | sed 's/^[^=]*=//; s/\\r$//' | sort -u); do
                case "$_raster" in max-*) continue ;; esac
                case "$_raster" in [0-9]*x[0-9]*) ;; *) continue ;; esac
                echo "$_raster:videomode key (Switchres CRT layer)"
            done
        fi'''

_H2 = '''                @MARKER@ — upstream patch 0003, adapted): a conf value
                # carrying the rate is computed with that exact rate when
                # absent from the pool. The pool comes from the glitch-free
                # --current output (on AMD dce_v6 every force-requery call
                # re-probes the analog DAC and blips the 15 kHz tube; --current
                # and the writes are silent). The pool entry carries the
                # stock PARTRES name (--name), so the apply below finds it.
                # A failed computation degrades to the stock behavior (the
                # game carries the desktop mode), never silent.
                if [ -f @BRIDGE@ ]; then
                    @POOL@
                    if echo "$_POOL" | grep -qx "${PARTRES}"; then
                        : # already in the pool — the apply below finds it
                    elif echo "$_POOL" | grep -qx "${PARTRES}i"; then
                        echo "setMode: interlaced fallback ${PARTRES} -> ${PARTRES}i" >> $log
                        PARTRES="${PARTRES}i"
                    else
                        _W=${PARTRES%%x*}; _H=${PARTRES#*x}; _I=""
                        case "${_H}" in *i) _I="i"; _H="${_H%i}" ;; esac
                        MODELINE=$(SR_FLOOR=1 python3 @BRIDGE@ calc "${_W}" "${_H}" "${PARTHZ}${_I}" --name "${PARTRES}" 2>>$log)
                        if [ -n "$MODELINE" ]; then
                            echo "setMode: generating ${MODE} via the Switchres CRT layer" >> $log
                            _MPARAMS=$(echo "$MODELINE" | sed 's/^Modeline "[^"]*"//')
                            xrandr --newmode "${PARTRES}" ${_MPARAMS}
                            xrandr --addmode "${OUTPUT}" "${PARTRES}"
                        else
                            echo "setMode: ${MODE} declared but the Switchres layer produced no modeline (stock behavior kept)" >> $log
                        fi
                    fi
                fi'''

_H3 = '''                @MARKER@ — upstream patch 0003, adapted): the bare
                # branch computes the default refresh (the API refresh-scales
                # the request into the preset; the preset IS the tube
                # safety). Same glitch-free pool read, same degradation.
                if [ -f @BRIDGE@ ]; then
                    _MODE_RE=$(printf '%s' "${MODE}" | sed 's/[]\\.|$(){}?+*^\\\\]/\\\\&/g')
                    if grep -qE "^[a-zA-Z0-9_.]+\\.videomode=${_MODE_RE}(\\.[^[:space:]]+)?[[:space:]]*$" /userdata/system/batocera.conf 2>/dev/null; then
                        @POOL@
                        if ! echo "$_POOL" | grep -qx "${MODE}"; then
                            _W=${MODE%%x*}; _H=${MODE#*x}; _I=""
                            case "${_H}" in *i) _I="i"; _H="${_H%i}" ;; esac
                            MODELINE=$(python3 @BRIDGE@ calc "${_W}" "${_H}" "60${_I}" --name "${MODE}" 2>>$log)
                            if [ -n "$MODELINE" ]; then
                                echo "setMode: generating ${MODE} via the Switchres CRT layer" >> $log
                                _MPARAMS=$(echo "$MODELINE" | sed 's/^Modeline "[^"]*"//')
                                xrandr --newmode "${MODE}" ${_MPARAMS}
                                xrandr --addmode "${OUTPUT}" "${MODE}"
                            else
                                echo "setMode: ${MODE} declared but the Switchres layer produced no modeline (stock behavior kept)" >> "$log"
                            fi
                        fi
                    fi
                fi'''

def _subst(text):
    return text.replace("@MARKER@", MARKER).replace("@BRIDGE@", BRIDGE).replace("@POOL@", _POOL)

HUNKS = [
    ('        xrandr --listModes "${PSCREEN}" | sed -e s+\'\\*$\'++ | '
     "sed -e s+'^\\([^ ]*\\) \\(.*\\)$'+'\\1:\\2'+",
     "after", _subst(_H1)),
    ("                PARTHZ=$(echo \"${MODE}\" | cut -d'.' -f2-)",
     "after", _subst(_H2)),
    ("                echo \"setMode: Output: ${OUTPUT} Mode: ${MODE}\" >> $log",
     "before", _subst(_H3)),
]



def fail(msg):
    print(f"resolution-crt-patch: FAIL: {msg}", file=sys.stderr)
    sys.exit(1)


def apply(target: Path, backup: Path) -> int:
    text = target.read_text(errors="strict")
    if MARKER in text:
        if all(h[2].rstrip("\n") in text for h in HUNKS):
            print("resolution-crt-patch: already applied (marker + hunks current)")
            return 0
        # the hunks evolved (marker present, content older) — restore the
        # stock snapshot and re-apply; without a snapshot, fail loud.
        if backup.exists():
            target.write_bytes(backup.read_bytes())
            text = target.read_text(errors="strict")
            print("resolution-crt-patch: hunk set updated — restored from the snapshot, re-applying")
        else:
            fail("hunk set outdated and NO stock snapshot to rebuild from")
    if not backup.exists():
        # the snapshot is taken ONLY from the pristine stock state (the
        # marker is absent above) — first apply wins, re-runs never churn
        backup.parent.mkdir(parents=True, exist_ok=True)
        backup.write_bytes(target.read_bytes())
        print(f"resolution-crt-patch: stock snapshot taken -> {backup}")
    new = text
    for anchor, position, block in HUNKS:
        count = new.count(anchor)
        if count != 1:
            fail(f"anchor missing/ambiguous ({count}x) — the launcher changed "
                 "(RGS update?): the layer holds stock behavior, verify flags it")
        if position == "after":
            new = new.replace(anchor, anchor + "\n" + block.rstrip("\n"), 1)
        else:
            new = new.replace(anchor, block.rstrip("\n") + "\n" + anchor, 1)
    tmp = target.with_suffix(".tmp")
    tmp.write_text(new)
    tmp.chmod(0o755)
    tmp.replace(target)
    patched = target.read_text()
    if MARKER not in patched or not all(h[0] in patched for h in HUNKS):
        fail("self-check failed after the write")
    print(f"resolution-crt-patch: applied {len(HUNKS)} hunks -> {target}")
    return 0


def check(target: Path) -> int:
    if MARKER in target.read_text(errors="replace"):
        print("resolution-crt-patch: hunks present")
        return 0
    print("resolution-crt-patch: hunks ABSENT (stock launcher)")
    return 1


def main():
    if len(sys.argv) < 3:
        print("usage: resolution-crt-patch.py apply|check <target> [backup]",
              file=sys.stderr)
        return 2
    cmd, target = sys.argv[1], Path(sys.argv[2])
    backup = Path(sys.argv[3]) if len(sys.argv) > 3 else target.parent / ".stock-bak"
    if cmd == "apply":
        return apply(target, backup)
    if cmd == "check":
        return check(target)
    fail(f"unknown command: {cmd}")


if __name__ == "__main__":
    sys.exit(main())
