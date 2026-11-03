#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0
# Copyright (C) 2026 FreZeeN
# Part of crt-dual — https://github.com/frezeen
# dotclock-measure.py — measure the video chain's real dotclock floor at BOOT.
#
# WHY THIS EXISTS (2026-09-20, Intel PCH incident): a mode can be ACCEPTED
# by the kernel and still never scan — on Haswell's PCH the analog output
# cannot clock below ~10.4 MHz (the ICLKIP divider is 7-bit): the mode
# shows as active in xrandr while the pipe produces no vblanks and every
# page flip times out (launch/exit stalls). The only honest oracle is
# BEHAVIOURAL: after setting a mode, does the CRTC actually produce
# vblanks? That is what this tool asks, via the DRM WAIT_VBLANK ioctl —
# no hardcoded limit, no vendor table, works on any GPU.
#
# WHEN: pre-X, from the S30z boot hook (after the splash released the
# display, before X/ES and the stock resolution logic). Never during a
# session: it takes the DRM master and changes modes.
#
# WHAT: tests the desktop anchor (640x480i — known good by construction)
# first, then walks the native-geometry candidates DESCENDING (highest
# dotclock first). The first rung with no vblanks is the boundary: the
# walk stops there and the lowest rung that DID produce vblanks is the
# chain's floor (== the anchor when everything below it fails, e.g. the
# Intel PCH). The floor is deliberately the LOWEST WORKING rung — the
# official CRT guidance (Rion, Batocera #6162) is dotclock_min = the
# lowest value the chain accepts, tested by hand (start 8, lower while it
# works); Switchres then derives its dynamic super-widths from it, so a
# lower floor means LESS widening and a more native picture, with the
# game's exact refresh untouched (integer horizontal scaling only). WHY DESCENDING (measured 2026-09-20): a rung below the
# chain's limit kills the pipe (lpt_program_iclkip falls back to a bogus
# clock) and the KERNEL then pays 4x10 s flip_done/commit waits on that
# CRTC — top-down costs exactly ONE such commit, the LAST set, and no
# modeset follows it. After a failing rung the restore is therefore
# skipped on purpose (another modeset would only wait for the same kernel
# timeouts); X/ES re-modesets at boot and recovers the display. A clean
# run (no failing rung) restores the pre-measurement CRTC state.
#
# OUTPUT: the floor in MHz on stdout (one line, e.g. "10.39"); the walk
# narrative on stderr. Loud failures, no fallback.
#
# Modes:
#   --read-state   read-only diagnostics (no master, no modeset): the CRT
#                  connector -> CRTC mapping + a vblank wait on the mode
#                  currently scanning (safe with X running)
#   --dry-run      print the candidate plan (clocks) and exit; no DRM
#   (default)      the full measurement (needs the DRM master)
#
# Env seams (tests): CRT_DUAL_DRM_DEV, CRT_DUAL_SYSFS, CRT_DUAL_SR_INI,
# CRT_DUAL_SR_PRESET, CRT_DUAL_MEASURE_TIMEOUT (vblank wait seconds).
import ctypes
import fcntl
import mmap
import os
import re
import signal
import struct
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
DRM_DEV = os.environ.get("CRT_DUAL_DRM_DEV", "/dev/dri/card0")
SYSFS = os.environ.get("CRT_DUAL_SYSFS", "/sys/class/drm")
SR_INI = os.environ.get("CRT_DUAL_SR_INI", "/etc/switchres.ini")
SR_PRESET = os.environ.get("CRT_DUAL_SR_PRESET", "")
HINT_INI = os.environ.get("CRT_DUAL_HINT_INI",
                          "/userdata/system/configs/retroarch/switchres.ini")
VBLANK_TIMEOUT = float(os.environ.get("CRT_DUAL_MEASURE_TIMEOUT", "1.0"))
DETECT = os.path.join(HERE, "..", "display", "display-detect.sh")

# ── DRM uapi (ioctls + structs; the kernel is the contract) ──────────────
def _iowr(nr, size):
    return (3 << 30) | (size << 16) | (ord("d") << 8) | nr


def _io(nr):
    """DRM_IO(nr) — no direction, no size (SET_MASTER/DROP_MASTER).

    The DRM dispatcher checks type+nr+SIZE: a size mismatch returns EINVAL
    as if the ioctl did not exist (verified on the box 2026-09-20: _IO(0x1e)
    -> EBUSY with X master; the wrong 0x1d -> EINVAL).
    """
    return (ord("d") << 8) | nr


class Resources(ctypes.Structure):
    _fields_ = [
        ("fb_id_ptr", ctypes.c_uint64), ("crtc_id_ptr", ctypes.c_uint64),
        ("connector_id_ptr", ctypes.c_uint64), ("encoder_id_ptr", ctypes.c_uint64),
        ("count_fbs", ctypes.c_uint32), ("count_crtcs", ctypes.c_uint32),
        ("count_connectors", ctypes.c_uint32), ("count_encoders", ctypes.c_uint32),
        ("min_width", ctypes.c_uint32), ("max_width", ctypes.c_uint32),
        ("min_height", ctypes.c_uint32), ("max_height", ctypes.c_uint32),
    ]


class ModeInfo(ctypes.Structure):
    _fields_ = [
        ("clock", ctypes.c_uint32),
        ("hdisplay", ctypes.c_uint16), ("hsync_start", ctypes.c_uint16),
        ("hsync_end", ctypes.c_uint16), ("htotal", ctypes.c_uint16),
        ("hskew", ctypes.c_uint16),
        ("vdisplay", ctypes.c_uint16), ("vsync_start", ctypes.c_uint16),
        ("vsync_end", ctypes.c_uint16), ("vtotal", ctypes.c_uint16),
        ("vscan", ctypes.c_uint16),
        ("vrefresh", ctypes.c_uint32), ("flags", ctypes.c_uint32),
        ("type", ctypes.c_uint32), ("name", ctypes.c_char * 32),
    ]


class Crtc(ctypes.Structure):
    _fields_ = [
        ("set_connectors_ptr", ctypes.c_uint64), ("count_connectors", ctypes.c_uint32),
        ("crtc_id", ctypes.c_uint32), ("fb_id", ctypes.c_uint32),
        ("x", ctypes.c_uint32), ("y", ctypes.c_uint32),
        ("gamma_size", ctypes.c_uint32), ("mode_valid", ctypes.c_uint32),
        ("mode", ModeInfo),
    ]


class Connector(ctypes.Structure):
    _fields_ = [
        ("encoders_ptr", ctypes.c_uint64), ("modes_ptr", ctypes.c_uint64),
        ("props_ptr", ctypes.c_uint64), ("prop_values_ptr", ctypes.c_uint64),
        ("count_modes", ctypes.c_uint32), ("count_props", ctypes.c_uint32),
        ("count_encoders", ctypes.c_uint32), ("encoder_id", ctypes.c_uint32),
        ("connector_id", ctypes.c_uint32), ("connector_type", ctypes.c_uint32),
        ("connector_type_id", ctypes.c_uint32),
        ("mm_width", ctypes.c_uint32), ("mm_height", ctypes.c_uint32),
        ("subpixel", ctypes.c_uint32), ("pad", ctypes.c_uint32),
    ]


class Encoder(ctypes.Structure):
    _fields_ = [
        ("encoder_id", ctypes.c_uint32), ("encoder_type", ctypes.c_uint32),
        ("crtc_id", ctypes.c_uint32), ("possible_crtcs", ctypes.c_uint32),
        ("possible_clones", ctypes.c_uint32),
    ]


class CreateDumb(ctypes.Structure):
    _fields_ = [
        ("height", ctypes.c_uint32), ("width", ctypes.c_uint32),
        ("bpp", ctypes.c_uint32), ("flags", ctypes.c_uint32),
        ("handle", ctypes.c_uint32), ("pitch", ctypes.c_uint32),
        ("size", ctypes.c_uint64),
    ]


class MapDumb(ctypes.Structure):
    _fields_ = [("handle", ctypes.c_uint32), ("pad", ctypes.c_uint32),
                ("offset", ctypes.c_uint64)]


class FbCmd(ctypes.Structure):
    _fields_ = [
        ("fb_id", ctypes.c_uint32), ("width", ctypes.c_uint32),
        ("height", ctypes.c_uint32), ("pitch", ctypes.c_uint32),
        ("bpp", ctypes.c_uint32), ("depth", ctypes.c_uint32),
        ("handle", ctypes.c_uint32),
    ]


class VblankReq(ctypes.Structure):
    _fields_ = [("type", ctypes.c_uint32), ("sequence", ctypes.c_uint32),
                ("signal", ctypes.c_ulong)]


class VblankRep(ctypes.Structure):
    _fields_ = [("type", ctypes.c_uint32), ("sequence", ctypes.c_uint32),
                ("tval_sec", ctypes.c_long), ("tval_usec", ctypes.c_long)]


class Vblank(ctypes.Union):
    _fields_ = [("request", VblankReq), ("reply", VblankRep)]


GETRES = _iowr(0xA0, ctypes.sizeof(Resources))
GETCRTC = _iowr(0xA1, ctypes.sizeof(Crtc))
GETENCODER = _iowr(0xA6, ctypes.sizeof(Encoder))
GETCONNECTOR = _iowr(0xA7, ctypes.sizeof(Connector))
SETCRTC = _iowr(0xA2, ctypes.sizeof(Crtc))
GETFB = _iowr(0xAD, ctypes.sizeof(FbCmd))
CREATE_DUMB = _iowr(0xB2, ctypes.sizeof(CreateDumb))
MAP_DUMB = _iowr(0xB3, ctypes.sizeof(MapDumb))
DESTROY_DUMB = _iowr(0xB4, ctypes.sizeof(ctypes.c_uint32))
ADDFB = _iowr(0xAE, ctypes.sizeof(FbCmd))
RMFB = _iowr(0xAF, ctypes.sizeof(ctypes.c_uint32))
WAIT_VBLANK = _iowr(0x3A, ctypes.sizeof(Vblank))
SET_MASTER = _io(0x1E)
DROP_MASTER = _io(0x1F)

# drm_mode_modeinfo flags
F_PHSYNC, F_NHSYNC, F_PVSYNC, F_NVSYNC, F_INTERLACE, F_DBLSCAN = 1, 2, 4, 8, 16, 32

_libc = ctypes.CDLL("libc.so.6", use_errno=True)


def _ioctl(fd, req, obj=None):
    if obj is None:
        ret = _libc.ioctl(fd, ctypes.c_ulong(req), 0)
    else:
        ret = _libc.ioctl(fd, ctypes.c_ulong(req), ctypes.byref(obj))
    if ret < 0:
        err = ctypes.get_errno()
        raise OSError(err, os.strerror(err))
    return ret


def log(msg):
    print("DOTCLOCK-MEASURE [%s]: %s" % (time.strftime("%H:%M:%S"), msg),
          file=sys.stderr, flush=True)


def die(code, msg):
    log(msg)
    sys.exit(code)


# ── resources / mapping ─────────────────────────────────────────────────
def drm_resources(fd):
    res = Resources()
    _ioctl(fd, GETRES, res)
    nf, nc, nn, ne = res.count_fbs, res.count_crtcs, res.count_connectors, res.count_encoders
    fbs = (ctypes.c_uint32 * nf)()
    crtcs = (ctypes.c_uint32 * nc)()
    conns = (ctypes.c_uint32 * nn)()
    encs = (ctypes.c_uint32 * ne)()
    res.fb_id_ptr = ctypes.addressof(fbs)
    res.crtc_id_ptr = ctypes.addressof(crtcs)
    res.connector_id_ptr = ctypes.addressof(conns)
    res.encoder_id_ptr = ctypes.addressof(encs)
    _ioctl(fd, GETRES, res)
    return {
        "crtcs": [crtcs[i] for i in range(nc)],
        "connectors": [conns[i] for i in range(nn)],
        "encoders": [encs[i] for i in range(ne)],
    }


def drm_connector(fd, cid):
    c = Connector()
    c.connector_id = cid
    _ioctl(fd, GETCONNECTOR, c)
    return c


def drm_encoder(fd, eid):
    e = Encoder()
    e.encoder_id = eid
    _ioctl(fd, GETENCODER, e)
    return e


def drm_crtc(fd, cid):
    c = Crtc()
    c.crtc_id = cid
    _ioctl(fd, GETCRTC, c)
    return c


def crt_connector_name():
    """The CRT output from the display layer's own classification (pre-X
    safe: display-detect reads DRM sysfs, no X)."""
    out = subprocess.run(["bash", DETECT, "--list"], capture_output=True, text=True,
                         env={**os.environ, "CRT_DUAL_SYSFS": SYSFS})
    for line in out.stdout.splitlines():
        parts = line.split("\t")
        if len(parts) >= 3 and parts[1] == "analog":
            return parts[0]
    return None


def resolve_crt(fd, name):
    """DRM name (VGA-1/DP-1/...) -> (connector_id, crtc_id, crtc_index)."""
    m = re.match(r"^([A-Za-z-]+)-(\d+)$", name)
    if not m:
        die(3, "unparsable connector name '%s'" % name)
    base, idx = m.group(1), int(m.group(2))
    type_map = {"VGA": 1, "DVI-I": 3, "DVI-D": 4, "DVI-A": 5, "HDMI-A": 11, "DP": 10}
    ctype = type_map.get(base)
    if ctype is None:
        die(3, "unknown connector type in '%s'" % name)
    res = drm_resources(fd)
    for cid in res["connectors"]:
        c = drm_connector(fd, cid)
        if c.connector_type == ctype and c.connector_type_id == idx:
            crtc_id, crtc_idx = 0, None
            if c.encoder_id:
                crtc_id = drm_encoder(fd, c.encoder_id).crtc_id
            if not crtc_id:
                # encoder-less: first CRTC the encoders can drive
                for eid in res["encoders"]:
                    e = drm_encoder(fd, eid)
                    if e.crtc_id:
                        crtc_id = e.crtc_id
                        break
            if crtc_id:
                for i, x in enumerate(res["crtcs"]):
                    if x == crtc_id:
                        crtc_idx = i
            return cid, crtc_id, crtc_idx
    die(3, "connector '%s' not found in DRM resources" % name)


def wait_vblank(fd, crtc_idx, timeout):
    """True when a vblank arrives within `timeout` seconds. The ioctl is
    interruptible: SIGALRM aborts the wait (a dead pipe never answers)."""
    def _alarm(_sig, _frm):
        raise TimeoutError

    v = Vblank()
    v.request.type = 0x01 | (crtc_idx << 1)  # RELATIVE, this CRTC
    v.request.sequence = 1
    old = signal.signal(signal.SIGALRM, _alarm)
    signal.setitimer(signal.ITIMER_REAL, timeout)
    try:
        _ioctl(fd, WAIT_VBLANK, v)
        return True
    except (TimeoutError, OSError):
        return False
    finally:
        signal.setitimer(signal.ITIMER_REAL, 0)
        signal.signal(signal.SIGALRM, old)


# ── mode computation (the stock switchres library, same math as runtime) ─
def sr_mode(width, height, refresh):
    sys.path.insert(0, os.path.join(HERE, "..", "api"))
    import switchres_api as sr  # the layer's own ctypes bridge
    lib, _ = sr.load_library()
    with sr._stdout_to_stderr():
        try:
            sr.init_dummy_session(lib, SR_INI, SR_PRESET or None)
            mode = sr.SrMode()
            ok = lib.sr_add_mode(ctypes.c_int(width), ctypes.c_int(height),
                                 ctypes.c_double(float(refresh)),
                                 ctypes.c_int(sr.SR_MODE_DONT_FLUSH),
                                 ctypes.byref(mode))
            if not ok or mode.width == 0:
                return None
            return mode
        finally:
            lib.sr_deinit()


def to_drm_mode(sr, label):
    mi = ModeInfo()
    mi.clock = int(sr.pclock // 1000)  # kHz
    mi.hdisplay = sr.width
    mi.hsync_start = sr.hbegin
    mi.hsync_end = sr.hend
    mi.htotal = sr.htotal
    mi.vdisplay = sr.height
    mi.vsync_start = sr.vbegin
    mi.vsync_end = sr.vend
    mi.vtotal = sr.vtotal
    mi.vrefresh = int(round(sr.vfreq))
    mi.flags = (F_PHSYNC if sr.hsync > 0 else F_NHSYNC) | \
               (F_PVSYNC if sr.vsync > 0 else F_NVSYNC) | \
               (F_INTERLACE if sr.interlace else 0) | \
               (F_DBLSCAN if sr.doublescan else 0)
    mi.name = label.encode()[:31]
    return mi


CANDIDATES = [(224, 224), (256, 224), (256, 240), (320, 240), (384, 288),
              # 544x240 -> 11.06 MHz: the fine rung between the PCH-class
              # limit (~10.39 MHz) and the anchor. Without it the floor
              # jumps 8.15 -> 13.04 and a 320-wide game widens x4
              # (1280x224 @25.97); with it the floor is 11.06 and the same
              # game widens x2 (640x224 @12.99) — less widening, more
              # native picture, same exact refresh.
              (544, 240)]


def build_plan(refresh):
    """Ladder of native geometries (ascending dotclock) + the desktop
    anchor LAST (640x480i, known good by construction on every supported
    chain). Candidates at or above the anchor's clock are useless rungs
    (the switchres library collapses some geometries onto the same
    interlaced container) — dropped; equal clocks are deduped."""
    anchor_sr = sr_mode(640, 480, refresh)
    plan = []
    seen = set()
    for w, h in CANDIDATES:
        m = sr_mode(w, h, refresh)
        if m is None:
            log("%dx%d@%s: switchres produced no modeline — skipped" % (w, h, refresh))
            continue
        if anchor_sr is not None and m.pclock >= anchor_sr.pclock:
            log("%dx%d@%s: %.2f MHz is at/above the anchor — rung dropped"
                % (w, h, refresh, m.pclock / 1e6))
            continue
        key = m.pclock
        if key in seen:
            log("%dx%d@%s: same %.2f MHz as an earlier rung — deduped"
                % (w, h, refresh, m.pclock / 1e6))
            continue
        seen.add(key)
        plan.append({"w": w, "h": h, "sr": m, "mhz": m.pclock / 1e6,
                     "label": "RGS15M_%dx%d" % (w, h)})
    plan.sort(key=lambda c: c["mhz"])
    if anchor_sr is not None:
        plan.append({"w": 640, "h": 480, "sr": anchor_sr,
                     "mhz": anchor_sr.pclock / 1e6, "label": "RGS15M_640x480i"})
    return plan


# ── modeset plumbing ────────────────────────────────────────────────────
def create_fb(fd, w, h):
    dumb = CreateDumb(height=h, width=w, bpp=32, flags=0)
    _ioctl(fd, CREATE_DUMB, dumb)
    mp = MapDumb(handle=dumb.handle)
    _ioctl(fd, MAP_DUMB, mp)
    mm = mmap.mmap(fd, dumb.size, mmap.MAP_SHARED, mmap.PROT_READ | mmap.PROT_WRITE,
                   offset=mp.offset)
    fb = FbCmd(width=w, height=h, pitch=dumb.pitch, bpp=32, depth=24, handle=dumb.handle)
    _ioctl(fd, ADDFB, fb)
    return dumb, mm, fb.fb_id


def fb_covers(fd, fb_id, plan):
    """True when the CRTC's existing framebuffer is big enough for every
    mode in the plan.

    Using the CRTC's OWN fb means this tool creates no fb: on a failing
    rung the kernel would otherwise disable the in-use dumb fb when the fd
    closes and pay its flip/commit timeouts AGAIN (measured 2026-09-20:
    six extra 10 s waits after the failing commit — 70 s total boot cost
    instead of ~11 s).
    """
    fb = FbCmd()
    fb.fb_id = fb_id
    try:
        _ioctl(fd, GETFB, fb)
    except OSError:
        return False
    need_w = max(c["sr"].width for c in plan)
    need_h = max(c["sr"].height for c in plan)
    return fb.width >= need_w and fb.height >= need_h


def read_hint():
    """The previous boot's floor, from the RA override (the only switchres
    ini that survives reboots; the system one is volatile by design).
    0.0 when absent/unreadable."""
    try:
        with open(HINT_INI, "r", errors="replace") as fh:
            for line in fh:
                parts = line.split()
                if len(parts) >= 2 and parts[0] == "dotclock_min":
                    return float(parts[1])
    except (OSError, ValueError):
        pass
    return 0.0


def hint_rung(plan, hint):
    """The ladder rung to verify for `hint` (closest clock), or None when
    there is no hint / the anchor already is the closest."""
    if hint <= 0:
        return None
    best = min(plan, key=lambda c: abs(c["mhz"] - hint))
    return None if best is plan[-1] else best


def try_rung(fd, crtc_id, fb_id, cid, crtc_idx, cand):
    """Set one rung and ask the oracle: True when it produces vblanks."""
    label = "%dx%d%s" % (cand["w"], cand["h"],
                         "i" if cand["sr"].interlace else "")
    try:
        set_mode(fd, crtc_id, fb_id, cid,
                 to_drm_mode(cand["sr"], cand["label"]))
        ok = wait_vblank(fd, crtc_idx, VBLANK_TIMEOUT)
    except OSError as e:
        log("%.2f MHz (%s): SETCRTC refused (%s)" % (cand["mhz"], label, e))
        return False
    log("%.2f MHz (%s): %s" % (cand["mhz"], label,
                               "vblank OK" if ok else
                               "NO vblank — below the chain limit"))
    return ok


def descend(fd, crtc_id, fb_id, cid, crtc_idx, rungs, floor):
    """Test `rungs` highest-first, stop at the first failure (the boundary
    costs the kernel's flip timeouts; nothing follows it). (floor, stalled)."""
    for cand in reversed(rungs):
        if try_rung(fd, crtc_id, fb_id, cid, crtc_idx, cand):
            floor = cand
        else:
            return floor, True
    return floor, False


def set_mode(fd, crtc_id, fb_id, connector_id, mi):
    c = Crtc()
    c.crtc_id = crtc_id
    c.fb_id = fb_id
    c.mode_valid = 1
    c.mode = mi
    conns = (ctypes.c_uint32 * 1)(connector_id)
    c.set_connectors_ptr = ctypes.addressof(conns)
    c.count_connectors = 1
    _ioctl(fd, SETCRTC, c)


def restore(fd, crtc_id, saved):
    c = Crtc()
    c.crtc_id = crtc_id
    c.fb_id = saved["fb_id"]
    c.mode_valid = saved["mode_valid"]
    c.mode = saved["mode"]
    conns_list = list(saved["connectors"])
    if saved["mode_valid"] and not conns_list:
        # GETCRTC can report an EMPTY connector list (observed on the
        # fbcon CRTC, 2026-09-20): a modeset with zero connectors is
        # EINVAL, and this path crashed the clean hint run and zeroed
        # the measured floor. Fall back to the connector this
        # measurement runs on — the one the CRTC was driving.
        conns_list = [saved["fallback"]]
    if conns_list:
        conns = (ctypes.c_uint32 * len(conns_list))(*conns_list)
        c.set_connectors_ptr = ctypes.addressof(conns)
        c.count_connectors = len(conns_list)
    _ioctl(fd, SETCRTC, c)


def main(argv):
    refresh = os.environ.get("CRT_DUAL_REFRESH", "60")
    if "--dry-run" in argv:
        plan = build_plan(refresh)
        for c in plan:
            print("%.2f MHz  %dx%d%s" % (c["mhz"], c["w"], c["h"],
                                         "i" if c["sr"].interlace else ""))
        return 0

    if "--plan" in argv:
        # Pure decision preview (no DRM): what would the walk do with the
        # hint currently stored in the RA override?
        plan = build_plan(refresh)
        hint = 0.0 if "--full" in argv else read_hint()
        hr = hint_rung(plan, hint)
        print("hint=%.1f" % hint)
        if hr is None:
            print("verify: anchor + full descent (no usable hint)")
        else:
            print("verify: anchor + rung %.2f MHz (%dx%d%s); rungs below "
                  "skipped" % (hr["mhz"], hr["w"], hr["h"],
                               "i" if hr["sr"].interlace else ""))
        return 0

    name = crt_connector_name()
    if not name:
        die(4, "no analog connected connector (CRT) — nothing to measure")

    if "--read-state" in argv:
        fd = os.open(DRM_DEV, os.O_RDWR)
        try:
            cid, crtc_id, crtc_idx = resolve_crt(fd, name)
            c = drm_crtc(fd, crtc_id)
            print("crt=%s connector_id=%d crtc_id=%d crtc_idx=%s active=%s "
                  "mode=%dx%d@%d clock=%dkHz" % (
                      name, cid, crtc_id, crtc_idx, bool(c.mode_valid),
                      c.mode.hdisplay, c.mode.vdisplay, c.mode.vrefresh, c.mode.clock))
            if crtc_idx is not None and c.mode_valid:
                t0 = time.time()
                ok = wait_vblank(fd, crtc_idx, VBLANK_TIMEOUT)
                print("vblank: %s in %.1fms" % ("YES" if ok else "NO",
                                                (time.time() - t0) * 1000))
            return 0
        finally:
            os.close(fd)

    # ── the measurement (boot only: takes the DRM master) ──
    try:
        return measure(refresh, name, full_scan="--full" in argv)
    except SystemExit:
        raise
    except Exception:
        import traceback
        log("MEASUREMENT FAILED (unexpected exception):")
        for _line in traceback.format_exc().splitlines():
            log("  %s" % _line)
        return 9


def measure(refresh, name, full_scan=False):
    plan = build_plan(refresh)
    if not plan:
        die(5, "no candidates (switchres produced nothing)")
    log("step: opening %s" % DRM_DEV)
    fd = os.open(DRM_DEV, os.O_RDWR)
    try:
        try:
            _ioctl(fd, SET_MASTER)
        except OSError as e:
            die(6, "cannot take the DRM master (%s) — another client owns the "
                   "display (EBUSY) or the ioctl was refused; measurement "
                   "skipped" % e)
        log("step: DRM master taken")
        cid, crtc_id, crtc_idx = resolve_crt(fd, name)
        if crtc_idx is None:
            die(7, "CRT connector %s has no CRTC" % name)
        log("step: crt %s -> connector %d crtc %d (index %s)"
            % (name, cid, crtc_id, crtc_idx))
        saved_c = drm_crtc(fd, crtc_id)
        saved_conns = []
        if saved_c.count_connectors:
            arr = (ctypes.c_uint32 * saved_c.count_connectors)()
            ctypes.memmove(arr, saved_c.set_connectors_ptr,
                           ctypes.sizeof(arr))
            saved_conns = [arr[i] for i in range(saved_c.count_connectors)]
        saved = {"fb_id": saved_c.fb_id, "mode_valid": saved_c.mode_valid,
                 "mode": saved_c.mode, "connectors": saved_conns,
                 "fallback": cid}
        log("step: saved crtc state (fb=%d mode_valid=%d mode=%dx%d connectors=%s)"
            % (saved_c.fb_id, saved_c.mode_valid, saved_c.mode.hdisplay,
               saved_c.mode.vdisplay, saved_conns))
        own_fb = None
        if saved_c.fb_id and fb_covers(fd, saved_c.fb_id, plan):
            fb_id = saved_c.fb_id
            log("step: using the CRTC's own fb %d (no dumb fb — a failing "
                "rung then costs only its own commit, not the kernel's "
                "in-use fb teardown)" % fb_id)
        else:
            dumb, mm, fb_id = create_fb(fd, 1024, 768)
            own_fb = (dumb, mm)
            log("step: dumb fb created (id=%d pitch=%d size=%d)"
                % (fb_id, dumb.pitch, dumb.size))
        floor = None
        stalled = False
        try:
            anchor = plan[-1]
            # The anchor (640x480i = the boot desktop) is known good by
            # construction: it validates the oracle AND leaves the pipe in
            # a healthy state before anything else.
            log("walk: anchor %.2f MHz first" % anchor["mhz"])
            set_mode(fd, crtc_id, fb_id, cid,
                     to_drm_mode(anchor["sr"], anchor["label"]))
            if not wait_vblank(fd, crtc_idx, VBLANK_TIMEOUT):
                die(8, "even the desktop anchor shows no vblanks — the "
                       "chain cannot scan 15 kHz at all")
            log("%.2f MHz (640x480i): vblank OK (anchor)" % anchor["mhz"])
            floor = anchor
            # WHY DESCENDING (measured 2026-09-20, Intel PCH): a rung below
            # the chain's limit makes lpt_program_iclkip fall back to a
            # bogus clock, the pipe stops producing vblanks and the KERNEL
            # then pays ~40 s of flip_done/commit waits (the failed set +
            # the fbdev restore on fd close). Testing top-down costs exactly
            # ONE such rung — the LAST set — and no modeset follows it.
            #
            # HINT FAST PATH: the RA override carries the previous boot's
            # floor across reboots. Verify the closest rung to it; if it
            # scans, the chain is unchanged and the floor holds (rungs
            # below are NOT re-tested: they would cost the same ~40 s).
            # If it fails, the chain degraded: re-walk the rungs ABOVE the
            # hint only (a lower clock can never work when a higher one
            # does not — that is what a minimum dotclock means).
            hint = 0.0 if full_scan else read_hint()
            hr = hint_rung(plan, hint)
            if hr is not None:
                log("hint: last floor %.1f MHz -> verifying the closest rung "
                    "%.2f MHz" % (hint, hr["mhz"]))
                if try_rung(fd, crtc_id, fb_id, cid, crtc_idx, hr):
                    floor = hr
                    log("hint verified: floor %.2f MHz (fast path; --full "
                        "re-walks everything)" % hr["mhz"])
                else:
                    stalled = True
                    log("hint FAILED: chain degraded — descending only the "
                        "rungs above %.2f MHz" % hr["mhz"])
                    above = [c for c in plan[:-1] if c["mhz"] > hr["mhz"]]
                    floor, _ = descend(fd, crtc_id, fb_id, cid, crtc_idx,
                                       above, floor)
            else:
                floor, stalled = descend(fd, crtc_id, fb_id, cid, crtc_idx,
                                         plan[:-1], floor)
        finally:
            if stalled:
                log("step: restore skipped — the pipe is stalled by the "
                    "failing set; the next modeset (X at boot) recovers it.")
                if own_fb:
                    own_fb[1].close()
            else:
                log("step: restoring the pre-measurement crtc state")
                restore(fd, crtc_id, saved)
                if own_fb:
                    _ioctl(fd, RMFB, ctypes.c_uint32(fb_id))
                    _ioctl(fd, DESTROY_DUMB, ctypes.c_uint32(own_fb[0].handle))
                    own_fb[1].close()
        print("%.2f" % floor["mhz"])
        return 0
    finally:
        try:
            _ioctl(fd, DROP_MASTER)
        except OSError:
            pass
        os.close(fd)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
