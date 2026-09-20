# Changelog

## 2026-09-21 — swapping the cables now just works

### Fixed
- **If you move the tube behind an adapter and the panel onto the analog
  port, the layer follows the change by itself.** Screens are recognised
  by what they report about themselves: an adapter that forwards the
  panel's own details is recognised as a panel, an adapter with nothing
  to forward is treated as the tube, and a screen that declares the low
  television timings is treated as a tube wherever it sits. No setting
  needs to be changed by hand.
- **An old setting that no longer matches the cables is ignored loudly.**
  If a port was declared as the panel (or as the tube) and the screens
  are swapped, the layer says so in its log and follows what it actually
  reads — your screens keep working; update or remove the setting when
  you like.
- **The boot splash and the desktop land on the right screen after such
  a change** (the panel), and the desktop is born at the panel's own
  mode.

## 2026-09-20 — integrated graphics' own VGA port now runs games

### Added
- **The layer measures your video chain at every boot.** A few seconds
  before the frontend starts it tries the low arcade video modes and
  keeps the lowest one the chain can really display. The result is
  thrown away and recomputed at every boot, so it always matches the
  card and the cable of the moment; where every low mode works the
  measurement is almost instant.
- **The diagnostic report now identifies each screen**: every bundle
  carries the adapter and EDID details of every port, so a screen that
  is not recognized can be diagnosed from the report alone.

### Fixed
- **A tube behind a DisplayPort-to-VGA adapter is recognized as a tube
  again**, and games run there with their low modes as before. The
  layer now detects when an adapter reports itself instead of the
  screen, and for screens that expose their own details it judges them
  by whether they can show the low television modes.
- **A machine whose VGA port cannot go below a certain clock now runs
  games there.** Some integrated graphics cannot produce the very low
  clocks of 240p at all: a game could start on a mode the screen never
  showed (black picture, sometimes a stuck system). The layer now hands
  games the smallest widened version of their mode that the chain can
  display — same picture and the game's own refresh, a wider raster
  (for example 640x224 instead of 320x224). Dedicated cards and
  DisplayPort adapters are untouched: they keep their native modes.
- **The desktop comes back quickly after you leave a game**: the layer
  reacts within half a second instead of a couple of seconds.
- **The two screens no longer advertise a low mode the tube cannot
  show**, so the system cannot pick a picture the screen will not
  display.
- **The boot splash and the desktop land on the right screen in a
  two-screen setup**, and the frontend window follows the screen when
  the layer changes resolution: the menu no longer stays black until
  you touch the controls, and no low-resolution flash appears at
  launch.
- **Custom resolutions declared for an emulator respect the measured
  chain**: a declared raster below what the chain can display is
  widened like the games instead of going dark.
- **The system's own arcade emulator is properly restored after a
  game** on machines where the layer swaps in the arcade build.

### Improved
- **RetroArch now takes its video settings from the same switchres
  file the arcade emulator uses**, so both behave consistently on every
  chain.
- **The layer's own logs no longer grow without bound**: they are
  trimmed at every boot.

### Settings
- **`rgs-15khz.dotclock_min`** sets the clock floor by hand (a number
  in MHz, or `off` to disable it) and skips the boot measurement
  entirely — useful when you want a fixed floor and the fastest boot.
- **`crt-dual.crt_output`** declares which port carries the tube when
  the layer cannot recognize it; **`crt-dual.analog_lcd`** declares
  that an analog port — or a named list of ports — carries a panel
  instead.

### Unchanged on purpose
- **The measured chain and the arcade video settings apply only while
  playing with the tube profile.** The stock profile keeps the system
  exactly as it was: no video settings, no files, nothing to restore.

## 2026-09-19 — unplugging a screen no longer leaves the next launch black

### Fixed
- **After you unplug one of the two screens, starting a game on the
  remaining one could leave it black.** The departed screen could stay
  marked inside the system as if it were still driving the picture; the
  layer then read the layout as already correct and made no change, and
  the game's video mode was addressed to a screen that was no longer
  there. The layer now releases any screen that is not physically present
  on every display change — and again just before a game starts — so the
  video mode always lands on the screen that is really there.

### Improved
- **The layer no longer declares the layout fine from the desktop picture
  alone**: it also checks for outputs that kept the display path after
  being disconnected — the exact condition behind the black screen above.

## 2026-09-19 — safer removal from the check screen, settings that stay right

### Fixed
- **If the removal started from the check screen does not complete, the
  machine no longer restarts on its own.** It stops and says why, and you
  can try again — before, a failed removal could still be followed by an
  automatic restart.
- **When you change a setting a second time, the newest value now wins.**
  Some settings — for example the CRT clock floor `rgs-15khz.dotclock_min`
  — could keep the older value after an edit; the layer now reads the last
  one.

### Improved
- **The problem report says so instead of going quiet when a graphics
  tool is missing** (for example when the desktop is not running), so the
  bundle can be read without follow-up questions.
- **When the installer cannot apply one of its compatibility adjustments
  to the stock launcher, it now says so and points to its log** — before,
  the install output claimed success either way.

## 2026-09-17 — Intel machines: the 480i patch is applied and kept; reports show its state

### Fixed
- **On Intel gen9 machines the 480i display patch could be skipped — or
  even removed at the next start — because the machine was misread as
  non-Intel, leaving both screens dark.** The check now reads the boot
  information reliably, so an Intel box is recognized as one: the patch
  is placed at install time (downloaded automatically when the box is
  online) and stays in place.

### Improved
- **The problem report now also shows the installed state of that
  display patch — present or not, and whether it matches the running
  system — together with the complete graphics log.** An Intel problem
  can now be closed with a single report instead of follow-up
  questions.

## 2026-09-17 — after a hard stop, and settings that stay yours

### Fixed
- **A session that ends without a clean exit can no longer leave the
  next start black.** If a game is killed by a power cut or a forced
  stop, the layer now hands back every screen setting it borrowed on the
  next boot — previously a following start on an LCD-only setup could
  come up dark.

### Changed
- **The installer no longer writes screen settings of its own.** It
  records the values your box uses (so the uninstall can hand them back
  exactly) and leaves your own settings in charge — nothing was locked in,
  so nothing needs reverting.

### Improved
- **The self-check now validates the profile folders on the box,
  including the ones you write yourself.** A broken profile is a loud,
  listed failure before it can affect a launch, and your own folders are
  recognized as legitimate — never reported as drift.
- **Clearer manual**: installing and the first start after it, the
  remote-access server that ships with the layer, and the profiles you
  maintain on the box.

## 2026-09-16 — measurement at your first game launch, native desktop always

### Fixed
- **The desktop now always starts at the native 480i.** Before the
  one-time clock measurement landed, the first boot could come up with
  an enlarged picture. The desktop is now generated identically on
  every machine, measured or not, and never depends on the measurement.

### Changed
- **The lowest-clock measurement happens the first time you launch a
  game, not at boot.** The one-time pass (a few quick mode changes on
  the tube, a couple of seconds) runs right before your first game
  starts on the CRT; every following launch reuses the remembered value
  instantly, and a graphics-hardware change re-measures by itself.
  `rgs-15khz.dotclock_min=off` still disables the measuring; a manual
  number (e.g. `25`) still pins the value yourself.
- **Your system's own clock configuration file is never touched.** The
  remembered value is kept by this layer and read when a game config is
  written, so it cannot leak into the desktop or other tools; the
  system file stays exactly as shipped.

