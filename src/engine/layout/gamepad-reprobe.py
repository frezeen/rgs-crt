#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0
# Copyright (C) 2026 FreZeeN
# Part of crt-dual — https://github.com/frezeen
"""
gamepad-reprobe.py — CRT-DUAL: gamepad-triggered manual hotplug re-probe.

Watches ANY gamepad evdev device (auto-detected: standard pads emit BTN_*
gamepad codes; arcade encoders are normalized to a pad by the user's
driver) and, on a configurable button combo, touches the manual hotplug
trigger file (/tmp/crt-dual/hotplug-trigger). The layout watcher picks
the trigger up and re-detects + force-applies the layout (the manual
channel, watcher section 1b).

Why this exists: on AMD dce_v6 the periodic forced probe glitches the lit
CRT in dual, so it is DISABLED (manual mode). The analog unplug/plug is
caught by this MANUAL trigger instead — a deliberate, rare user action.

UNIVERSAL + NON-GRABBING:
  - auto-detects every gamepad (any /dev/input/event* exposing gamepad
    BTN_* codes + ABS axes; excludes keyboards/mice/power), so it works
    on any pad or arcade encoder on any box.
  - opens devices O_RDONLY|O_NONBLOCK without EVIOCGRAB, so it only
    OBSERVES — ES/RetroArch keep full control of the same device.
  - python-evdev when present (correct capability parse); raw-struct
    fallback reading /proc/bus/input/devices when it is not (stock box).

Combo: hold the modifier, then press the action key. Defaults to
Select + L1 (BTN_SELECT + BTN_TL = 314 + 310). Remappable via the
batocera.conf knob `crt-dual.hotplug_combo=MOD+KEY` (evdev codes,
decimal or 0x hex; the LAST occurrence wins — batocera-settings
appends), falling back to the env seam CRT_DUAL_TRIGGER_MOD/KEY. The
combo is idle-only by construction on the watcher side (the trigger is
consumed/deferred by the watcher's game guard).
"""

import contextlib
import os, sys, time, struct, glob
from select import select

STATE_DIR = os.environ.get("CRT_DUAL_STATE_DIR", "/tmp/crt-dual")
TRIGGER   = os.path.join(STATE_DIR, "hotplug-trigger")
COMBO_WINDOW = 2.0   # hold Select + press L1 within this window = trigger
DEBOUNCE     = 1.0   # min seconds between triggers

# evdev codes (Linux input-event-codes.h)
EV_KEY      = 0x01
BTN_SELECT  = 0x13a  # 314  Select/Back (combo modifier, held)
BTN_TL      = 0x136  # 310  L1 (combo action)

# Configurable combo; precedence: batocera.conf knob > env seam > default.
# Values are evdev codes, decimal or 0x hex:
#   crt-dual.hotplug_combo=MOD+KEY in batocera.conf (engine-owned knob)
#   CRT_DUAL_TRIGGER_MOD / CRT_DUAL_TRIGGER_KEY (env, tests/service)
#   default Select+L1 = 314 + 310
def _env_int(name, default):
    v = os.environ.get(name)
    try:
        return int(v, 0) if v is not None else default
    except ValueError:
        return default

CONF_PATH = os.environ.get("CRT_DUAL_CONF", "/userdata/system/batocera.conf")


def _combo_from_conf():
    """(mod, key) from the LAST crt-dual.hotplug_combo line, or None.

    batocera-settings-set APPENDS, so the last occurrence is the effective
    value (same semantics as the rest of the layer)."""
    try:
        with open(CONF_PATH, "r", encoding="utf-8", errors="replace") as f:
            hits = [ln.strip() for ln in f if ln.startswith("crt-dual.hotplug_combo")]
    except OSError:
        return None
    if not hits:
        return None
    raw = hits[-1].split("=", 1)[-1].strip().strip("\"'")
    if "+" not in raw:
        return None
    mod_s, key_s = raw.split("+", 1)
    try:
        return int(mod_s.strip(), 0), int(key_s.strip(), 0)
    except ValueError:
        return None


def _resolve_combo():
    env_pair = (_env_int("CRT_DUAL_TRIGGER_MOD", BTN_SELECT),
                _env_int("CRT_DUAL_TRIGGER_KEY", BTN_TL))
    return _combo_from_conf() or env_pair


TRIGGER_MOD, TRIGGER_KEY = _resolve_combo()

GAMEPAD_BTN_RANGE = range(0x130, 0x140)  # BTN_SOUTH..BTN_DPAD_RIGHT
ABS_RANGE        = range(0x00, 0x40)

FMT  = "llHHI"
SIZE = struct.calcsize(FMT)


# ── device detection ────────────────────────────────────────────────────

def _bits_of(words):
    bits = set()
    for wi, w in enumerate(words.split()):
        try:
            v = int(w, 16)
        except ValueError:
            continue
        for b in range(64):
            if v & (1 << b):
                bits.add(wi * 64 + b)
    return bits


def _has_pyb_evdev():
    try:
        import evdev  # noqa
        return True
    except ImportError:
        return False


def detect_gamepads():
    """Return gamepad /dev/input/event* paths (physical + uinput)."""
    if _has_pyb_evdev():
        import evdev
        pads = []
        try:
            paths = evdev.list_devices()
        except Exception:
            paths = []
        for p in paths:
            try:
                d = evdev.InputDevice(p)
                caps = d.capabilities(verbose=True)
                keys = set()
                for names, code in caps.get(("EV_KEY", 1), {}):
                    keys.add(code)
                has_game_btn = bool(keys & set(GAMEPAD_BTN_RANGE))
                has_abs = ("EV_ABS", 3) in caps
            except Exception:
                continue
            if has_game_btn and has_abs:
                pads.append(p)
        return pads

    # Fallback: raw /proc/bus/input/devices parse (no python-evdev).
    pads = []
    try:
        dev = open("/proc/bus/input/devices").read()
    except Exception:
        return pads
    for blk in dev.split("\n\n"):
        name = key = absb = hand = ""
        for line in blk.split("\n"):
            l = line.strip()
            if l.startswith("N:"):
                name = l.split('"')[1]
            elif l.startswith("H:"):
                hand = l
            elif l.startswith("B: KEY="):
                key = l[8:]
            elif l.startswith("B: ABS="):
                absb = l[8:]
        if not name or "event" not in hand:
            continue
        kb = _bits_of(key)
        has_game_btn = bool(kb & set(GAMEPAD_BTN_RANGE))
        has_abs = bool(_bits_of(absb) & set(ABS_RANGE))
        if has_game_btn and has_abs:
            ev = [t for t in hand.split() if t.startswith("event")]
            if ev:
                pads.append("/dev/input/" + ev[0])
    return pads


# ── raw-struct reader (fallback path) ───────────────────────────────────

def _safe_dev_path(p):
    """Return p only if it is a real /dev/input event device (constrains the
    open()/os.open() path to the kernel's event interface — the only place these
    device paths legitimately come from; never user-supplied)."""
    try:
        rp = os.path.realpath(p)
    except Exception:
        return None
    if rp.startswith("/dev/input/") and os.path.basename(rp).startswith("event"):
        return rp
    return None


def _safe_trigger_path():
    """Resolve the trigger path strictly inside the runtime state dir, refusing
    any STATE_DIR that escapes /tmp (defense-in-depth: the env is fixed by the
    service; never user-supplied)."""
    base = os.path.realpath(STATE_DIR)
    if not base.startswith("/tmp"):
        return None
    return os.path.join(base, "hotplug-trigger")


def run_raw(pads):
    fds = {}
    for p in pads:
        sp = _safe_dev_path(p)
        if not sp:
            continue
        with contextlib.suppress(Exception):
            fds[os.open(sp, os.O_RDONLY | os.O_NONBLOCK)] = sp
    if not fds:
        sys.stderr.write("gamepad-reprobe: could not open gamepad\n")
        return 2
    combo = Combo()
    while True:
        r, _, _ = select(list(fds), [], [], 0.3)
        for fd in r:
            try:
                data = os.read(fd, SIZE)
            except (BlockingIOError, OSError):
                continue
            if len(data) != SIZE:
                continue
            _s, _n, typ, code, val = struct.unpack(FMT, data)
            if typ != EV_KEY:
                continue
            combo.feed(code, val)


def _trigger():
    trig = _safe_trigger_path()
    if not trig:
        sys.stderr.write("gamepad-reprobe: refusing unsafe trigger path\n")
        return
    try:
        os.makedirs(os.path.dirname(trig), exist_ok=True)
        open(trig, "w").close()
        sys.stderr.write("gamepad-reprobe: combo -> hotplug trigger\n")
    except Exception as e:
        sys.stderr.write("gamepad-reprobe: %s\n" % e)


class Combo:
    """Modifier-held + action-key state machine, shared by BOTH read paths
    (raw-struct and evdev). val: 1 press, 0 release; repeat values are
    ignored, so a held modifier is never dropped by an autorepeat."""

    def __init__(self):
        self.held = set()
        self.last = 0.0

    def feed(self, code, val):
        if code == TRIGGER_MOD:
            if val == 1:
                self.held.add(code)
            elif val == 0:
                self.held.discard(code)
        elif code == TRIGGER_KEY and val == 1 and TRIGGER_MOD in self.held:
            now = time.time()
            if now - self.last > DEBOUNCE:
                self.last = now
                _trigger()


def main():
    # The gamepad may not be up yet at boot (the arcade-encoder driver
    # normalizes to a uinput pad a moment later) — retry detection for a
    # while before giving up.
    pads = []
    for _ in range(10):
        pads = detect_gamepads()
        if pads:
            break
        select([], [], [], 1.0)   # poll wait (no fixed sleep) — retry cadence
    if not pads:
        sys.stderr.write("gamepad-reprobe: no gamepad device found\n")
        return 2
    sys.stderr.write("gamepad-reprobe: watching %s\n" % ",".join(pads))

    if _has_pyb_evdev():
        import evdev
        devs = []
        for p in pads:
            sp = _safe_dev_path(p)
            if not sp:
                continue
            with contextlib.suppress(Exception):
                devs.append(evdev.InputDevice(sp))
        if not devs:
            return run_raw(pads)
        combo = Combo()
        while True:
            r, _, _ = select(devs, [], [], 0.3)
            for dev in r:
                for ev in dev.read():
                    if ev.type != EV_KEY:
                        continue
                    combo.feed(ev.code, ev.value)
    else:
        return run_raw(pads)
    return 0


if __name__ == "__main__":
    sys.exit(main())
