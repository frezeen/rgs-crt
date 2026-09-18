#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0
# Copyright (C) 2026 FreZeeN
# Part of crt-dual — https://github.com/frezeen
"""Switchres library bridge — ctypes over the STOCK libswitchres.so.

Who creates/reads this: the generator (calc — boot-time X11 conf
modelines), sr-owner.sh (create — converter 240p path), the patched
stock launcher hunks (calc --name), diag-dump.sh / verify.sh (version,
calc smoke). No other consumer. Not persistent state.

Why a ctypes bridge and not the `switchres` CLI:
  - Same engine, zero text parsing: the modeline arrives STRUCTURED in the
    sr_mode struct (switchres_wrapper.h ABI) instead of grepped/cut from
    CLI stdout.
  - Alignment with the official integration path: the Batocera CRT Script
    maintainer's long-term plan is calling the Switchres API instead of
    the CLI tool. This is that call, working.
  - Zero toolchain: pure source over the stock library Batocera ships
    (/usr/lib64/libswitchres.so.2.x — the same lib /usr/bin/switchres
    links). Nothing compiled, nothing bundled. Python 3 + ctypes are
    stock (configgen IS Python).

Scope contract (user-approved design, plan switchres-api-migration):
  DATA-PLANE ONLY. This helper computes modelines (the library owns the
  generation math). It never attaches modes or drives the X server: the
  library names created modes "SR-*" (custom_video_xrandr.cpp::add_mode),
  which is our game-mode marker, and session modes do not survive an X
  restart — the persistent canonical names (640x480i/320x240 from the
  generated conf) belong to the stock batocera-resolution contract. The
  verified glitch-free xrandr application sequence stays in bash.

Loud-failure policy: any failure exits non-zero with a message on stderr.
There is deliberately NO fallback to the switchres CLI in runtime paths
(the CLI survives only as this repo's test oracle).

Usage:
  switchres_api.py calc W H R [i] [--monitor PRESET] [--ini PATH]
      Print one Xorg-style `Modeline "<label>" <params>` line, formatted
      exactly like the CLI's (modeline_print MS_LABEL|MS_PARAMS) so the
      CLI remains a byte-for-byte acceptance oracle. R accepts the CLI's
      trailing "i" interlace suffix (e.g. "60i").
  switchres_api.py version
      Print the loaded library path and its reported version string.

Exit codes: 0 ok · 2 bad usage · 10 library load failed · 11 init failed
· 12 mode generation failed.
"""

import contextlib
import ctypes
import glob
import os
import re
import sys
from typing import NoReturn, Tuple

# Mode flags — switchres_wrapper.h (identical in v2.2.1 and master 2.2.2,
# both headers fetched and compared byte-for-byte 2026-08-22).
SR_MODE_INTERLACED = 1 << 0
SR_MODE_ROTATED = 1 << 1
SR_MODE_DONT_FLUSH = 1 << 16


class SrMode(ctypes.Structure):
    """Mirror of `sr_mode` from switchres_wrapper.h (the C ABI contract)."""

    _fields_ = [
        ("width", ctypes.c_int),
        ("height", ctypes.c_int),
        ("refresh", ctypes.c_int),
        #
        ("vfreq", ctypes.c_double),
        ("hfreq", ctypes.c_double),
        #
        ("pclock", ctypes.c_uint64),
        ("hbegin", ctypes.c_int),
        ("hend", ctypes.c_int),
        ("htotal", ctypes.c_int),
        ("vbegin", ctypes.c_int),
        ("vend", ctypes.c_int),
        ("vtotal", ctypes.c_int),
        ("interlace", ctypes.c_int),
        ("doublescan", ctypes.c_int),
        ("hsync", ctypes.c_int),
        ("vsync", ctypes.c_int),
        #
        ("is_refresh_off", ctypes.c_int),
        ("is_stretched", ctypes.c_int),
        ("x_scale", ctypes.c_double),
        ("y_scale", ctypes.c_double),
        ("v_scale", ctypes.c_double),
        ("id", ctypes.c_int),
    ]


def die(code: int, message: str) -> NoReturn:
    """Loud failure: message on stderr, non-zero exit."""
    print("switchres_api: %s" % message, file=sys.stderr)
    sys.exit(code)


def _soname_version(path: str) -> Tuple[int, ...]:
    """Version tuple parsed out of libswitchres.so[.N...]; (0,) when the
    soname carries none."""
    found = re.search(r"libswitchres\.so((?:\.\d+)+)$", path)
    return tuple(int(x) for x in found.group(1).strip(".").split(".")) if found else (0,)


def _parse_refresh(refresh_arg) -> Tuple[float, int]:
    """(refresh_float, interlace_flags) — CLI parity: a trailing "i" forces
    interlace (scan_mode check in switchres_main.cpp)."""
    flags = 0
    text = str(refresh_arg)
    if text.endswith("i"):
        flags |= SR_MODE_INTERLACED
        text = text[:-1]
    try:
        return float(text), flags
    except ValueError:
        die(2, "invalid refresh '%s'" % refresh_arg)


@contextlib.contextmanager
def _stdout_to_stderr():
    """Redirect fd 1 -> stderr for the duration of the library calls.

    The library logs through C-level printf (not wrappable from ctypes).
    Flush the C streams WHILE fd 1 still points at stderr — otherwise the
    buffered chatter drains at process exit, after the restore, back onto
    our structured stdout."""
    saved = os.dup(1)
    try:
        os.dup2(2, 1)
        yield
        ctypes.CDLL(None).fflush(None)
    finally:
        os.dup2(saved, 1)
        os.close(saved)


def _format_modeline(mode: "SrMode", name=None) -> str:
    """One Xorg-style Modeline line, formatted EXACTLY like the CLI's
    log_info("Switchres: Modeline %s\\n") line (modeline_print with
    MS_LABEL|MS_PARAMS, modeline.cpp v2.2.1) so the CLI stays a
    byte-for-byte test oracle. Empty flag fields keep their placeholder
    spaces (the CLI's sprintf emits them too). NOTE: sr_mode carries the
    actives as width/height (modeline_to_sr_mode maps
    modeline.hactive/vactive into them)."""
    label = "%dx%d_%d%s %.6fKHz %.6fHz" % (
        mode.width,
        mode.height,
        mode.refresh,
        "i" if mode.interlace else "",
        mode.hfreq / 1000.0,
        mode.vfreq,
    )
    # RGS-15KHZ-EXT (stock raster channel): --name replaces the label with
    # one single word (the caller's pool name — upstream helper parity,
    # the PR's own --name flag); the timing fields stay untouched.
    if name:
        label = "%s %.6fKHz %.6fHz" % (name, mode.hfreq / 1000.0, mode.vfreq)
    params = " %.6f %d %d %d %d %d %d %d %d %s %s %s %s" % (
        mode.pclock / 1000000.0,
        mode.width,
        mode.hbegin,
        mode.hend,
        mode.htotal,
        mode.height,
        mode.vbegin,
        mode.vend,
        mode.vtotal,
        "interlace" if mode.interlace else "",
        "doublescan" if mode.doublescan else "",
        "+hsync" if mode.hsync else "-hsync",
        "+vsync" if mode.vsync else "-vsync",
    )
    return 'Modeline "%s"%s' % (label, params)


def load_library() -> Tuple[ctypes.CDLL, str]:
    """Load the STOCK libswitchres.so (never bundled, never compiled).

    Search mirrors the dynamic linker; among versioned sonames the NEWEST
    wins (unversioned devel symlinks do not exist on stock Batocera).

    The stock Batocera build is linked against optional SDL2 symbols that
    ARE executed even on the calc path (verified 2026-08-22: a lazy-only
    load dies at call time with 'undefined symbol: SDL_WasInit'). SDL2 is
    therefore preloaded into the global namespace first (best-effort — a
    build without SR_WITH_SDL2 does not need it), then the library loads
    with eager binding so a genuinely missing dependency fails LOUDLY now,
    not mid-call.
    """
    with contextlib.suppress(OSError):
        sdl = ctypes.CDLL("libSDL2-2.0.so.0", mode=os.RTLD_GLOBAL | os.RTLD_NOW)
        del sdl  # held alive by the loader's global namespace; no SDL2 present is only fatal if the switchres build needs it

    candidates = []
    for pattern in (
        "/usr/lib64/libswitchres.so*",
        "/usr/lib/libswitchres.so*",
        "/usr/local/lib64/libswitchres.so*",
        "/usr/local/lib/libswitchres.so*",
    ):
        candidates.extend(glob.glob(pattern))
    # Newest version first; dedupe merged-/usr realpath aliases.
    unique = {}
    for path in sorted(set(candidates), key=_soname_version, reverse=True):
        unique[os.path.realpath(path)] = path
    candidates = list(unique.values())

    last_err = None
    for path in ["libswitchres.so"] + candidates:
        try:
            return ctypes.CDLL(path), path
        except OSError as err:
            last_err = err
    die(10, "cannot load the stock libswitchres.so (%s)" % last_err)


def init_dummy_session(lib, ini_path, monitor_preset):
    """Start a switchres session equivalent to the CLI's `-c` calc mode.

    Sequence (mirrors switchres_main.cpp v2.2.1, calculate_flag branch):
    sr_init parses the system switchres.ini; the user ini is layered on
    top; screen=dummy selects dummy_display (display_manager::make) so
    NOTHING touches the X server — the exact property that makes the CLI
    `-c` safe. keep_changes=1 so deinit can never restore/undo anything.
    """
    lib.sr_init()
    if ini_path:
        lib.sr_load_ini(ini_path.encode())
    if monitor_preset:
        # Before init_disp: add_display re-parses options with this preset
        # (same order as the CLI applying -m before add_display).
        lib.sr_set_monitor(monitor_preset.encode())
    lib.sr_set_option(b"keep_changes", b"1")

    # The dummy screen goes through sr_init_disp's OWN screen argument —
    # the same call the CLI's calculate branch performs via
    # display()->set_screen("dummy") (there is NO "screen" ini key in
    # v2.2.1's set_option map — verified on box 2026-08-22: 'Invalid
    # option screen'; the key is "display", but the explicit argument is
    # the exact CLI-equivalent path).
    lib.sr_init_disp.restype = ctypes.c_int
    idx = lib.sr_init_disp(b"dummy", None)
    if idx < 0:
        die(11, "sr_init_disp failed (dummy display init)")


def calc_modeline(width, height, refresh_arg, ini_path, monitor_preset,
                  name=None):
    """Compute one modeline via the library; return the Modeline line."""
    refresh, flags = _parse_refresh(refresh_arg)
    if width <= 0 or height <= 0 or refresh <= 0.0:
        die(2, "invalid mode request %dx%d@%s" % (width, height, refresh_arg))

    lib, lib_path = load_library()

    with _stdout_to_stderr():
        try:
            init_dummy_session(lib, ini_path, monitor_preset)

            mode = SrMode()
            result = lib.sr_add_mode(
                ctypes.c_int(width),
                ctypes.c_int(height),
                ctypes.c_double(refresh),
                ctypes.c_int(flags | SR_MODE_DONT_FLUSH),  # compute, never attach
                ctypes.byref(mode),
            )
            if not result or mode.width == 0:
                die(
                    12,
                    "library produced no modeline for %dx%d@%s (lib: %s)"
                    % (width, height, refresh_arg, lib_path),
                )
        finally:
            lib.sr_deinit()

    return _format_modeline(mode, name)


def create_mode(
    width,
    height,
    refresh_arg,
    output,
    ini_path,
    monitor_preset,
):
    """Generate a mode via the library and ATTACH it to a real output.

    One library session does what the CLI+xrandr era needed four shell
    steps for: generation (sr_add_mode), attach (sr_flush ->
    XRRCreateMode+XRRAddOutputMode with the library's fresh SR-* name —
    immune to ModePool shadowing by construction). The MODESET stays with
    the caller (one RandR write by this returned handle): the library's
    in-session sr_set_mode resizes the framebuffer and BadMatches
    (RRSetScreenSize) when a second CRTC is live — a dual topology,
    verified 2026-08-28 GTX 970. Single-output hosts may still drive it
    directly through the library.

    Idempotent: the SR-* name is deterministic, so re-running finds the
    existing mode (the library logs 'duplicate request' and succeeds).

    Prints the resulting X mode NAME on stdout (single line) so the bash
    layer can select it without any name bookkeeping of its own.
    """
    refresh, flags = _parse_refresh(refresh_arg)
    if width <= 0 or height <= 0 or refresh <= 0.0 or not output:
        die(2, "invalid create request %dx%d@%s on '%s'" % (width, height, refresh_arg, output))

    lib, lib_path = load_library()

    with _stdout_to_stderr():
        try:
            # Real-display session (NOT dummy): the X server connection comes
            # from DISPLAY via the library's own XOpenDisplay.
            lib.sr_init()
            if ini_path:
                lib.sr_load_ini(ini_path.encode())
            if monitor_preset:
                lib.sr_set_monitor(monitor_preset.encode())
            # Safety rails: both features DISABLE other CRTCs
            # when enabled (set_timing issues XRRSetCrtcConfig(... None) on
            # outputs outside the requested ones). Defaults are already off;
            # assert them so an upstream default change fails HERE, loudly.
            lib.sr_set_option(b"screen_reordering", b"0")
            lib.sr_set_option(b"screen_compositing", b"0")
            lib.sr_set_option(b"keep_changes", b"1")  # teardown owns nothing

            lib.sr_init_disp.restype = ctypes.c_int
            idx = lib.sr_init_disp(output.encode(), None)
            if idx < 0:
                die(11, "sr_init_disp failed on output '%s'" % output)

            mode = SrMode()
            result = lib.sr_add_mode(
                ctypes.c_int(width),
                ctypes.c_int(height),
                ctypes.c_double(refresh),
                ctypes.c_int(flags),  # no DONT_FLUSH: add+flush = generate+attach
                ctypes.byref(mode),
            )
            if not result or mode.width == 0:
                die(
                    12,
                    "library could not create/attach %dx%d@%s on '%s' (lib: %s)"
                    % (width, height, refresh_arg, output, lib_path),
                )
        finally:
            lib.sr_deinit()

    # The attach name is built by custom_video_xrandr.cpp::add_mode as
    # SR-<timing-id>_<w>x<h>@<vfreq>[i] with the timing id starting at
    # 1 within this single-display session; vfreq formatted %.2f.
    name = "SR-%d_%dx%d@%.2f%s" % (
        1,
        mode.width,
        mode.height,
        mode.vfreq,
        "i" if mode.interlace else "",
    )
    return name


def main(argv):
    if len(argv) < 1:
        die(2, "missing subcommand (calc|create|version)")

    cmd = argv[0]
    if cmd == "version":
        lib, lib_path = load_library()
        lib.sr_get_version.restype = ctypes.c_char_p
        print("%s (%s)" % (lib.sr_get_version().decode(), lib_path))
        return 0

    if cmd == "calc":
        args = []
        ini_path = None
        monitor_preset = None
        name = None
        rest = argv[1:]
        while rest:
            arg = rest.pop(0)
            if arg == "--ini":
                ini_path = rest.pop(0) if rest else None
                if not ini_path:
                    die(2, "--ini requires a path")
            elif arg == "--monitor":
                monitor_preset = rest.pop(0) if rest else None
                if not monitor_preset:
                    die(2, "--monitor requires a preset name")
            elif arg == "--name":
                name = rest.pop(0) if rest else None
                if not name:
                    die(2, "--name requires a label")
            else:
                args.append(arg)
        if len(args) != 3:
            die(2, "usage: calc W H R[i] [--monitor PRESET] [--ini PATH] [--name LABEL]")
        try:
            width, height = int(args[0]), int(args[1])
        except ValueError:
            die(2, "W and H must be integers")
        print(calc_modeline(width, height, args[2], ini_path, monitor_preset, name))
        return 0

    if cmd == "create":
        args = []
        ini_path = None
        monitor_preset = None
        rest = argv[1:]
        while rest:
            arg = rest.pop(0)
            if arg == "--ini":
                ini_path = rest.pop(0) if rest else None
                if not ini_path:
                    die(2, "--ini requires a path")
            elif arg == "--monitor":
                monitor_preset = rest.pop(0) if rest else None
                if not monitor_preset:
                    die(2, "--monitor requires a preset name")
            else:
                args.append(arg)
        if len(args) != 4:
            die(2, "usage: create W H R[i] OUTPUT [--monitor PRESET] [--ini PATH]")
        try:
            width, height = int(args[0]), int(args[1])
        except ValueError:
            die(2, "W and H must be integers")
        print(create_mode(width, height, args[2], args[3], ini_path, monitor_preset))
        return 0

    die(2, "unknown subcommand '%s' (calc|create|version)" % cmd)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]) or 0)
