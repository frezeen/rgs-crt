#!/bin/bash
# rgs_crt_check.sh — the rgs-crt check tool (ES-launchable: it appears in
# the "Batocera config" menu next to the RGS scripts; the +rgs system
# maps /userdata/roms/rgs with extension .sh).
#
# WHAT THE USER SEES (effect only): a full-screen verdict window —
# placement is ES's job (the tool launches through the same chain as any
# game; no screen-selection logic here) — GREEN "all aligned, everything
# ok", or RED with two choices:
# ESC = exit (games keep running stock-safe), ENTER = uninstall the layer
# and reboot (pure stock RGS). The uninstall is DELIBERATE here: the user
# launched this tool, no game is launching, nothing can race.
#
# ALL the logic lives in the ONE service (zz_rgs_15khz tool-check /
# tool-uninstall): this file is UI only. PASS also restores held profiles
# and adopts the version (service side).
#
# Update feed (download a newer rgs-crt automatically): DEFERRED until
# the project repo goes public (ROADMAP phase 14) — this tool is written
# so the feed check slots into the RED screen.
#
# Test seams: RGS15_SVCDIR (+ the service seams for tool-check/tool-uninstall).
set -u
SVC="${RGS15_SVCDIR:-/userdata/system/services}/zz_rgs_15khz"
export RGS15_SVC_PATH="$SVC"
[ -f "$SVC" ] || { echo "rgs-crt is not installed" >&2; exit 1; }

_verdict="$(bash "$SVC" tool-check 2>/dev/null)"
[ "$_verdict" = "GREEN" ] || _verdict="RED"

# The pygame block prints the user's choice (empty = no action). If it
# cannot draw or crashes, stdout stays empty — no uninstall ever runs on
# a failed UI (fail-safe direction, see service tool-uninstall).
_choice="$(DISPLAY="${DISPLAY:-:0.0}" python3 - "$_verdict" <<'PYEOF' 2>/dev/null
import os
import subprocess
import sys
import pygame

verdict = sys.argv[1] if len(sys.argv) > 1 else "RED"

pygame.init()
clock = pygame.time.Clock()
scr = pygame.display.set_mode((0, 0), pygame.FULLSCREEN)
pygame.display.set_caption("rgs-crt")
w, h = scr.get_size()
fs = max(14, int(h * 0.042))
margin = int(w * 0.07)
maxw = w - 2 * margin

f_title = pygame.font.SysFont("dejavusans", int(fs * 1.35), bold=True)
f_body = pygame.font.SysFont("dejavusans", fs)
f_pick = pygame.font.SysFont("dejavusans", int(fs * 1.1), bold=True)

def wrap(fnt, text):
    if fnt.size(text)[0] <= maxw or not text:
        return [text]
    words, out, cur = text.split(), [], ""
    for wd in words:
        t = (cur + " " + wd).strip()
        if fnt.size(t)[0] <= maxw:
            cur = t
        else:
            out.append(cur)
            cur = wd
    out.append(cur)
    return out

white, dim = (245, 245, 245), (168, 172, 180)
if verdict == "GREEN":
    band_col, acc = (30, 96, 40), (120, 220, 140)
    title = "RGS-CRT — EVERYTHING ALIGNED"
    rows = [
        ("The layer is certified on this RGS version.", f_body, white),
        ("", f_body, white),
        ("Press any key to close.", f_body, dim),
    ]
else:
    band_col, acc = (168, 32, 32), (230, 200, 60)
    title = "RGS-CRT — RED: NOT CERTIFIED"
    rows = [
        ("The RGS system was updated and the rgs-crt layer could not be re-verified.", f_body, white),
        ("Games run stock-safe meanwhile.", f_body, white),
        ("", f_body, white),
        ("ESC = exit and keep playing stock", f_pick, acc),
        ("ENTER = uninstall rgs-crt and reboot into stock RGS", f_pick, acc),
    ]

result = []
running = True
while running:
    for ev in pygame.event.get():
        if ev.type == pygame.QUIT:
            running = False
        elif ev.type == pygame.KEYDOWN:
            if ev.key == pygame.K_ESCAPE:
                running = False
            elif verdict == "RED" and ev.key in (pygame.K_RETURN, pygame.K_KP_ENTER, pygame.K_u):
                result.append("uninstall")
                running = False
            elif verdict == "GREEN":
                running = False
    scr.fill((12, 12, 16))
    band_h = int(h * 0.14)
    pygame.draw.rect(scr, band_col, (0, 0, w, band_h))
    pygame.draw.rect(scr, band_col, (0, h - 4, w, 4))
    t = f_title.render(title, True, white)
    scr.blit(t, (w // 2 - t.get_width() // 2, band_h // 2 - t.get_height() // 2))
    ty = int(h * 0.24)
    for txt, fnt, col in rows:
        for piece in wrap(fnt, txt):
            s2 = fnt.render(piece, True, col)
            scr.blit(s2, (margin, ty))
            ty += int(fs * 1.45)
            if ty > h - band_h:
                break
    hint = f_pick.render("ESC = exit" if verdict == "GREEN" else "choose with the keyboard", True, dim)
    scr.blit(hint, (w // 2 - hint.get_width() // 2, h - int(h * 0.06) - hint.get_height() // 2))
    pygame.display.flip()
    clock.tick(10)
pygame.quit()
print(result[0] if result else "")
PYEOF
)"

if [ "$_choice" = "uninstall" ]; then
	bash "$SVC" tool-uninstall
fi
exit 0
