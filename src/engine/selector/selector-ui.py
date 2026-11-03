#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0
# Copyright (C) 2026 FreZeeN
# Part of crt-dual — https://github.com/frezeen
"""selector-ui.py — CRT-DUAL: thin pygame render+input for the profile picker.

The selector is TWO parts. This is
the UI ONLY — render + input. The DECISION (which displays are confirmed,
which profiles participate, what the default is) lives in selector-core.sh
and is passed here via /tmp/crt-dual-profile-options:

    # candidates for selector-ui.py (one per line)
    <profile-name>
    <profile-name>
    # default
    <default-profile-name>

The UI reads that file, draws one PANEL per candidate — the profile's own
picture above its name and description, with a large up-arrow under the
selected one (the arrow IS the selection indicator) and the countdown — maps
input, and prints the chosen profile NAME to stdout. The pictures are
transparent PNGs composited on the picker's black background, so the tube
shows the object and nothing else; they live in assets/ next to this file
and a candidate without one still gets a text-only panel.

It NEVER writes the state file /tmp/crt-dual/profile — the single writer is
first_script.sh only . The caller (selector-core.sh) validates the choice
against the candidate list.

Input mapping is EXPLICIT for the arcade cabinet (lessons from the old
repo): left/right = joystick axis 0 (the cabinet stick did not respond
to axis Y), plus hat (dpad), keyboard arrows, Enter and gamepad button.

Fallback (corrected lesson): on pygame init failure the core has ALREADY
decided — this UI prints the default (a choice the core made for the
display present, NEVER "CRT always").

Timeout -> the default from the options file (display present).

Exit codes: 0 with the chosen profile name on stdout (or the default),
1 on hard failure (caller falls back to its own default).
"""
import contextlib
import math
import os
import sys

# pygame prints its support banner to STDOUT on import unless this env
# var is set. The core captures stdout as the chosen profile
# (_chosen="$(python3 selector-ui.py)"), so the banner corrupted the
# choice and the picker always fell back to the default (diagnosis
# 2026-08-10, selector.log: 'confirm -> 31khz-lcd' then core
# 'picker failed/timeout'). Set it before any pygame import.
os.environ["PYGAME_HIDE_SUPPORT_PROMPT"] = "1"

TIMEOUT = 10  # seconds; timeout -> default of the display present

BLACK = (0, 0, 0)
WHITE = (255, 255, 255)
GRAY = (120, 120, 120)
HIGHLIGHT = (255, 196, 32)
DIM_WHITE = (255, 255, 255, 180)
OVERLAY = (0, 0, 0, 200)

OPTIONS_FILE = os.environ.get("CRT_DUAL_OPTIONS_FILE", "/tmp/crt-dual-profile-options")
ASSET_DIR = os.environ.get(
    "CRT_DUAL_ASSET_DIR",
    os.path.join(os.path.dirname(os.path.abspath(__file__)), "assets"))

# What each candidate looks like in the picker: (name, description, picture).
# Keyed by profile name; a profile absent here keeps its spec.conf
# label/description and gets no picture — the picker stays N-profile.
PRESENTATION = {
    "rgs-15khz": ("CRT", "4:3 CRT 15 kHz", "crt.png"),
    "rgs-stock": ("LCD", "modern LCD/TV 16:9 high definition", "lcd.png"),
}

# The picker runs inside `selector-core.sh ... 2>/dev/null` (first_script
# silences stderr), so input/selection problems were invisible — the only
# trace was the profile that ended up applied. Log every event and the
# final choice to a file (diagnosis 2026-08-10: the user selected
# 31khz-lcd in the picker but 15khz-crt was applied).
LOG_FILE = os.environ.get("CRT_DUAL_LOG_FILE", "/userdata/system/logs/selector.log")


def clear_screen() -> None:
    """Hand the tube back black before the window goes away.

    Nothing repaints the raster between this window's destruction and the
    game's window: EmulationStation is blocked in the launch, and X leaves the
    destroyed window's pixels in place (background None). The picker's last
    frame therefore stayed on the glass — under the profile's bezel strips,
    which map seconds before the game presents (measured 2026-11-03). The
    screen this UI painted is the screen it must leave clean."""
    with contextlib.suppress(Exception):
        import pygame
        surface = pygame.display.get_surface()
        if surface is not None:
            surface.fill(BLACK)
            pygame.display.flip()


def log_event(msg: str) -> None:
    """Append a timestamped line to LOG_FILE (best-effort, never raises)."""
    with contextlib.suppress(Exception):
        import time
        with open(LOG_FILE, "a") as f:
            f.write(f"{time.strftime('%Y-%m-%d %H:%M:%S')} {msg}\n")


def read_options():
    """Parse the options file -> (candidates, default). Candidates = list
    of profile names in display order; default = the core's choice."""
    candidates = []
    default = None
    reading_default = False
    with contextlib.suppress(Exception):
        with open(OPTIONS_FILE) as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                if line == "# default":
                    reading_default = True
                    continue
                if line.startswith("#"):
                    continue
                if reading_default:
                    default = line
                    break
                candidates.append(line)
    return candidates, default


def label_of(candidate):
    """Read the profile's label/description from spec.conf (best-effort)."""
    pkg = os.environ.get("CRT_DUAL_PKG_ROOT", "/userdata/system/crt-dual")
    spec = f"{pkg}/profiles/{candidate}/spec.conf"
    label, desc = candidate, ""
    with contextlib.suppress(Exception):
        for line in open(spec, errors="replace"):
            line = line.strip()
            if line.startswith("label") and "=" in line:
                label = line.split("=", 1)[1].strip()
            elif line.startswith("description") and "=" in line:
                desc = line.split("=", 1)[1].strip()
    return label, desc


def entry_of(candidate):
    """-> (name, description, picture path or None) for one candidate."""
    if candidate in PRESENTATION:
        name, desc, picture = PRESENTATION[candidate]
        return name, desc, os.path.join(ASSET_DIR, picture)
    label, desc = label_of(candidate)
    return label, desc, None


def prepare_art(path, box_w, box_h):
    """Load the profile picture and fit it inside box_w x box_h, aspect kept.
    -> Surface or None (a missing picture is a text-only panel, never a crash)."""
    if not path:
        return None
    try:
        import pygame
        image = pygame.image.load(path).convert_alpha()
    except Exception:
        log_event(f"art unavailable: {path}")
        return None
    sw, sh = image.get_size()
    k = min(box_w / sw, box_h / sh)
    return pygame.transform.smoothscale(
        image, (max(1, int(sw * k)), max(1, int(sh * k))))


def wrap(text, font, maxw):
    """Wrap text to fit maxw pixels, breaking on words."""
    words = text.split()
    if not words:
        return [""]
    lines, cur = [], words[0]
    for w in words[1:]:
        trial = cur + " " + w
        if font.size(trial)[0] <= maxw:
            cur = trial
        else:
            lines.append(cur)
            cur = w
    lines.append(cur)
    return lines


def draw(screen, fonts, art, arrow, entries, selected, remaining, default,
         elapsed=0.0):
    """One frame: a picture panel per candidate, the arrow under the chosen."""
    import pygame
    font_title, font_name, font_desc, font_small = fonts
    w, h = screen.get_size()
    screen.fill(BLACK)

    title = font_title.render("CRT-DUAL — Select profile", True, WHITE)
    screen.blit(title, title.get_rect(center=(w // 2, int(h * 0.075))))

    margin = int(w * 0.045)
    gap = int(w * 0.035)
    panel_w = (w - 2 * margin - gap) // 2
    img_top = int(h * 0.105)
    img_h = int(h * 0.49)

    for i, (name, desc, _path) in enumerate(entries):
        left = margin + i * (panel_w + gap)
        cx = left + panel_w // 2
        chosen = i == selected

        picture = art[i]
        if picture is not None:
            rect = picture.get_rect(center=(cx, img_top + img_h // 2))
            if not chosen:
                # the unselected cabinet/TV steps back: same art, dimmed
                picture = picture.copy()
                picture.fill((140, 140, 140, 255), special_flags=pygame.BLEND_RGBA_MULT)
            screen.blit(picture, rect)

        ny = img_top + img_h + int(h * 0.035)
        t = font_name.render(name, True, WHITE if chosen else GRAY)
        screen.blit(t, t.get_rect(center=(cx, ny)))
        dy = ny + int(h * 0.055)
        for line in wrap(desc, font_desc, panel_w)[:2]:
            d = font_desc.render(line, True, WHITE if chosen else GRAY)
            screen.blit(d, d.get_rect(center=(cx, dy)))
            dy += int(h * 0.045)

        if chosen and arrow is not None:
            # the selection indicator: the arrow sits under the chosen panel
            # and points up at it (its own art, transparent, on the black)
            # ...and bobs up and down, so the eye lands on the chosen panel
            bob = math.sin(elapsed * 4.0) * (h * 0.018)
            rect = arrow.get_rect(
                center=(cx, int(h * 0.735 + bob) + arrow.get_height() // 2))
            screen.blit(arrow, rect)

    instr = font_small.render("left/right or stick: move    Enter / A: confirm",
                              True, GRAY)
    screen.blit(instr, instr.get_rect(center=(w // 2, int(h * 0.925))))
    ttl = font_small.render(f"Default: {default}  in {max(0, remaining)}s", True, GRAY)
    screen.blit(ttl, ttl.get_rect(center=(w // 2, int(h * 0.965))))
    pygame.display.flip()


def main():
    candidates, default = read_options()
    log_event(f"options: candidates={candidates} default={default}")
    if not candidates:
        print(default or "")
        return 0
    if default is None:
        default = candidates[0]

    # pygame is only reached when the core found a REAL choice (gate table)
    try:
        import pygame
    except Exception:
        log_event("pygame import failed — core default")
        print(default)  # corrected lesson: fallback = core's default, never "CRT always"
        return 0

    try:
        os.environ["SDL_VIDEO_DRIVER"] = "x11"
        pygame.display.init()
        pygame.font.init()
        pygame.joystick.init()
        info = pygame.display.Info()
        # NOFRAME overlay — no modeset, no CRTC reprogram, 0G on dce_v6 (FULLSCREEN blips even when mode already 640)
        screen = pygame.display.set_mode(
            (info.current_w, info.current_h), pygame.NOFRAME)
        pygame.display.set_caption("CRT-DUAL Profile Selector")
        pygame.event.set_grab(True)
        pygame.key.set_repeat(300, 100)
    except Exception:
        import traceback
        log_event("pygame init failed:\n" + traceback.format_exc())
        print(default)
        return 0

    log_event(f"pygame ok: display {info.current_w}x{info.current_h} "
              f"joysticks={pygame.joystick.get_count()}")

    # fonts scale with the raster: 640x480 on the tube, 1080p on the panel
    scale = info.current_h / 480.0
    fonts = (pygame.font.Font(None, max(18, int(40 * scale))),
             pygame.font.Font(None, max(16, int(32 * scale))),
             pygame.font.Font(None, max(14, int(22 * scale))),
             pygame.font.Font(None, max(12, int(20 * scale))))

    joystick = None
    if pygame.joystick.get_count() > 0:
        try:
            joystick = pygame.joystick.Joystick(0)
            joystick.init()
        except Exception:
            joystick = None

    entries = [entry_of(c) for c in candidates]
    panel_w = (info.current_w - 2 * int(info.current_w * 0.045)
               - int(info.current_w * 0.035)) // 2
    box = (panel_w, int(info.current_h * 0.49))
    art = [prepare_art(path, *box) for (_n, _d, path) in entries]
    arrow = prepare_art(os.path.join(ASSET_DIR, "arrow.png"),
                        int(panel_w * 0.40), int(info.current_h * 0.13))
    log_event(f"panels: {[(e[0], bool(a)) for e, a in zip(entries, art)]}")

    selected = 0
    clock = pygame.time.Clock()
    start = pygame.time.get_ticks()

    running = True
    while running:
        elapsed = (pygame.time.get_ticks() - start) / 1000
        remaining = max(0, TIMEOUT - int(elapsed))
        if remaining <= 0:
            running = False
            break

        for event in pygame.event.get():
            log_event(f"event: type={event.type} {event.dict}")
            if event.type == pygame.QUIT:
                running = False
                break
            if event.type == pygame.KEYDOWN:
                if event.key in (pygame.K_UP, pygame.K_LEFT):
                    selected = (selected - 1) % len(candidates)
                elif event.key in (pygame.K_DOWN, pygame.K_RIGHT):
                    selected = (selected + 1) % len(candidates)
                elif event.key in (pygame.K_RETURN, pygame.K_SPACE):
                    log_event(f"confirm KEYDOWN selected={selected} -> {candidates[selected]}")
                    print(candidates[selected])
                    return 0
            if event.type == pygame.JOYAXISMOTION and event.axis in (0, 1):
                # axis 1 = current cabinet stick; axis 0 = legacy stick
                if event.value < -0.3:
                    selected = (selected - 1) % len(candidates)
                elif event.value > 0.3:
                    selected = (selected + 1) % len(candidates)
            if event.type == pygame.JOYHATMOTION:
                if event.value[1] < 0:
                    selected = (selected - 1) % len(candidates)
                elif event.value[1] > 0:
                    selected = (selected + 1) % len(candidates)
                elif event.value[0] < 0:
                    selected = (selected - 1) % len(candidates)
                elif event.value[0] > 0:
                    selected = (selected + 1) % len(candidates)
            if event.type == pygame.JOYBUTTONDOWN:
                # any button confirms (the cabinet's confirm button is not
                # necessarily button 0 — diagnosis 2026-08-10); the log
                # records which one was used.
                log_event(f"confirm JOYBUTTON button={event.button} selected={selected} -> {candidates[selected]}")
                print(candidates[selected])
                return 0

        draw(screen, fonts, art, arrow, entries, selected, remaining, default,
             elapsed)
        clock.tick(30)

    log_event(f"timeout — default {default}")
    print(default)
    return 0


if __name__ == "__main__":
    try:
        rc = main()
    except Exception:
        import traceback
        log_event("EXCEPTION:\n" + traceback.format_exc())
        sys.stdout.write(os.environ.get("CRT_DUAL_FALLBACK", ""))
        rc = 0
    finally:
        clear_screen()
        try:
            import pygame
            pygame.quit()
        except Exception:
            pass
    sys.exit(rc)
