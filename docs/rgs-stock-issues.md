# Stock RGS issues found along the way

For the RGS team — found while certifying systems on RGS 43.41
(Batocera 43.1 base), x86_64, NVIDIA. These are stock behaviors
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
  when it exits, shipped as a commented one-liner in the stock-compat
  profile so users can opt in without editing anything). Measured
  effect: portrait art self-fills, 2767/2835 landscape artworks fill
  their holes exactly under the 4:3 full fit, the remaining 68 keep
  reduced side bars only — never worse than the integer-scaled state.
  A user-level demonstration of "extend, don't replace" — not a
  substitute for the configgen rule above, which would make every
  stock box behave well by default.
