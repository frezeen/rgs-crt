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

The UI reads that file, draws one button per candidate (label +
description + countdown), maps input, and prints the chosen profile NAME
to stdout. It NEVER writes the state file /tmp/crt-dual/profile — the
single writer is first_script.sh only . The caller
(selector-core.sh) validates the choice against the candidate list.

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
import os
import re
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
HIGHLIGHT = (200, 180, 50)
DIM_WHITE = (255, 255, 255, 180)
OVERLAY = (0, 0, 0, 200)

OPTIONS_FILE = os.environ.get("CRT_DUAL_OPTIONS_FILE", "/tmp/crt-dual-profile-options")

# The picker runs inside `selector-core.sh ... 2>/dev/null` (first_script
# silences stderr), so input/selection problems were invisible — the only
# trace was the profile that ended up applied. Log every event and the
# final choice to a file (diagnosis 2026-08-10: the user selected
# 31khz-lcd in the picker but 15khz-crt was applied).
LOG_FILE = os.environ.get("CRT_DUAL_LOG_FILE", "/userdata/system/logs/selector.log")


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

    font_title = pygame.font.Font(None, 40)
    font_btn = pygame.font.Font(None, 28)
    font_small = pygame.font.Font(None, 20)

    joystick = None
    if pygame.joystick.get_count() > 0:
        try:
            joystick = pygame.joystick.Joystick(0)
            joystick.init()
        except Exception:
            joystick = None

    labels = [label_of(c) for c in candidates]
    selected = 0
    clock = pygame.time.Clock()
    start = pygame.time.get_ticks()

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

    def draw(remaining):
        w, h = screen.get_size()
        overlay = pygame.Surface((w, h), pygame.SRCALPHA)
        overlay.fill(OVERLAY)
        screen.blit(overlay, (0, 0))
        title = font_title.render("CRT-DUAL — Select profile", True, WHITE)
        screen.blit(title, title.get_rect(center=(w // 2, 44)))

        # vertical layout: one row per candidate (fits 640x480 CRT; the old
        # horizontal layout overflowed the screen width)
        btn_w = int(w * 0.86)
        btn_h = 86
        spacing = 18
        x0 = (w - btn_w) // 2
        total_h = len(candidates) * btn_h + (len(candidates) - 1) * spacing
        y0 = max(96, (h - total_h) // 2 + 24)
        for i, (label, desc) in enumerate(labels):
            rect = pygame.Rect(x0, y0 + i * (btn_h + spacing), btn_w, btn_h)
            if i == selected:
                pygame.draw.rect(screen, HIGHLIGHT, rect, border_radius=8)
                pygame.draw.rect(screen, WHITE, rect, 3, border_radius=8)
            else:
                pygame.draw.rect(screen, GRAY, rect, border_radius=8)
                pygame.draw.rect(screen, GRAY, rect, 1, border_radius=8)
            # label centered, description wrapped below (max 2 lines)
            t = font_btn.render(label, True, WHITE)
            screen.blit(t, t.get_rect(center=(rect.centerx, rect.y + 22)))
            desc_lines = wrap(desc, font_small, btn_w - 24)[:2]
            dy = rect.y + 44
            for dl in desc_lines:
                d = font_small.render(dl, True, DIM_WHITE)
                screen.blit(d, d.get_rect(center=(rect.centerx, dy)))
                dy += 20

        instr = font_small.render("up/down or stick: move    Enter / A: confirm", True, GRAY)
        screen.blit(instr, instr.get_rect(center=(w // 2, h - 56)))
        ttl = font_small.render(f"Default: {default}  in {max(0, remaining)}s", True, GRAY)
        screen.blit(ttl, ttl.get_rect(center=(w // 2, h - 32)))
        pygame.display.flip()

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
                if event.key in (pygame.K_UP,):
                    selected = (selected - 1) % len(candidates)
                elif event.key in (pygame.K_DOWN,):
                    selected = (selected + 1) % len(candidates)
                elif event.key in (pygame.K_LEFT,):
                    selected = (selected - 1) % len(candidates)
                elif event.key in (pygame.K_RIGHT,):
                    selected = (selected + 1) % len(candidates)
                elif event.key in (pygame.K_RETURN, pygame.K_SPACE):
                    log_event(f"confirm KEYDOWN selected={selected} -> {candidates[selected]}")
                    print(candidates[selected])
                    return 0
            if event.type == pygame.JOYAXISMOTION and event.axis == 1:
                if event.value < -0.3:
                    selected = (selected - 1) % len(candidates)
                elif event.value > 0.3:
                    selected = (selected + 1) % len(candidates)
            elif event.type == pygame.JOYAXISMOTION and event.axis == 0:
                # legacy: the old cabinet stick responded to axis 0 only
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

        screen.fill(BLACK)
        draw(remaining)
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
        try:
            import pygame
            pygame.quit()
        except Exception:
            pass
    sys.exit(rc)
