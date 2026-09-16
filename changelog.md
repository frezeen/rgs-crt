# Changelog

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
  remembered value lives only in the emulators' settings, so it cannot
  leak into the desktop or other tools; the system file stays exactly
  as shipped.

## 2026-09-14 — the lowest clock your chain can produce (dotclock decide)

### Added
- **The layer now measures your machine and steers the emulators
  accordingly.** At the first boot it measures, with a handful of quick
  mode changes on the tube, the lowest video clock your GPU + adapter
  chain can actually produce, and remembers it. From then on, at every
  boot, the emulators are asked for a game's native resolution only
  when the chain can produce it; below that limit the picture is
  widened instead — same game, full screen, never a black screen. This
  protects consoles whose native modes need very low clocks (a class
  that would otherwise come up dark on some hardware combinations).
  The decision is persistent: it is re-taken only if the setting is
  removed (or the layer re-installed, e.g. after a hardware change).
- **One switch to keep the emulators' own behavior.** Setting
  `rgs-15khz.dotclock_min=off` in `batocera.conf` leaves their settings
  untouched and stops the measuring.

### Removed
- The old per-model clock whitelist: the on-box measurement replaces
  tables — one source of truth, per machine, not per card family.
