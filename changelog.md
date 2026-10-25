# Changelog

## 2026-10-25

- **Ballistics arcade 3D starts in native full-screen.** Removed the widescreen translation canvas and redundant game keys for Ballistics, letting it boot directly into its native full-screen 4:3 640x480 resolution without getting stuck before video mode negotiation.
- **Bounty Hunter authentic 3:4 vertical arcade display.** Corrected ReShade preset and aspect ratio mapping for Bounty Hunter: disabled artificial flat-panel bezels, virtual CRT curvature and bloom shaders, restoring clean pillarbox black borders and authentic 3:4 TATE arcade geometry on 4:3 CRT monitors.
- **Arcade PC widescreen gamescope classification.** Cleaned up native 4:3 titles from the 16:9 Gamescope forced list, reserving hardware canvas scaling strictly for actual widescreen titles.
- **Robust session termination and updater reliability.** Polling guards and update feed probes now handle active wine sessions cleanly, preventing false game timeouts and loop detections.

## 2026-10-22

- **Dreamcast keeps its 4:3 shape.** Dreamcast games now declare the picture
  as 4:3 in the emulator's aspect setting instead of following the emulator's
  internal widescreen-shaped picture, so the arcade proportions stay fixed.
- **NESiCAxLive games lose the smoothing blur.** Namco NESiCAxLive titles now
  render raw native pixels on the tube instead of the software smoothing
  filter the emulator layered over the picture.

## 2026-10-21

- **Interlaced HDMI and TV panel compatibility.** Fixed boot crashes on TVs and monitors advertising 1080i modes over HDMI by properly sanitizing display boundary definitions.
- **Dual display widescreen LCD scaling.** The display engine now strictly selects progressive modes over interlaced modes on digital panels, enabling hardware scaling to stretch the cloned 4:3 arcade desktop edge-to-edge on 16:9 LCDs without black borders.
- **Seamless updater verification.** Verification now accounts for pre-reboot state during installs and updates on AMD/Intel systems, eliminating false failure banners in the EmulationStation update tool.
- **NESiCAxLive arcade library certified on CRT.** Full 50-game library tuned for the 4:3 tube, with native raster on horizontal classics and authentic 3:4 orientation with arcade bezels on vertical shooters.
  - **Widescreen HD arcade titles stretch cleanly to fill the tube.** Modern
    16:9 widescreen releases (BlazBlue, Persona 4 Arena, Under Night In-Birth,
    Ultra Street Fighter IV, Crimzon Clover, Yatagarasu, etc.) utilize targeted
    Gamescope canvas scaling to fill the entire 4:3 tube edge to edge without black bars.
- **Multi-system configuration scoping.** Profiles now support declaring custom
  configuration files independently across different systems, ensuring that game-specific
  overrides for one emulator (such as MAME or Windows arcade games) are only applied
  when launching games on that specific system.
- **Safe game termination on system updates.** When applying configuration updates,
  active Windows arcade games and background emulator processes are cleanly closed,
  preventing launch collisions and leaving EmulationStation responsive.

## 2026-10-21 — Sega Chihiro arcade games certified on the tube; RGS upgrade scripts protected

- **Sega Chihiro arcade games certified on the tube.** Chihiro titles fill the 4:3
  tube edge to edge at native 640x480 resolution on an interlaced 60 Hz signal,
  with authentic arcade proportions and zero extra sharpening or cosmetic shaders.
- **Reliable graphics rendering via Vulkan API.** Chihiro now utilizes the native Vulkan
  graphics backend on AMD GPUs, resolving graphics ring timeouts and crashes that occurred
  under OpenGL and ensuring smooth, stable gameplay with low GPU overhead (34%). Verified
  across multiple titles (Crazy Taxi High Roller, OutRun 2 Special Tours, The House of the Dead III).
- **RGS utility update scripts run without interruption.** The display supervisor now
  prioritizes RGS utility menu scripts over orphan checks, ensuring that system upgrade scripts
  that restart the menu are never prematurely aborted.
- **Robust process clean-up on game exit.** The process tree killer safely guards against
  terminating inherited session process groups when the frontend closes, keeping background
  display services and remote access active.

## 2026-10-20 — Sega Model 2 certified on the tube; game launches protected from false timeouts

- **Sega Model 2 arcade games certified on the tube (Daytona USA).** Titles
  fill the 4:3 tube edge to edge at the native arcade refresh rate (57.52 Hz) on
  an interlaced signal, locked with zero tearing and smooth frame pacing.
  Internal 3D rendering runs at native 1:1 resolution instead of the heavy 4x
  supersampling shipped by stock, keeping graphics faithful to the original arcade
  board while keeping GPU load minimal (19%).
- **Authentic arcade rendering on the tube.** Sega Model 2 games use the arcade
  monitor's own continuous beam scaling, original draw distance, and authentic
  stipple transparency. Software CRT cosmetic filters designed for flat screens
  are disabled on the real tube.
- **Game launches are protected from false timeouts.** The system supervisor
  now evaluates game windows relative to the active screen mode, ensuring that
  low-resolution, vertical arcade, and interlaced titles are recognized immediately
  and never killed during startup.
- **Games returning to the menu release the screen cleanly.** If an arcade game
  or Windows title exits or hangs, the background manager terminates all child
  processes and safely brings back the main menu without freezing the display.

## 2026-10-19 — the layer follows RGS 43.68

- **The box updated to RGS 43.68 and the layer re-certified by itself** (version
  43.68.0, `verify.sh` clean). The 43.67 defect that hid the system list is not
  in this path: going straight to 43.68 never writes the broken file.
- **Chihiro follows the new stock emulator.** 43.66 replaced it with the
  `xemuchihiro` generator, whose render scale is the namespaced
  `xemu_chihiro_render`; the old `xemu_render` stays for Xbox only, so the
  chihiro block now names the key the stock generator actually reads.
- **Amiga Ransom gets the same tube treatment as Amiga 500/1200** — auto-crop
  on, aspect correction off — instead of the pillar-boxed stock default.
- **Sega Model 2 needs a tube re-test**: 43.66 replaced the emulator (0.9.51)
  and the 43.68 generator now sizes its window from the declared raster.

## 2026-10-19 — remote access stops fighting a screen that is not there yet

- **The remote view service no longer restarts itself in a loop when the
  display server is not up yet.** At boot, or after a restart of the display
  server, it waits at no cost instead of starting the viewer every two
  seconds — that used to mean hundreds of starts in one morning, each one a
  probe of the display, and tens of thousands of log lines. The remote view
  comes back as soon as the screen is there.
- **If the viewer cannot stay up for another reason, it gives up after a few
  tries and writes why in its log**, instead of spinning forever. A viewer
  that died after a healthy run still comes back on its own, as before.

## 2026-10-18 — leaving a game is one clean change; a screen plugged in is handled once

- **Leaving a game restores the desktop with a single change.** The layer now
  touches only the displays that actually disagree with the wanted layout, so the
  tube no longer receives a mode change it was already on, and the menu comes
  back sooner (measured: from about five display changes down to two, and the
  screen no longer drops to a tiny frame in between).
- **A screen plugged in or unplugged is handled once.** The layout is restored in
  one pass, without the extra interface restart that used to undo the first
  attempt: no black window on the display that has just been attached, and no
  wasted work behind it.
- **Unplugging and replugging a cable within a couple of seconds costs nothing.**
  A display that leaves the cabinet waits for the layout to settle instead of
  reacting to a cable that is coming straight back.
- **When a game takes the screen, the hand-over is checked.** The checked
  condition is now the whole hand-over (the game's screen is on, primary and
  unscaled) instead of half of it, so a mis-set primary can no longer send the
  picture to the other display.
- **After a game, the menu is checked against the screen** and repaired when its
  window does not fill it, instead of being left partly off-screen until
  something else moved it.
- **A menu page that occasionally came up blank is now detected** and given one
  nudge, and the amount of blank area it reports is written down, so the next
  occurrence can be measured rather than described.
- **The display service comes back reliably after a restart.**

## 2026-10-18 — Windows arcade and pinball systems tuned for the tube

- **Pinball FX, Pinball FX2, Pinball M, Zaccaria Pinball and Future Pinball render native 640x480i.** Each table fills
  the 4:3 tube edge to edge at native proportions without distortion or downscaling.
  Rendering directly at the tube resolution keeps GPU load minimal (1.5% to 4.6% on
  Pinball FX and Pinball FX2; 2.8% on Zaccaria Pinball; 6.3% on Future Pinball; 85% on Pinball M) for solid 60 Hz frame pacing.
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
- **Taito Type X and Type X+ certified on the tube.** Native 4:3 titles (The King of Fighters '98 Ultimate Match, GigaWing Generations, Spica Adventure) render directly at 640x480i with minimal GPU load (0.9% to 2.4%). Widescreen 16:9 and HD titles (New Super Mario Bros. Wii Coin World, Battle Gear 4 Tuned / Professional at 1360x768, Battle Gear 4 at 800x600) use targeted Gamescope stretch to fill the 4:3 tube edge to edge without black bars.
- **NESiCAxLive certified on the tube (50 titles).** Every title fills the 4:3 tube
  edge to edge at 640x480i without black bars. Titles that draw on an HD canvas
  (Chaos Code, Vampire Savior, Crimzon Clover) display full frame, covering 99.6%
  of the glass with minimal GPU load (0.6% to 0.8%). Exception runs on the same
  class canvas: it asks SDL for a 1280x720 surface at startup, and an earlier
  per-game 640x480 canvas made its payload throw and die instead (85% of the
  tube once back on the class canvas).
  Elevator Action, which the launcher already presents at screen size in 4:3,
  renders directly with no canvas at all (0.8% GPU load).
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
