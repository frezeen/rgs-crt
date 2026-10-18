# Changelog

## 2026-10-18 — Windows arcade and pinball systems tuned for the tube

- **Pinball FX, Pinball FX2, Pinball M and Zaccaria Pinball render native 640x480i.** Each table fills
  the 4:3 tube edge to edge at native proportions without distortion or downscaling.
  Rendering directly at the tube resolution keeps GPU load minimal (1.5% to 4.6% on
  Pinball FX and Pinball FX2; 2.8% on Zaccaria Pinball; 85% on Pinball M) for solid 60 Hz frame pacing.
- **Pinball FX3 uses a 1080p canvas with full-frame display.** The engine's fixed
  display configuration is mapped cleanly to the 480i tube (6.3% GPU load).
- **Windows arcade systems render on a 1280x720 canvas.** Systems drawing on an HD
  canvas (Adrenaline Arcade, Arcade PC, UNIS) display full frame at 480i without
  saturating the graphics card.
- **Laserdisc arcade systems (Daphne and Singe) certified on the tube.** Dragon's
  Lair and laserdisc titles fill the 4:3 tube edge to edge at native 640x480i
  (0.9% GPU load). Widescreen command overrides that cropped the video and pushed
  the arcade score display out of frame are stripped on the tube profile so the
  full picture and scoreboard remain centered and legible.
- **Works on the current RGS.** This release is built and checked against RGS
  43.65. When RGS updates, the layer re-checks itself against the new version at
  boot or when you open the check tool.

## 2026-10-17 — five more machines reach the tube

**Five more systems are certified for the tube: Apple IIgs, Atari Jaguar
CD, Visual Pinball, Sega Model 3 and Sega Hikaru.** Each fills the 4:3
tube with the machine's own picture on its interlaced signal, full frame
with no black bars, and text and scores legible one to one:

- **Apple IIgs** — the computer's picture fills the tube at 640x480i,
  its blue border included. No per-game settings: the common profile is
  enough, and the machine plays even though the emulator looks for a
  system ROM file this box does not carry.
- **Atari Jaguar CD** — the add-on's games fill the tube at 480i, and
  there is no BIOS to find or place.
- **Visual Pinball** — the pinball table fills the tube edge to edge,
  its own side artwork left and right exactly as the maker drew it. The
  table brings its own pinball ROM, nothing to add.
- **Sega Model 3** — the board's 3D arcade games fill the tube at 480i,
  drawn straight from the board's own raster.
- **Sega Hikaru** — the arcade's 3D picture fills the tube the same
  way: no bars, no stretch.

**A .chd game for FM Towns will not open, and the fault is in RGS.** The
system list offers a .chd for FM Towns like any other game, but the
emulator RGS ships cannot read that format: the machine reaches the Towns
logo and then waits for a system disk with the drive empty. Sitting in
RGS, not in the layer, it is not something the layer can fix — until RGS
changes its emulator, keep FM Towns games in a format the emulator reads.

## 2026-10-17 — the check no longer fails a healthy box at random

**A healthy setup passes the display check every time.** The check that
verifies the screen is being managed used to count the screen-manager
program by listing processes — and one helper process it spawns while doing
any work counted as a second copy of the manager. On some boxes the check
then failed even though nothing was wrong, saying the screen is unmanaged,
at random and without any real fault. It now counts the manager programs
and their own helpers the way they are actually related, so it sees exactly
one manager on a healthy setup, every time.

## 2026-10-16 — the layer follows RGS 43.63, and a problem report is collected twice as fast

**Works on the current RGS.** This release is built and checked against RGS
43.63. When RGS updates, the layer re-checks itself against the new version at
boot or when you open the check tool, and the version it shows follows the
RGS it was checked against.

**Sending a problem report is about twice as fast.** The report you produce
when something goes wrong gathered its pieces one after another; they are
independent of each other, so they are now gathered together. Same report,
same contents, roughly half the wait.

**A problem report now says when it is incomplete.** The report carries a
small status file: OK, or BROKEN with one line per decisive field that is
missing (for instance a screen snapshot with no scaling detail). When
something decisive is missing the tool also exits with an error, so a report
can no longer look fine while it is not — the report itself is still
produced.

**The consistency check no longer says "all fine" while the screen is
unmanaged.** If the layout names a screen that is not connected, or the
program that manages the screen is not running exactly once, the check now
fails loudly instead of reporting a clean state.

## 2026-10-16 — the layer follows RGS 43.62, and the check tool stops offering the same update twice

**Works on the current RGS.** This release is built and checked against RGS
43.62. When RGS updates, the layer re-checks itself against the new version
at boot or when you open the check tool, and the version it shows follows the
RGS it was checked against.

**The check tool no longer offers the same update again and again.** After it
installed an update, it kept showing that same one as still available, so
opening it again would download and install it a second time. Fixed: once an
update is installed, the tool sees it as current.

**Leaving a game no longer leaves the menu black on the LCD profile.** When
you played a game while the LCD was the active screen and then went back to
the menu, the menu could come back black. Fixed: preparing a game session no
longer switches off the screen the menu lives on.

**The RGS update from the menu is no longer interrupted.** That update opens
several windows in a row; the layer could read the pause between two of them
as "the game has closed" and release the screen mid-update, which aborted it.
Fixed: while an RGS utility is running, the release waits.

**The screen comes back faster when a game closes.** Going back to the menu
after a game now takes a few seconds instead of about eleven, on both screens.

**The update tool's text is readable on the tube.** The RGS updater's window
is sized for a large modern screen, so on the tube its text was too big to
read. The layer now opens it with a size that fits 480i.

**The check tool shows what it is doing.** The check entry prints the live
steps of its check and update, and keeps the steps on the result screen.

## 2026-10-11 — the Windows-arcade systems reach the tube

**Three more arcade systems on the tube.** Adrenaline Arcade, Arcade PC and
UNIS Arcade Machines now start on the 15 kHz signal instead of staying on the
LCD: their games fill the 4:3 glass at 480i, with the picture reaching the
edges. Checked on the glass with Candy Crush Arcade, Arctic Thunder, Friction,
Subway Surfers Arcade and Dino Invasion. The 4:3 titles fill the tube the way
the cabinet shows them; the wide-screen ones fill it stretched — the same
declared trade the PS3 and Xbox 360 rows already make. Every game keeps the
look it ships with, its own cabinet frame included, exactly as the original
does.

**The rest of the Windows-arcade family is ready.** The other RGS
Windows-arcade systems — the Taito Type X family, Global VR, Sega Nu and
Konami PC — get the same tube treatment, so their games will start on the tube
the moment their content is on the machine. No game of theirs is on this box
yet, so none has been measured: the compatibility map lists them as not yet
tested.

**Windows-arcade games start again.** A change meant to release the screen
when a game closes could also end a game that had just started, so the
Windows-arcade titles — the Raw Thrills shooters included — stopped launching.
Fixed: the release now waits until the game has really gone, so a game that is
still running is never touched.

## 2026-10-11 — the check entry keeps itself current, and RGS 43.58 is certified

**Opening the check entry is now all it takes.** "RGS-CRT CHECK & UPDATE" no
longer waits for a keypress: opening it looks for a newer release of the
layer, installs one on the spot when it is certified for this box,
re-certifies against the RGS version the box runs, and shows the result.
Each step is shown on screen, and written to the log, errors included.

**It never reboots on its own.** A layer update installs in place; you
restart when RGS itself says a reboot is due — the tool asks nothing of the
machine and never touches a running game.

**The version now follows the RGS it ran on.** Once the layer certifies on a
new RGS, its version takes that RGS number (for example 43.58.0), so the
check line and the RGS you are running agree — even before a release for
that number is published.

**New arcade systems written down.** The Windows-arcade systems RGS ships
(typex, typex2, nesicax, nesicax2) are now listed in the compatibility map
as not yet covered: they run stock until a profile is measured, exactly like
globalvr and arcadepc.

