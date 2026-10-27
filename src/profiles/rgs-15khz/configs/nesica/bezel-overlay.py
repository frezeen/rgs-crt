#!/usr/bin/env python3
"""
Lightweight X11 side-bezel overlay for vertical arcade games on 4:3 CRT.
Draws pixel-perfect left and right bezel strips over black side pillars on :0.
"""

import sys
import os
import time
import signal
import ctypes
from PIL import Image

PID_FILE = "/tmp/bezel-overlay.pid"

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

CWOverrideRedirect = 1 << 9

def is_game_active(game_name):
    for pid in os.listdir("/proc"):
        if not pid.isdigit():
            continue
        try:
            with open(f"/proc/{pid}/cmdline", "rb") as f:
                c = f.read().decode("latin1", errors="ignore")
                if game_name.lower() in c.lower() and "bezel-overlay" not in c:
                    return int(pid)
        except (OSError, IOError):
            continue
    return None

def run_overlay(image_path, game_token, strip_w=None):
    # Wait up to 15 seconds for game process to appear
    game_pid = None
    for _ in range(30):
        game_pid = is_game_active(game_token)
        if game_pid:
            break
        time.sleep(0.5)

    if not game_pid:
        sys.exit(0)

    # Wait an extra second for game window to map on X11
    time.sleep(1.0)

    if not os.path.exists(image_path):
        sys.exit(0)

    try:
        im = Image.open(image_path).convert("RGBA")
    except Exception:
        sys.exit(0)

    x11 = ctypes.cdll.LoadLibrary("libX11.so.6")
    d = x11.XOpenDisplay(b":0")
    if not d:
        sys.exit(0)

    root = x11.XDefaultRootWindow(d)
    screen = x11.XDefaultScreen(d)
    visual = x11.XDefaultVisual(d, screen)
    depth = x11.XDefaultDepth(d, screen)

    W, H = im.size
    left_w = strip_w if (strip_w and strip_w > 0) else 114
    right_w = left_w
    right_x = W - right_w

    def create_strip(x, y, w, h, img_crop):
        attr = XSetWindowAttributes()
        attr.override_redirect = 1
        win = x11.XCreateWindow(
            d, root, x, y, w, h, 0,
            depth, 1, visual,
            CWOverrideRedirect, ctypes.byref(attr)
        )
        bgra = Image.new("RGBA", (w, h))
        bgra.paste(img_crop, (0, 0))
        r, g, b, a = bgra.split()
        bgrx = Image.merge("RGBA", (b, g, r, a)).tobytes()
        ximage = x11.XCreateImage(d, visual, depth, 2, 0, bgrx, w, h, 32, 0)
        gc = x11.XCreateGC(d, win, 0, None)
        x11.XMapRaised(d, win)
        x11.XPutImage(d, win, gc, ximage, 0, 0, 0, 0, w, h)
        x11.XFlush(d)
        return win, gc, ximage, bgrx

    w1 = create_strip(0, 0, left_w, H, im.crop((0, 0, left_w, H)))
    w2 = create_strip(right_x, 0, right_w, H, im.crop((right_x, 0, W, H)))

    # Main monitoring loop: keep connection alive and periodically raise strips
    running = True
    def sig_handler(signum, frame):
        nonlocal running
        running = False
    signal.signal(signal.SIGTERM, sig_handler)
    signal.signal(signal.SIGINT, sig_handler)

    while running:
        if not os.path.exists(f"/proc/{game_pid}"):
            break
        # Raise strips on top in case game re-presented
        x11.XRaiseWindow(d, w1[0])
        x11.XRaiseWindow(d, w2[0])
        x11.XFlush(d)
        time.sleep(0.5)

    x11.XDestroyWindow(d, w1[0])
    x11.XDestroyWindow(d, w2[0])
    x11.XCloseDisplay(d)
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

def start(image_path, game_token, strip_w=None):
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
        token = sys.argv[3] if len(sys.argv) > 3 else "Space Invaders"
        strip_w = int(sys.argv[4]) if len(sys.argv) > 4 else None
        start(img, token, strip_w)
