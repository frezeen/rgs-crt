#!/bin/bash
# rgs_crt_check.sh — the rgs-crt check tool (ES-launchable: it appears in
# the "Batocera config" menu next to the RGS scripts; the +rgs system
# maps /userdata/roms/rgs with extension .sh).
#
# WHAT THE USER SEES (effect only): a full-screen window that stays open
# WHILE the layer checks itself, streaming each step as it happens
# ("checking new version", "found", "download", "install", "certify",
# "all green and certified") and then the verdict — GREEN "all green and
# certified, version <v>", or RED with what went wrong. ESC = exit
# (games keep running stock-safe); on RED, U = uninstall the layer and
# reboot into pure stock RGS.
#
# THE FLOW IS AUTOMATIC (owner decision 2026-10-11): opening this tool IS
# the update — no keypress. The service `tool-update` checks the feed,
# installs a newer release certified for this RGS through get.sh,
# re-certifies, and on an all-green certify the version rises to the RGS
# it just certified. NOTHING reboots in that flow: an update installs in
# place and the user restarts by hand when RGS says so. The only action a
# key can still cause is the DELIBERATE uninstall (user-launched, no game
# launching, nothing can race).
#
# ALL the logic lives in the ONE service (zz_rgs_15khz tool-update /
# tool-uninstall): this file is glue. The flow runs in THIS shell (so the
# seam observes it) and its live steps reach the window through the
# service log; the window (pygame) is owner-live-tested. A window that
# cannot draw, or crashes, prints no choice — so it can never uninstall
# anything.
#
# Test seams: RGS15_SVCDIR (+ the service seams for tool-update /
# tool-uninstall; RGS15_PKG + RGS15_RGS_VERSION_FILE for the release
# line; RGS15_LOG for the live steps + the loud error the RED window
# shows).
set -u
SVC="${RGS15_SVCDIR:-/userdata/system/services}/zz_rgs_15khz"
export RGS15_SVC_PATH="$SVC"
[ -f "$SVC" ] || { echo "rgs-crt is not installed" >&2; exit 1; }

PKG="${RGS15_PKG:-/userdata/system/crt-dual}"
LOG="${RGS15_LOG:-/userdata/system/logs/rgs-15khz.log}"
RGSFILE="${RGS15_RGS_VERSION_FILE:-/userdata/system/rgs.version}"

# Hand-off to the window (its own temp dir; never the repo).
_RUN="$(mktemp -d /tmp/rgs-crt-check.XXXXXX 2>/dev/null || true)"
[ -n "$_RUN" ] || _RUN="/tmp/rgs-crt-check.$$"
mkdir -p "$_RUN" 2>/dev/null || true
_VFILE="$_RUN/verdict"
_OFF=0
[ -f "$LOG" ] && _OFF="$(wc -c <"$LOG" 2>/dev/null || echo 0)"

# The window script (a temp file, so it can be BACKGROUNDED while the
# flow below runs in the foreground — the seam sees the flow, the user
# sees the live steps).
cat >"$_RUN/window.py" <<'PYEOF'
import sys
import pygame

logpath = sys.argv[1] if len(sys.argv) > 1 else ""
off = int(sys.argv[2]) if len(sys.argv) > 2 and sys.argv[2].isdigit() else 0
vfile = sys.argv[3] if len(sys.argv) > 3 else ""

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
f_small = pygame.font.SysFont("dejavusans", int(fs * 0.9))
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

white, dim, warn = (245, 245, 245), (168, 172, 180), (230, 200, 60)
progress = []
verdict = None
rows = []
err = ""

def tail_log():
    global off
    if not logpath:
        return
    try:
        with open(logpath, "rb") as fh:
            fh.seek(off)
            data = fh.read()
            off = fh.tell()
    except OSError:
        return
    for raw in data.decode("utf-8", "replace").splitlines():
        s = raw.split("]: ", 1)[-1].strip()
        if s.startswith("update:") or "GUARD HOLD" in s:
            progress.append(s)

def read_verdict():
    global verdict, rows, err
    if not vfile:
        return
    try:
        txt = open(vfile, encoding="utf-8", errors="replace").read()
    except OSError:
        return
    if not txt.strip():
        return
    lines = txt.splitlines()
    verdict = lines[0].strip() if lines else "RED"
    if verdict not in ("GREEN", "RED"):
        verdict = "RED"
    for line in lines[1:]:
        if line.startswith("ERR "):
            err = line[4:].strip()
        elif line.strip():
            rows.append(line)

result = []
running = True
while running:
    for ev in pygame.event.get():
        if ev.type == pygame.QUIT:
            running = False
        elif ev.type == pygame.KEYDOWN:
            if ev.key == pygame.K_ESCAPE:
                running = False
            elif verdict == "RED" and ev.key == pygame.K_u:
                result.append("uninstall")
                running = False
            elif verdict is not None:
                running = False
    if verdict is None:
        tail_log()
        read_verdict()

    scr.fill((12, 12, 16))
    band_h = int(h * 0.14)
    if verdict is None:
        band_col, title = (40, 60, 96), "RGS-CRT - CHECK & UPDATE"
    elif verdict == "GREEN":
        band_col, title = (30, 96, 40), "RGS-CRT - ALL GREEN AND CERTIFIED"
    else:
        band_col, title = (168, 32, 32), "RGS-CRT - RED: NOT CERTIFIED"
    pygame.draw.rect(scr, band_col, (0, 0, w, band_h))
    pygame.draw.rect(scr, band_col, (0, h - 4, w, 4))
    t = f_title.render(title, True, white)
    scr.blit(t, (w // 2 - t.get_width() // 2, band_h // 2 - t.get_height() // 2))

    ty = int(h * 0.22)
    if verdict is None:
        shown = progress[-12:] if len(progress) > 12 else progress
        for line in shown:
            for piece in wrap(f_small, line):
                s2 = f_small.render(piece, True, dim)
                scr.blit(s2, (margin, ty))
                ty += int(fs * 1.15)
        if not progress:
            s2 = f_body.render("checking the layer...", True, dim)
            scr.blit(s2, (margin, ty))
    else:
        # what the flow did, dimmed above the verdict — so the steps are
        # visible even when the check completes in well under a second
        # (nothing to install: there is no long-running phase to watch).
        shown = progress[-8:] if len(progress) > 8 else progress
        for line in shown:
            for piece in wrap(f_small, line):
                s2 = f_small.render(piece, True, dim)
                scr.blit(s2, (margin, ty))
                ty += int(fs * 1.15)
        if shown:
            ty += int(fs * 0.5)
        for line in rows:
            for piece in wrap(f_body, line):
                s2 = f_body.render(piece, True, white)
                scr.blit(s2, (margin, ty))
                ty += int(fs * 1.45)
        if err:
            ty += int(fs * 0.4)
            for piece in wrap(f_body, err):
                s2 = f_body.render(piece, True, warn)
                scr.blit(s2, (margin, ty))
                ty += int(fs * 1.45)
        ty += int(fs * 0.4)
        if verdict == "RED":
            for line in ("U = uninstall rgs-crt and reboot into stock RGS",
                         "ESC = exit and keep playing stock"):
                s2 = f_pick.render(line, True, warn)
                scr.blit(s2, (margin, ty))
                ty += int(fs * 1.45)
        else:
            s2 = f_body.render("Press any key to close.", True, dim)
            scr.blit(s2, (margin, ty))

    if verdict is None:
        hint = "ESC = exit"
    elif verdict == "RED":
        hint = "U = uninstall, ESC = exit"
    else:
        hint = "any key = close"
    h2 = f_pick.render(hint, True, dim)
    scr.blit(h2, (w // 2 - h2.get_width() // 2, h - int(h * 0.06) - h2.get_height() // 2))
    pygame.display.flip()
    clock.tick(10)
pygame.quit()
print(result[0] if result else "")
PYEOF

# 1. Open the window FIRST, in the background: it tails the log for the
#    live steps and reads the verdict file the moment the flow writes it.
#    Backgrounded so the flow stays the foreground call the seam observes
#    (and so ESC can close the window without aborting an update already
#    running — the update is automatic; opening the tool is the consent).
DISPLAY="${DISPLAY:-:0.0}" python3 "$_RUN/window.py" "$LOG" "$_OFF" "$_VFILE" "$SVC" \
	>"$_RUN/choice" 2>/dev/null &
_PYPID=$!

# 2. The automatic flow: feed check -> install a newer certified release
#    via get.sh -> certify -> on green the version rises to the RGS it
#    just certified. RGS15_FEED_ALLOW_NET=1 is the feed probe's opt-in.
#    No reboot. stdout is the verdict (GREEN|RED); rc 2 = certified but
#    the install failed (loud in the log, no re-label).
_rc=0
_verdict="$(RGS15_FEED_ALLOW_NET=1 bash "$SVC" tool-update 2>/dev/null)" || _rc=$?
[ "$_verdict" = "GREEN" ] || _verdict="RED"

# 3. Compose the outcome + rows and hand them to the window. The verdict
#    DECISION stays here (seamable): a non-GREEN flow fails safe to RED.
_installed="$(tr -d ' \t\r\n' <"$PKG.version" 2>/dev/null || true)"
[ -n "$_installed" ] || _installed="unknown"
_live_rgs="$(tr -d ' \t\r\n' <"$RGSFILE" 2>/dev/null || true)"
[ -n "$_live_rgs" ] || _live_rgs="unknown"
_err_row=""
if [ "$_rc" != "0" ]; then
	# the last loud line of the flow, so the window explains itself — a
	# failed update is never silent (full story stays in the service log).
	_err_row="$(grep -Ea 'update: ERROR|GUARD HOLD' "$LOG" 2>/dev/null | tail -1 | sed 's/^[^]]*]: //')"
fi
{
	printf '%s\n' "$_verdict"
	if [ "$_verdict" = "GREEN" ]; then
		printf '%s\n' "all green and certified - version $_installed"
		printf '%s\n' "certified on RGS $_live_rgs"
	else
		printf '%s\n' "the rgs-crt layer could not be certified on this system"
		printf '%s\n' "games run stock-safe meanwhile"
	fi
	[ -n "$_err_row" ] && printf 'ERR %s\n' "$_err_row"
} >"$_VFILE"

# 4. Wait for the window to close, then act on the ONE deliberate choice.
wait "$_PYPID" 2>/dev/null || true
_choice="$(cat "$_RUN/choice" 2>/dev/null || true)"
rm -rf "$_RUN" 2>/dev/null || true
if [ "$_choice" = "uninstall" ]; then
	bash "$SVC" tool-uninstall
fi
exit 0
