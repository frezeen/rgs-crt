#!/usr/bin/env python3
"""
Lightweight X11 side-bezel overlay for vertical arcade games on 4:3 CRT.
Draws pixel-perfect left and right bezel strips over black side pillars on :0.

The strips belong to the GAME'S WINDOW, so that window is the only oracle:
they appear with it and leave with it. Keyed on a process command line, the
daemon matched the emulator launcher — whose own argv carries the ROM name —
and mapped the cabinet art ~2 s after the [runtime] apply, while the
profile picker's last frame was still on the tube and no game window existed
yet (measured 2026-11-03): cabinet over the selector, and a daemon that outlived
its game did the same to the next picker. The rule is the display layer's
(src/engine/display/display-reconcile.sh): a viewable window that is not
EmulationStation's (by WINDOW CLASS, not pid) and is large — >= half the raster
or >= 640x480 — is the game; wine's helper windows (IME 1x1, 160x20, Input)
never qualify.
"""

import sys
import os
import time
import signal
import ctypes
from PIL import Image

PID_FILE = "/tmp/bezel-overlay.pid"

# The picker's caption (selector-ui.py). Our own full-screen window is not a
# game: a daemon that outlived its game must not read it as one and sit above it.
PICKER_TITLE = "CRT-DUAL Profile Selector"

# The launch budget the display layer already allows a game to put a picture up
# (display-reconcile.sh CRT_DUAL_SESSION_BUDGET): no window by then = no game.
WINDOW_WAIT = 120.0
# Absence of the game window ends the daemon: the display layer's 16 polls at
# 0.5 s (GONE_POLLS x POLL). Long enough for a title that recreates its window
# on an in-game mode switch; gameStop's undo ends the daemon at once anyway.
ABSENCE_GRACE = 8.0
# Pillar width when the profile names none (the shared overlay's default).
DEFAULT_STRIP_W = 114

IsViewable = 2

class XSetWindowAttributes(ctypes.Structure):
    _fields_ = [
        ("background_pixmap", ctypes.c_ulong),
        ("background_pixel", ctypes.c_ulong),
        ("border_pixmap", ctypes.c_ulong),
        ("border_pixel", ctypes.c_ulong),
        ("bit_gravity", ctypes.c_int),
        ("win_gravity", ctypes.c_int),
        ("backing_store", ctypes.c_int),
        ("backing_planes", ctypes.c_ulong),
        ("backing_pixel", ctypes.c_ulong),
        ("save_under", ctypes.c_int),
        ("event_mask", ctypes.c_long),
        ("do_not_propagate_mask", ctypes.c_long),
        ("override_redirect", ctypes.c_int),
        ("colormap", ctypes.c_ulong),
        ("cursor", ctypes.c_ulong),
    ]

class XWindowAttributes(ctypes.Structure):
    _fields_ = [
        ("x", ctypes.c_int),
        ("y", ctypes.c_int),
        ("width", ctypes.c_int),
        ("height", ctypes.c_int),
        ("border_width", ctypes.c_int),
        ("depth", ctypes.c_int),
        ("visual", ctypes.c_void_p),
        ("root", ctypes.c_ulong),
        ("class_", ctypes.c_int),
        ("bit_gravity", ctypes.c_int),
        ("win_gravity", ctypes.c_int),
        ("backing_store", ctypes.c_int),
        ("backing_planes", ctypes.c_ulong),
        ("backing_pixel", ctypes.c_ulong),
        ("save_under", ctypes.c_int),
        ("colormap", ctypes.c_ulong),
        ("map_installed", ctypes.c_int),
        ("map_state", ctypes.c_int),
        ("all_event_masks", ctypes.c_long),
        ("your_event_mask", ctypes.c_long),
        ("do_not_propagate_mask", ctypes.c_long),
        ("override_redirect", ctypes.c_int),
        ("screen", ctypes.c_void_p),
    ]

CWOverrideRedirect = 1 << 9


def open_display():
    """Open :0 with the prototypes this file uses (int is ctypes' default,
    pointers are not). Returns (lib, display) or (lib, None)."""
    x11 = ctypes.cdll.LoadLibrary("libX11.so.6")
    x11.XOpenDisplay.restype = ctypes.c_void_p
    x11.XDefaultRootWindow.restype = ctypes.c_ulong
    x11.XDefaultScreen.restype = ctypes.c_int
    x11.XDisplayWidth.restype = ctypes.c_int
    x11.XDisplayHeight.restype = ctypes.c_int
    x11.XDefaultVisual.restype = ctypes.c_void_p
    x11.XDefaultDepth.restype = ctypes.c_int
    return x11, x11.XOpenDisplay(b":0")


def window_class(x11, d, win):
    """WM_CLASS of a window, '' when it has none. The display layer tells
    EmulationStation apart by class, not by pid: its window is owned by the
    `emulationstation` process while the session launcher is its parent."""
    cls = ctypes.c_char_p()
    inst = ctypes.c_char_p()
    if not x11.XGetClassHint(ctypes.c_void_p(d), win, ctypes.byref(cls), ctypes.byref(inst)):
        return ""
    name = (cls.value or b"").decode("latin1")
    if cls:
        x11.XFree(cls)
    if inst:
        x11.XFree(inst)
    return name


def window_name(x11, d, win):
    """WM_NAME of a window, '' when it has none."""
    name = ctypes.c_char_p()
    if not x11.XFetchName(ctypes.c_void_p(d), win, ctypes.byref(name)):
        return ""
    out = (name.value or b"").decode("latin1")
    if name:
        x11.XFree(name)
    return out


def game_window(x11, d):
    """The game's window id, or None: a viewable window that is not
    EmulationStation's and is large (>= half the raster or >= 640x480).

    Top-level frames (openbox) carry no WM_CLASS, so the walk descends into
    them: the client window with a class is what qualifies."""
    root = x11.XDefaultRootWindow(ctypes.c_void_p(d))
    screen = x11.XDefaultScreen(ctypes.c_void_p(d))
    sw = x11.XDisplayWidth(ctypes.c_void_p(d), screen)
    sh = x11.XDisplayHeight(ctypes.c_void_p(d), screen)
    pending = [root]
    while pending:
        parent = pending.pop()
        r = ctypes.c_ulong()
        p = ctypes.c_ulong()
        kids = ctypes.POINTER(ctypes.c_ulong)()
        n = ctypes.c_uint()
        if not x11.XQueryTree(ctypes.c_void_p(d), parent, ctypes.byref(r),
                              ctypes.byref(p), ctypes.byref(kids), ctypes.byref(n)):
            continue
        for i in range(n.value):
            win = kids[i]
            pending.append(win)
            attrs = XWindowAttributes()
            if not x11.XGetWindowAttributes(ctypes.c_void_p(d), win, ctypes.byref(attrs)):
                continue
            if attrs.map_state != IsViewable:
                continue
            cls = window_class(x11, d, win)
            if not cls or cls == "emulationstation":
                continue
            if window_name(x11, d, win) == PICKER_TITLE:
                continue
            if attrs.width * attrs.height * 2 >= sw * sh \
                    or (attrs.width >= 640 and attrs.height >= 480) \
                    or (attrs.height >= 400 and attrs.width >= 240):
                if kids:
                    x11.XFree(kids)
                return win
        if kids:
            x11.XFree(kids)
    return None


def create_strip(x11, d, root, visual, depth, x, y, w, h, img_crop):
    attr = XSetWindowAttributes()
    attr.override_redirect = 1
    win = x11.XCreateWindow(ctypes.c_void_p(d), root, x, y, w, h, 0,
                            depth, 1, visual, CWOverrideRedirect, ctypes.byref(attr))
    bgra = Image.new("RGBA", (w, h))
    bgra.paste(img_crop, (0, 0))
    r, g, b, a = bgra.split()
    bgrx = Image.merge("RGBA", (b, g, r, a)).tobytes()
    ximage = x11.XCreateImage(ctypes.c_void_p(d), visual, depth, 2, 0, bgrx, w, h, 32, 0)
    gc = x11.XCreateGC(ctypes.c_void_p(d), win, 0, None)
    x11.XMapRaised(ctypes.c_void_p(d), win)
    x11.XPutImage(ctypes.c_void_p(d), win, gc, ximage, 0, 0, 0, 0, w, h)
    x11.XFlush(ctypes.c_void_p(d))
    return win, gc, ximage, bgrx


def process_with(token):
    """A pid whose cmdline carries the token, or None.

    This says WHICH title was launched, never whether it is on screen: the
    launcher's own argv names the ROM, so it is a scope, and the window is
    the liveness oracle."""
    for pid in os.listdir("/proc"):
        if not pid.isdigit():
            continue
        try:
            with open(f"/proc/{pid}/cmdline", "rb") as f:
                c = f.read().decode("latin1", errors="ignore")
        except OSError:
            continue
        if token.lower() in c.lower() and "bezel-overlay" not in c:
            return int(pid)
    return None


def run_overlay(image_path, game_token=None, strip_w=None):
    if not os.path.exists(image_path):
        sys.exit(0)
    try:
        im = Image.open(image_path).convert("RGBA")
    except Exception:
        sys.exit(0)

    x11, d = open_display()
    if not d:
        sys.exit(0)

    root = x11.XDefaultRootWindow(ctypes.c_void_p(d))
    screen = x11.XDefaultScreen(ctypes.c_void_p(d))
    visual = x11.XDefaultVisual(ctypes.c_void_p(d), screen)
    depth = x11.XDefaultDepth(ctypes.c_void_p(d), screen)

    W, H = im.size
    left_w = strip_w if (strip_w and strip_w > 0) else DEFAULT_STRIP_W
    right_x = W - left_w
    strips = []

    def draw():
        strips.append(create_strip(x11, d, root, visual, depth, 0, 0,
                                   left_w, H, im.crop((0, 0, left_w, H))))
        strips.append(create_strip(x11, d, root, visual, depth, right_x, 0,
                                   left_w, H, im.crop((right_x, 0, W, H))))

    def show():
        # Map + raise: the game presents over the strips when it redraws, and
        # the pillars must stay covered.
        for win, _gc, _ximage, _buf in strips:
            x11.XMapRaised(ctypes.c_void_p(d), win)
        x11.XFlush(ctypes.c_void_p(d))

    def hide():
        for win, _gc, _ximage, _buf in strips:
            x11.XUnmapWindow(ctypes.c_void_p(d), win)
        x11.XFlush(ctypes.c_void_p(d))

    running = True
    def sig_handler(signum, frame):
        nonlocal running
        running = False
    signal.signal(signal.SIGTERM, sig_handler)
    signal.signal(signal.SIGINT, sig_handler)

    started = time.time()
    seen_at = 0.0  # last moment the game's window was on screen; 0 = never yet
    while running:
        if game_token and process_with(game_token) is None:
            # The [runtime] block is per system, so this hook runs for every
            # game in it: a launch of another title is not ours. Leave nothing.
            if strips:
                hide()
            break
        if game_window(x11, d) is not None:
            if not strips:
                draw()
            show()
            seen_at = time.time()
        elif strips:
            # No game window, no cabinet: never over the picker, never over
            # the desktop waiting for the next launch.
            hide()
            if time.time() - seen_at > ABSENCE_GRACE:
                break
        elif time.time() - started > WINDOW_WAIT:
            break
        time.sleep(0.5)

    for win, _gc, _ximage, _buf in strips:
        x11.XDestroyWindow(ctypes.c_void_p(d), win)
    x11.XCloseDisplay(ctypes.c_void_p(d))
    if os.path.exists(PID_FILE):
        try:
            os.remove(PID_FILE)
        except OSError:
            pass


def stop():
    if os.path.exists(PID_FILE):
        try:
            with open(PID_FILE) as f:
                pid = int(f.read().strip())
            os.kill(pid, signal.SIGTERM)
        except Exception:
            pass
        try:
            os.remove(PID_FILE)
        except OSError:
            pass


def start(image_path, game_token=None, strip_w=None):
    if game_token and process_with(game_token) is None:
        sys.exit(0)
    stop()
    pid = os.fork()
    if pid > 0:
        # First parent exits immediately
        sys.exit(0)

    # First child: create new session
    os.setsid()

    # Second fork: ensure daemon cannot acquire a controlling terminal
    pid2 = os.fork()
    if pid2 > 0:
        with open(PID_FILE, "w") as f:
            f.write(str(pid2))
        os._exit(0)

    # Grandchild daemon: redirect std fds to /dev/null so parent subprocess pipes close
    try:
        devnull = os.open(os.devnull, os.O_RDWR)
        os.dup2(devnull, 0)
        os.dup2(devnull, 1)
        os.dup2(devnull, 2)
        if devnull > 2:
            os.close(devnull)
    except OSError:
        pass

    run_overlay(image_path, game_token, strip_w)


if __name__ == "__main__":
    if len(sys.argv) < 2:
        sys.exit(1)
    action = sys.argv[1]
    if action == "stop":
        stop()
    elif action == "start":
        img = sys.argv[2] if len(sys.argv) > 2 else ""
        game = sys.argv[3] if len(sys.argv) > 3 else None
        width = int(sys.argv[4]) if len(sys.argv) > 4 else None
        start(img, game, width)
