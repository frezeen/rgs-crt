# Changelog

## 2026-09-14 — per-game rasters, correct first launch, zero-touch install

### Added
- **Per-game exact rasters, through RGS's own resolution channel.** A
  game or system can now declare the exact signal it was designed for,
  in two forms: bare (e.g. `256x256` — automatically scaled into the
  standard 15 kHz family) or exact (e.g. Model 2's native
  `693x520i` at 57.52 Hz — taken literally). To carry this, the layer
  installs a small marked extension inside RGS's resolution tool: at
  game start the declared mode is announced and generated ahead of
  time, so the tube shows the native raster instead of the nearest
  stock mode. The extension is clearly marked, the stock tool is kept
  as a byte-exact snapshot, and uninstall removes the extension
  cleanly (a hand-modified tool is never overwritten).
- **RGS updates no longer break the launcher patch.** When an RGS
  update re-copies its own launcher files over ours, the layer
  re-applies the resolution patch automatically at the next boot — no
  manual re-run of the installer needed after an update.

### Fixed
- **The first game after boot now starts at the right resolution on
  LCD-only setups.** With the tube absent, the display server could
  still be holding an old mode when the first game launched: the
  launcher then read a stale geometry and RetroArch could come up
  lowered and mis-sized, with game configs written at the wrong size.
  The pre-launch preparation now runs in two steps — release the
  outputs, then re-initialize the game display from a clean state —
  which forces a real mode reprogram. Every launch now reads coherent
  geometry, on the CRT profile and the stock profile alike.

### Changed
- **Installation is zero-touch.** Installing (or re-installing) the
  layer no longer writes any resolution setting into the launcher
  config: a fresh stock box already launches correctly with no keys at
  all, because the stock launcher treats a missing key exactly like its
  "auto" setting. The install only backs up your current settings; if a
  hand-edited resolution key is later found on the box, the health
  check reports it as drift instead of silently keeping it.
- **Profiles are slimmer, with no behavior change.** 33 redundant
  "max-640x480" resolution keys were removed (one global plus one per
  system). EmulationStation already sits at 480i on the tube, so
  re-forcing the same mode at every game launch was a no-op, and the
  per-system copies simply repeated the global one. Verified live on
  the cab with an Xbox title (the most exposed class) and a Model 2
  title. The real rasters are untouched: Model 2 keeps its native
  693x520i at 57.52 Hz, Pyxel keeps 256x256.
- **The stock (LCD) profile needs no forced key either.** With the
  launch fix above, the belt used to pin the LCD at 1920x1080 is gone:
  LCD sessions read the right mode on their own.
- **The health check watches the new channel.** It verifies that the
  launcher extension is in place together with its stock snapshot (so
  uninstall can always restore), that the extension is not missing when
  the profile needs it, and that nothing is left behind in stock state.
- **Snappier return to the menu.** The watcher now tracks the game
  lifecycle: the moment a game ends, the dual layout (menu on the tube,
  desktop on the LCD) is restored on the watcher's first cycle — about
  a second, measured live.

### Removed
- The boot-time "self-heal" fallback in the dual service: settings are
  now restored at one predictable point only — the watcher, when a game
  ends — instead of an extra writer rewriting things at boot.
