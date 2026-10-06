# Compatibility map — what works on the tube

This layer runs INSIDE stock RGS and reverts cleanly.

This is the honest per-system status of the **RGS 15 kHz CRT** profile.
Certification box: RGS 43.43 (Batocera 43.1 base), x86_64, NVIDIA
GTX 970, arcade tube in the demonstrated 13.6–16.2 kHz range — the
measured numbers below come from it; the full layer has also been
tested on an AMD R9 270X machine, and Intel hardware carries a
pending re-test. Every TESTED verdict
below comes from a real launch on that tube with the resulting signal
measured — a glance is never a verdict.

## How to read the verdicts

| Verdict | Meaning |
| --- | --- |
| **TESTED date** | Launched on the real tube; the signal was measured and the picture judged (fullscreen, legible text, owner eyes on the glass). The numbers stay in the row. |
| **family** | Runs through a pipeline already certified by a TESTED launch of the same kind, byte-for-byte. Expected to work; not individually launched yet. |
| **pending** | Declared untested — usually this box has no content for it. Never presented as working. |

## Measured on the tube (TESTED)

The "settings" column is a faithful summary of what the tube profile
declares for that system; the profile folder itself is the complete
source. Two shorthands:
**common** = the every-launch base (480i desktop mode, smoothing off,
shaders off, bezels off); **RA family** = the RetroArch family keys
(the emulator switches the tube resolution itself, no super-resolutions,
no shader from any source). A row saying "common + RA family" has no
per-system tuning at all — its result comes from the pipeline alone.


Some video chains cannot clock the lowest native arcade modes at all (the analog
output of certain integrated graphics is one; a DisplayPort adapter or a
dedicated AMD card is not). The layer measures the chain at every boot and,
when that is the case, hands games the smallest widened version of their mode
that still clocks — same picture and the game's exact refresh, just a wider
raster (e.g. 640x224 instead of 320x224). Chains that can do native modes are
left untouched. Nothing to configure: the measurement runs before the frontend
starts.

| System | What you get | Settings the profile applies | Verdict |
| --- | --- | --- | --- |
| Super Nintendo (snes, snes-msu1, sufami, satellaview) | Native SNES signal, 256x224@60.10, pixel-perfect, no filters | common + RA family | TESTED 2026-09-04 |
| NES, Famicom Disk System | Native 256x224@60, tiny credits legible | common + RA family | TESTED 2026-09-06 |
| Mega Drive / Genesis (+ Mega-CD, Game Gear, SG-1000 on same pipeline) | Native 320x224, full-bleed, correct aspect | common + RA family | TESTED 2026-09-06 |
| PC Engine / TurboGrafx (+ CD) | Native 256x240, full-bleed, crisp | common + RA family | TESTED 2026-09-06 |
| Game Boy Advance | Its native 240x160@60 is too rare a signal for a tube; runs fullscreen at an even 3x on a clean interlaced signal instead — authentic handheld colors | common + RA family + core-native aspect (ratio=core) | TESTED 2026-09-06 |
| Naomi / Dreamcast / Atomiswave family | Native 640x480i arcade signal. Expect a brief re-sync in the first seconds of a Dreamcast-family launch (the core announces its display size after boot; the tube settles on the true native mode) — safe at arcade frequency the whole time | common + RA family + 640x480 internal render, anisotropic filtering off (Atomiswave: the resolution key only) | TESTED 2026-09-04 (Naomi) |
| Arcade — MAME (standalone and RetroArch core) | Each game gets its own board's native mode; measured Virtua Fighter at 693x520@57.52i and R-Type at 384x256@55.02, both full-bleed with the smallest text legible. The standalone path runs on **GroovyMAME**, an arcade binary **you procure** (never shipped — see install & updates). Audio stable on the current binary | common + stand-alone arcade redirection (switchres on, artwork crop, accelerated video) + authored ini files + the binary swap + the launcher's hardcoded audio override dropped | TESTED 2026-09-04 |
| Sega Model 2 (model2) | Native Model 2 raster at 693x520@57.52i, full-bleed, correct aspect; runs the RGS Model 2 emulator (the JammASD cabinet wiring talks straight to the board emulation) | common + native 1:1 render + the declared raster (693x520i.57.524160) | TESTED 2026-09-10 (Daytona USA) |
| Arcade — Neo Geo / FBNeo | Native 320x240@60 progressive, fullscreen | common + RA family | TESTED 2026-09-06 |
| Sega Saturn | Correct proportions at 660x224@59.83, with ~7% black bands top and bottom kept on purpose: stretching the signal to fill would trade correctness for accuracy | common + RA family | TESTED 2026-09-06 |
| Nintendo DS | Both screens stacked (Top/Bottom) at 661x496i filling the whole tube | common + RA family | TESTED 2026-09-06 |
| Commodore 64 | Native 384x272@50, full-bleed square pixels, no pillars | common + RA family + zoom mode off, pepto-PAL palette, square-pixel aspect | TESTED 2026-09-06 |
| Nintendo 64 (+64DD) | Native 320x240@60 progressive, pixel-for-pixel edge to edge. The session uses the core that follows the console's live video timing; the stock default is never touched | common + RA family + session-scoped core choice (parallel_n64) | TESTED 2026-09-06 |
| Amiga 500/1200 | 480i arcade signal for every game; measured Aladdin gameplay filling all edges with 1:1 HUD text legible | common + 480i video mode, pixelated scaling, auto-crop on, aspect-correction off, 640x480 canvas forced in the emulator's own file | TESTED 2026-09-06 |
| DOS | Signal follows the content's native mode; measured 320x200@65 | common + RA family | TESTED 2026-09-06 |
| PS2 | 640x480i as designed, authentic hardware-style texture filtering, no fake scanlines. Attract-mode footage carries its own letterbox (the game's frame, not bars); gameplay-HUD fill not certified | common + vsync on, Vulkan backend, PS2-authentic texture filtering + dithering + mipmapping, 4:3 FMV ratio | TESTED-with-note 2026-09-07 |
| PlayStation (psx) | The console's own signal, 1:1: measured 512x240 at 60 Hz on a clean 15.7kHz line, pixel-for-pixel with no filters — pause menus and HUD text crisp at 1:1, original 4:3 proportions. The system picks its standard PlayStation emulator by itself | common only | TESTED 2026-09-23 |
| SC-3000 | Boots to native 280x216@59.92 with the console's hardware border — but only after you pick the right core in the game's settings; see stock issue §1 | common + RA family (the core choice stays yours — stock mis-resolves it) | TESTED 2026-09-06 |
| BBC Micro (and the MAME-driven vintage computers) | Native 640x480@50i, crisp | common only; the shared arcade ini files, the binary swap and the audio-override drop belong to the arcade (MAME) system, not to this row | TESTED 2026-09-06 |
| Doom (PrBoom), Mr. Boom | Native 320x200, full HUD, all edges | common + RA family | TESTED 2026-09-06 |
| Ports & tools (Od Commander, RetroTrivia, Prince of Music) | Run stock on the tube's 480i desktop signal, crisp | common only | TESTED 2026-09-06 |
| Commander X16 (commanderx16) | The machine's boot screen fills the tube with pixel-crisp 1:1 text. The X16's native signal is 640x480@60 **progressive** (a 31kHz VGA-class signal no 15kHz tube can show as progressive), so the tube shows the same untouched pixel grid **interlaced** at 640x480i 15.69kHz — no scaling, all 480 lines. The machine also has a 320x240@60 (40-column) mode that stays 15kHz-safe; not proven on the tube yet. For a .bas launch the stock loader carries only the last of the program's two files (upstream behaviour) | common + native 1:1 rendering (the stock renderer's 2x upscale disabled) | TESTED-with-note 2026-09-10 |
| Pyxel (pyxel) | Runs on its own native signal: 256x256 at ~58.5Hz **progressive** on a clean 16.2kHz line (the tube's demonstrated upper edge), pixel-for-pixel with no filters. A square image on a 4:3 glass: the render fills the width with a minimal vertical overscan (the arcade standard — text sits well inside) | common + native 256x256 mode declared per game | TESTED-with-note 2026-09-10 |
| Wii U (cemu) | HD 16:9 console on the tube's 480i, full-bleed stretched — the shared HD-console policy. The emulator's own stretch setting lands in its live file, render native, no extra image tricks | common + cemu stretch aspect (FullscreenScaling) + gamescope 864x486@60 fullscreen stretch | TESTED 2026-09-10 |
| PS4 (shadps4) | HD 16:9 content on the tube's 480i, full-bleed stretched — same policy as the PS3/Vita rows. The window wrapper is what fills the glass: without it the emulator letterboxes by itself (its own file offers no stretch control). Render at the game's own scale, no sharpening or smoothing | common + gamescope 864x486@60 fullscreen stretch + native render | TESTED 2026-09-10 |
| PS Vita (vita3k) | The Vita's native panel (960x544) has no 15kHz form (its interlaced variant needs ~17.3kHz — beyond the tube's demonstrated edge), so the game runs full-bleed stretched to the tube's 480i — same policy as the PS3 row. The internal render stays at the console's native scale, no sharpening or smoothing. A true-proportions letterbox mode exists (a two-key change) | common + gamescope 864x486@60 fullscreen stretch + native render scale | TESTED-with-note 2026-09-10 |
| PS3 (rpcs3) | HD 16:9 console on a 15kHz tube: no native mode exists, so the tube shows it full-bleed stretched to 4:3 — the proportions are compressed (16:9 content in a 4:3 glass). Render at the game's native scale (no artificial upscaling), no sharpening or smoothing. The letterboxed alternative (true proportions with black bars) exists as a one-key change if you ever prefer it | common + rpcs3 native render scale (100%) + gamescope 864x486 fullscreen stretch | TESTED-with-note 2026-09-10 |
| Xbox / Chihiro (xemu) | Native 640x480 on the tube's 480i signal — gameplay fills the glass edge to edge (the title art keeps its own dark frame); title text legible 1:1. Runs the stock Xbox emulator with a 1:1 render scale and no extra image tricks (sharpness and smoothing stay off) | common + gamescope 640x480@60 window (pixel filter, no sharpening, fullscreen stretch) + native render scale | TESTED 2026-09-10 |
| GameCube / Triforce / Wii (dolphin family) | Native 640x480 raster shown on the tube's 480i signal (the console's own 480p is a 31kHz signal a 15kHz tube cannot show progressively) — full-bleed. The internal render runs at an even 2x for crisper geometry and text | common + dolphin stretch-to-window fill, internal render 2x | TESTED 2026-09-10 |

**Every verdict includes the exit:** the session ends, everything
returns to the desktop state, and the system reports clean.

## Same certified pipeline, not individually launched (family)

These systems share a path already certified by a TESTED launch above,
byte-for-byte. Names are the system IDs as they appear in the game
lists; each is certified by the launch named at the end of the line.

- **Game Boy / handhelds** — gb, gbc, gb2players, gbc2players, gbch,
  gbah, pokemini, virtualboy, wswan, wswanc, pocketchallengev2, ngp,
  ngpc, lynx, supervision, megaduck: same libretro pipeline as the
  TESTED Game Boy Advance launch.
- **Nintendo classics** — famicom, nesh, dendy, datach, nes_hd,
  nesaladdin, nes-msu, supercharger: same pipeline as the TESTED NES
  launch; sfc, snesh, sgb, sgb-msu1: same as the TESTED SNES launch;
  iqueplayer, n64-jp, n64h: same as the TESTED N64 launch; cavestory,
  dinothawr, superbroswar, xrick, arduboy, tic80, wasm4, zc210, dice,
  lowresnx, pico8, bennugd, lutro, uzem, scv: same core plumbing,
  their own content pending.
- **Sega family** — gamegear, sg1000, megacd, megadrive-msu, genesis,
  genh, ggh, mark3, megadrive-jp, nomad, segacd, megadrive-segachannel,
  sega32xcd, megacd32x, sega32x, pico, saturn-jp, multivision: same
  pipeline as the TESTED Mega Drive / Saturn launches; dreamcast-jp:
  same as Naomi.
- **NEC / SNK / other consoles** — tg16, tgcd, pcfx,
  supergrafx: same as the TESTED PC Engine launch; neogeocd, cps1,
  cps2, cps3, neogeomvs, neogeo64, igspgm, segastv, namco10, namco12,
  namco23, videopac: same as the TESTED Neo Geo / MAME-core launches;
  cave3rd, gaelco, namco22: MAME core
  (same standalone-arcade pipeline, no content on this box yet);
  jaguar, vectrex: same libretro pipeline.
- **Home computers via RetroArch** — atari2600, atari5200, atari7800,
  atari800, atarist, zx81, thomson, pc98, x68000, x1, pc88, c128, c20,
  cplus4, pet, c64gs, cbm2, msx2+, msxturbor, gx4000, gemrb,
  reminiscence, vircon32, quake, intellivision, channelf, odyssey2,
  videopacplus, 3do, cassettevision: same pipeline
  as the TESTED C64 launch; amigacd32, amigacdtv ride the TESTED Amiga
  path; zxspectrum (fuse, user override)
  rides the tested global-only path.
- **Vintage computers via MAME/MESS** — arcadia, cgenie, dragon64,
  mz2500, mz2000, mz700, mz800, mz80k, oricatmos, pv2000, rx78, sv8000,
  beena, ctvboy, loopy, mc10, pc60, pc80, pcw, segaai, trs80, vis, fm7,
  gamecom, gamepock, gp32, pdp1, socrates, supracan, tvgames, vgmplay,
  vsmile, xegs, mtx512, and the abc80–vii block (abc80, alice32,
  apogee, aquarius, bml3, cpc464p, digiblst, elektronika, exl100,
  galaxy, gamekin3, hec2hr, hyprscan, ibmpcjr, jupace, konamilcd, m24,
  m5, mbee, microvsn, mononcol, mpu1000, myvision, ondrat, orao103,
  p2000t, pecom64, pockstat, smc777, snotec, sorcerer, studio2, sys80,
  tiger, vg5k, vic10, vidbrain, vii): same emulator as the TESTED BBC
  Micro / SC-3000 launches.
- **Standalone vintage machines** — adam, advision, apfm1000,
  astrocade, atom, camplynx, coco, crvision, electron, gamate, gmaster,
  laser310, lcdgames, pv1000, ti99, tutor, vc4000, pegasus: same
  global-only standalone path.
- **Clock Signal classics** — amstradcpc, archimedes, colecovision,
  macintosh, mastersystem, msx1, msx2, zxspectrum: same global-only
  path (three TESTED launches).
- **Ports & standalone games** — abuse, bstone, cannonball, catacomb,
  cdogs, cgenius, corsixth, devilutionx, doom3, easyrpg, ecwolf,
  eduke32, fury, etlegacy, fallout1-ce, fallout2-ce, flatpak, gzdoom,
  hcl, hurrican, ikemen, rtcw, jazz2, mugen, openbor, openjazz,
  jknight, jkdf2, mohaa, raze, flash, scummvm, ports, solarus,
  sonic-mania, sonicretro, sonic3-air, steam, rott, theforceengine,
  thextech, traider1, traider2, tyrian, quake3, halflife, quake2,
  windows, windows_installers, ngage, 3dsen, clonehero, fpinball,
  launCharc/makecode, fsuae/amiga600, fightcade2, c16, amiga3000,
  msxlaserdisk, tduo, vgm, zinc: same global-only path.
- **Windows 9x** — win98 runs through the TESTED DOS core; win311 and
  win95 are separate binaries, still pending.

## Declared untested (pending)

No content on the certification box, or one specific behavior still
unproven — listed, never claimed:

- switch, xbox360,
  psp, 3ds, model3, hikaru, namco2x6, daphne, singe,
  jaguarcd, samcoupe, apple2, apple2gs, enterprise, spectravideo,
  fmtowns, lindbergh, moonlight (needs a streaming host
  PC), vpinball, dxx-rebirth, win311, win95.
- rawthrills (Aliens Armageddon, Big Buck Hunter Pro): the tube profile
  sends these two gun games to the tube's 480i arcade signal instead of
  leaving them on the LCD — verified on the glass 2026-10-07 on both
  engines (wine and linuxloader): the picture fills the 4:3 frame, no
  letterbox, no stretch.
- konamigx: the base system definition is malformed, emulator truly
  unknown — needs upstream; gameandwatch: no content and no fallback —
  declared out.
