# Stock RGS issues found along the way

For the RGS team — found while certifying systems on RGS 43.54–43.63
(Batocera 43.1 base), x86_64, NVIDIA and AMD. These are stock behaviors
(display-independent: they reproduce on LCD too), and this layer runs
INSIDE stock RGS and reverts cleanly — none of them is caused by it.

**Inclusion test:** an item lands here only if it reproduces on an
untouched stock RGS box **without this product installed**. Anything
that requires one of our files or settings is our behavior and is
documented on our own pages — a misattributed bug would be a false
accusation against the platform this project is a gift to.

## 1. SC-3000 tries the wrong emulator core and fails to boot

- What you see: a SC-3000 game fails with "Failed to load content" /
  "Unknown system '<game title>'" in the console output. EmulationStation
  shows "mess (default)" as the core, and the system config carries no
  explicit choice — yet the launch runs the **mame** core.
- Why it fails: with the mame core the launcher takes the arcade branch
  and hands the game TITLE where a driver name is expected. The mess
  branch writes it correctly.
- Workaround today: in the game's settings, pick emulator **libretro**
  with core **mess** explicitly — the game then boots (verified: Bomb
  Jack, native 280x216).
- Suggested fix: default core `mess` for sc3000, and an audit of the
  other single-core mess systems for the same mis-resolution.

## 2. Integer-scaled MAME frames leave a black border inside game bezels

- What you see (LCD): the game picture sits in the middle of the
  bezel's hole with an even black border all around, instead of
  filling the hole as the artwork intends.
- Measured (88games): bezel hole 1403x1044; game frame 1196x896 (the
  largest integer multiple of the 256x224 native that fits 1080p);
  symmetric margins of 103/104 and 74/74 pixels.
- The contradiction is inside the stock settings themselves: the pack
  sets MAME to integer scaling, while the landscape bezel art is sized
  for the 4:3 full fit (1392x1044 — 0.8% from the hole). Every game
  whose integer step lands below the hole shows the border. Portrait
  bezels hide it by design: their holes are narrower than the frame,
  so the art clips the game instead of framing black.
- Population check (the whole pack, not a sample): 4216 game-level
  MAME artworks; 1379 portrait (self-filling); 2835 landscape, of
  which 2767 show exactly this border; 68 widescreen-hole cases. The
  mismatch is the normal state, not a per-game fluke.
- The existing precision mechanism (`custom_viewport_*`) only exists
  in `.info` files — 208 of them, all under `systems/`, none for the
  `games/` artwork tree that triggers the problem.
- Suggested fix (one rule, zero per-game content): when the
  auto-selected artwork is a `games/` image with no `.info`, derive
  the viewport from the artwork's own transparent hole (computable at
  config time), or skip integer scaling for games using per-game art.
  Generating thousands of `.info` files is the one fix to avoid.
- Demonstrated alternative while upstream decides: the mechanism this
  project uses for exactly this case — a session-scoped setting
  (`mame.integerscale = 0`, applied when the game starts, given back
  when it exits, shipped commented in the stock-compat profile (a
  block header plus the setting) so users can opt in without editing
  anything). Measured
  effect: portrait art self-fills, 2767/2835 landscape artworks fill
  their holes exactly under the 4:3 full fit, the remaining 68 keep
  reduced side bars only — never worse than the integer-scaled state.
  A user-level demonstration of "extend, don't replace" — not a
  substitute for the configgen rule above, which would make every
  stock box behave well by default.

## 3. FM Towns: a `.chd` is offered by the system list and cannot be read by the shipped emulator

- What you see: a `.chd` for `fmtowns` is listed like any other game.
  Launching it boots the Towns BIOS (logo on screen) and stops at
  "Please set the system disk" (the Japanese-localized on-screen
  message) — insert the system disk — with the CD-ROM device empty. The owner also reports a warning at launch that the
  emulator does not support this format. The warning names the format, not
  the cause, so there is no path from the message to the fault.
- Measured (2026-10-16, RGS 43.63, AMD box, launch log): the generator built
  `Tsugaru_CUI <bios>/fmtowns … -FD0 "<game>.chd"` — a CD image handed to the
  FLOPPY device. The shipped `/usr/bin/Tsugaru_CUI`'s own `-HELP` is the
  authority: `-CD image-file-name` takes **ISO or CUE**. A `.chd` is a format
  this emulator does not read, on either device.
- The routing half: the stock `tsugaruGenerator.py` maps only `.iso/.cue/.bin`
  to `-CD` and sends everything else — a `.chd` included — to `-FD0`. So even
  a hypothetical CHD-capable build would still receive the disc as a floppy.
- Why it cannot work today: three stock surfaces disagree. The system's
  accepted-extension list advertises `.chd` (the same list is written into the
  system's `_info.txt` inside the roms folder), the generator has no `-CD`
  route for it, and the emulator cannot read it. Any one of them alone would be
  survivable; together they make a list entry that can never boot.
- Not ours (the page's inclusion test): no file, key or hook of this layer is
  in this path — there is no `fmtowns` block in the profile, and the launched
  argv is the stock generator's, token for token. The failure is independent of
  the display too: it is a content-format failure and would be identical on the
  LCD.
- Workaround today: convert the image to CUE/BIN (`chdman extractcd`, shipped on
  the box at `/usr/bin/chdman`) or supply the game as `.cue`/`.iso` — the
  generator then routes `-CD` by itself.
- Suggested fix: remove `.chd` from the FM Towns accepted extensions (it is the
  only CD-class entry there the emulator cannot read), or keep it and give the
  generator a `-CD` route for it once the emulator can read CHD. Either way the
  list and the emulator stop contradicting each other.
- Observed in the same delivery (2026-10-11): the system's `gamelist.xml` lists
  a second title whose file is not present in the roms folder — a list entry
  that can only fail.

## 4. Taito Type X: Tate (vertical) shmups render sideways on stock RGS

- What you see: launching `Raiden IV (1.00J) (Portrait)` or `Raiden III (2.01J) (Portrait)` displays the game rotated 90 degrees sideways, requiring physical monitor rotation or head-tilting.
- Measured (2026-10-18, stock RGS 43.65 on LCD): reproduces on untouched stock RGS on LCD (`rgs-stock`). Unlike `GigaWing Generations` (which carries an authored ReShade rotation pipeline in its loader template `gigawing-generations.yaml`), `raiden-4-typex.yaml` and `raiden-3-typex.yaml` omit ReShade rotation directives entirely, leaving the raw Tate raster unrotated on horizontal displays.
- Not ours (the page's inclusion test): reproduces bit-for-bit on stock LCD with no layer files or hooks active; confirmed identical behavior on LCD by the owner.
- Suggested fix: add ReShade 90-degree CCW/CW rotation configuration to `raiden-3-typex.yaml` and `raiden-4-typex.yaml` in the stock RGS loader profiles matching the mechanism already used in `gigawing-generations.yaml`.

