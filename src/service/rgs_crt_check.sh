#!/bin/bash
# rgs_crt_check.sh — the rgs-crt check tool (ES-launchable: it appears in
# the "Batocera config" menu next to the RGS scripts; the +rgs system
# maps /userdata/roms/rgs with extension .sh).
#
# WHAT THE USER SEES (effect only): a full-screen verdict window —
# placement is ES's job (the tool launches through the same chain as any
# game; no screen-selection logic here) — GREEN "all aligned, everything
# ok" with the release line, or RED with choices:
# ESC = exit (games keep running stock-safe), ENTER = uninstall the layer
# and reboot (pure stock RGS). When the feed reports a newer release the
# layer on this box is certified for, ENTER offers the update instead (U
# still uninstalls on RED). The update/uninstall is DELIBERATE here: the
# user launched this tool, no game is launching, nothing can race.
#
# ALL the logic lives in the ONE service (zz_rgs_15khz tool-check /
# feed-check / tool-update / tool-uninstall): this file is UI only. PASS
# also restores held profiles and adopts the version (service side).
#
# Test seams: RGS15_SVCDIR (+ the service seams for tool-check/feed-check/
# tool-update/tool-uninstall; RGS15_PKG + RGS15_RGS_VERSION_FILE for the
# release line).
set -u
SVC="${RGS15_SVCDIR:-/userdata/system/services}/zz_rgs_15khz"
export RGS15_SVC_PATH="$SVC"
[ -f "$SVC" ] || { echo "rgs-crt is not installed" >&2; exit 1; }

_verdict="$(bash "$SVC" tool-check 2>/dev/null)"
[ "$_verdict" = "GREEN" ] || _verdict="RED"

# Feed state (thin glue: the service owns the check, we parse the first
# word only). Empty/garbage => OFFLINE (today's screens, fail-safe).
# RGS15_FEED_ALLOW_NET=1 opts this box into the network fetch; without it
# the service answers OFFLINE (hermetic seams, offline-safe default).
_feed_line="$(RGS15_FEED_ALLOW_NET=1 bash "$SVC" feed-check 2>/dev/null || true)"
_feed="${_feed_line%% *}"
case "$_feed" in
UPDATE | BLOCKED | CURRENT | OFFLINE) ;;
*) _feed="OFFLINE" ;;
esac
_feed_ver="$(printf '%s' "$_feed_line" | cut -d' ' -f2 -s)"
[ -n "$_feed_ver" ] || _feed_ver="unknown"

# Release line (same seams + defaults as the service, display only).
_PKG="${RGS15_PKG:-/userdata/system/crt-dual}"
_installed="$(tr -d ' \t\r\n' <"$_PKG.version" 2>/dev/null || true)"
[ -n "$_installed" ] || _installed="unknown"
_live_rgs="$(tr -d ' \t\r\n' <"${RGS15_RGS_VERSION_FILE:-/userdata/system/rgs.version}" 2>/dev/null || true)"
[ -n "$_live_rgs" ] || _live_rgs="unknown"
_rel_row="release $_installed  ·  certified on RGS $_live_rgs"
if [ "$_feed" = "UPDATE" ]; then
	_upd_row="update available: $_feed_ver"
	_offer="UPDATE"
else
	_upd_row="up to date"
	_offer=""
fi

# The pygame block prints the user's choice (empty = no action). If it
# cannot draw or crashes, stdout stays empty — no update/uninstall ever
# runs on a failed UI (fail-safe direction, see service tool-uninstall).
_choice="$(DISPLAY="${DISPLAY:-:0.0}" python3 - "$_verdict" "$_offer" "$_rel_row" "$_upd_row" <<'PYEOF' 2>/dev/null
import sys
import pygame

verdict = sys.argv[1] if len(sys.argv) > 1 else "RED"
offer = sys.argv[2] if len(sys.argv) > 2 else ""
rel_row = sys.argv[3] if len(sys.argv) > 3 else ""
upd_row = sys.argv[4] if len(sys.argv) > 4 else ""

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
    if offer == "UPDATE":
        rows = [
            (rel_row, f_body, white),
            (upd_row, f_body, acc),
            ("", f_body, white),
            ("ENTER = update", f_pick, acc),
            ("ESC = close", f_pick, acc),
        ]
    else:
        rows = [
            (rel_row, f_body, white),
            (upd_row, f_body, white),
            ("", f_body, white),
            ("Press any key to close.", f_body, dim),
        ]
else:
    band_col, acc = (168, 32, 32), (230, 200, 60)
    title = "RGS-CRT — RED: NOT CERTIFIED"
    if offer == "UPDATE":
        rows = [
            ("The RGS system was updated and the rgs-crt layer could not be re-verified.", f_body, white),
            ("Games run stock-safe meanwhile.", f_body, white),
            ("", f_body, white),
            (upd_row, f_body, acc),
            ("", f_body, white),
            ("ENTER = update", f_pick, acc),
            ("U = uninstall rgs-crt and reboot into stock RGS", f_pick, acc),
            ("ESC = exit and keep playing stock", f_pick, acc),
        ]
    else:
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
            elif verdict == "GREEN" and offer == "UPDATE" \
                    and ev.key in (pygame.K_RETURN, pygame.K_KP_ENTER):
                result.append("update")
                running = False
            elif verdict == "GREEN":
                running = False
            elif offer == "UPDATE":
                if ev.key in (pygame.K_RETURN, pygame.K_KP_ENTER):
                    result.append("update")
                    running = False
                elif ev.key == pygame.K_u:
                    result.append("uninstall")
                    running = False
            elif ev.key in (pygame.K_RETURN, pygame.K_KP_ENTER, pygame.K_u):
                result.append("uninstall")
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

if [ "$_choice" = "update" ]; then
	bash "$SVC" tool-update
elif [ "$_choice" = "uninstall" ]; then
	bash "$SVC" tool-uninstall
fi
exit 0
