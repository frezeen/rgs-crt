# Changelog

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

