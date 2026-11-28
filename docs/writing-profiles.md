# Writing and maintaining profiles

This layer runs INSIDE stock RGS and reverts cleanly. Profiles are the
one part of it that is yours to shape: this page is the hands-on
manual for writing one, and for keeping the existing ones in shape.

If you only want to understand what a profile is, read
[Profiles](profiles.md) first. This page is the toolbox.

## Where profiles live, and how one takes effect

Every profile is a folder. The ones you use on the box live in
`/userdata/system/crt-dual/profiles` — the folder your standard install
deploys to (`verify.sh` prints the location as its first line, in case
a box ever moved it). The rules of the game:

- **A new folder is a new profile.** Drop it in and it is discovered
  at the next game launch — if it fits the displays you have plugged
  in, it shows up in the chooser alongside the others.
- **Nothing you change takes effect mid-game.** Profiles belong to the
  game boundary: edit between games, test with the next launch.
- **`./verify.sh` checks every profile on the box.** A malformed spec
  is a loud, listed failure there — never a surprise mid-game.
- **Reinstall overwrites the package copy of the shipped profiles.**
  If you edit a shipped one, keep a copy of your version outside the
  package (the same place the install keeps its own backups), or build
  your own folder next to it instead.

A profile folder looks like this:

```
my-profile/
├── spec.conf      ← the profile itself (plain text — everything below)
├── configs/       ← optional: whole files it provides
└── binaries/      ← optional: programs it swaps in (yours to procure)
```

## The anatomy of a spec.conf

```
label = My Tube Profile
description = what this one is for

[global]                 ← applies on EVERY launch under this profile
[display]
target = crt             ← games drive the tube; the other screen sleeps

[batocera.conf]          ← global settings, written at game start,
global.smooth = false    ← reverted at game exit — exactly the keys
                         ← you already know from the RGS settings file

[snes]                   ← a SYSTEM block: applied only to SNES games
[batocera.conf]
snes.ratio = 4:3
```

Blocks choose their target; sections say what kind of change each line
is. The block types:

| Block | Applies to |
| --- | --- |
| `[global]` | every launch under the profile |
| `[snes]` (or `[system.snes]`) | games of the system `snes` |
| `[emulator.libretro]` | every game whose emulator resolves to libretro — one block for a whole family |
| `[core.snes9x]` | games running that specific core |
| `[<system>["<rom>"]]` | one title, matched by exact filename or stem (extension optional), with every section inside the block scoped to it |

Repeated generator operation keys in different per-game blocks remain
separately scoped: only the launched title's declarations reach the
launcher, in declaration order. For example, targeting a single title:

```
[gaelco["Gaelco Championship Tuning Race.squashfs"]]
[batocera.conf]
gaelco["Gaelco Championship Tuning Race.squashfs"].gamescope = 1
```

When two blocks set the same setting, **the more specific one wins**:
per-game beats core beats system beats emulator beats global. Bare
`[batocera.conf]` keys (like `videomode = 640x480i`) work inside
`[<system>]` (qualified as `<system>.<key>`) and inside `[emulator.*]` /
`[core.*]`, where they apply as `<system>.<key>` **only to systems that
have a block in the profile** — an unlisted system does not inherit bare
keys from `[emulator.*]` or `[core.*]`, whereas dotted keys and
per-emulator generator operations apply whenever the emulator or core
matches.

If a system or per-game block declares `<system>.emulator` or
`<system>.core`, that pin overrides even when EmulationStation passes
`-emulator` or `-core` on the launch command line. The engine overlays
the profile pin **before** matching `[emulator.*]` and `[core.*]` blocks
(so pinning `gaelco.emulator = mame` automatically pulls in
`[emulator.mame]` on that launch). A stock or user-saved per-game pin in
`batocera.conf` still takes precedence over a system-level profile pin
(`per-game > system`), while a profile's own per-game pin overrides both.

> **Gotcha that bites everyone once:** every `[...]` header is a block.
> ini-style sub-headings like `[Graphics]` do not exist here — such a
> header would be read as a system block named `Graphics` and its keys
> quietly ignored. Never write one.

## The toolbox: what a profile can do

### 1. Settings for the system itself — `[batocera.conf]`

Each line is a setting exactly as it lives in the RGS settings file,
and that is the point: RGS reads them **before** it decides how to
launch, so a profile can redirect the launch itself.

```
[mame]
[batocera.conf]
mame.emulator = mame          # use the standalone arcade emulator...
mame.core = mame              # ...with its own core
mame.switchres = 1            # ...in native-resolution mode
[n64]
[batocera.conf]
n64.core = parallel_n64       # or: pick a different core for this session
```

Applied at game start, given back at game exit. Existing keys are
replaced **in place** (keeping their position in `batocera.conf` rather
than moving to the end of the file); if a key appears more than once in
`batocera.conf`, only the last (effective) occurrence is modified and
restored. If the setting did not exist before, it is removed again — your
file never accumulates junk. Per-game keys (`<system>["<rom>"].key =
value`) and per-folder keys (`<system>.folder["/path"].key = value`) work
here too, and leaving a value empty (`gaelco.videomode =`) removes a
stock setting for the duration of the session and restores it when the
game exits.

### 2. Single lines in an emulator's own settings file — `[keypatch/...]`

```
[naomi]
[keypatch/configs/retroarch/config/Flycast/naomi.opt]
reicast_internal_resolution = "640x480"
```

Rewrites the named lines in the live file for the session (the path is
relative to the box's system config folder, or absolute), keeps the
previous content, and restores it byte-for-byte when the game exits. If
the target file does not exist yet, it is created for the session and
removed again on exit. UTF-8 BOM headers (used by emulators such as
PPSSPP) are handled automatically, and duplicate occurrences of a
patched key are collapsed during the session. This is the right tool for
any settings file the emulator owns and may rewrite itself — it always
operates on the current content, so it cannot silently rot. Legacy
flat-file injection headers (`[configs/<path>]`) are removed and rejected
at validation time — always use `[keypatch/<path>]` for living files.

If the setting must live inside a named section of the file (INI files
group their keys under `[Section]` headers), write the section in front
of the key — the line lands in that section (created if the file has
none yet, and removed on exit once empty) and is removed from it again
at exit:

```
[psp]
[keypatch/configs/ppsspp/PSP/SYSTEM/ppsspp.ini]
Graphics/DisplayStretch = True
```

A key written without a section keeps the plain behavior (anywhere in
the file), though adding a flat key to a file that already carries
`[Section]` headers triggers a warning because it lands outside any
section and is inert — always use `Section/Key` for INI files.

Some emulators keep a `<key>\default` marker beside every setting (Qt
and QSettings-based programs such as azahar do this, and they rewrite
those markers each time they save). While the marker says `true` the
program ignores the value on the line and uses its own built-in default
instead — so patching the value alone is silently discarded. Patch the
marker with it:

```
[3ds]
[keypatch/configs/azahar-emu/qt-config.ini]
Layout/custom_top_width = 640
Layout/custom_top_width\default = false
```

### 3. Whole files the profile provides — `[configs]`

```
[mame]
[configs]
mame/mame.ini = configs/mame/mame.ini
```

The file from your `configs/` folder (named on the left) takes over the
target path (on the right, relative to `/userdata/system/` or absolute)
for the session, and the stock one is restored byte-identical at exit.
The same config file can be declared in more than one block as long as
every declaration maps to the same target path (for example `mame/mame.ini`
in both `[mame]` and `[gaelco]`). If a target file is already
byte-identical to the profile copy (for example left behind by a hard
crash), the engine treats it as absent stock rather than archiving your
profile file as stock. Use this only for content you author
and that does not belong to the system (a launcher config, a game list)
— **never** for living files the software rewrites on its own; a frozen
copy of those rots quietly. For those, use the keypatch above.

### 4. A program of your own — `[binaries]`

```
[mame]
[binaries]
mame = /usr/bin/mame/mame
```

The file named in your `binaries/` folder is what launches, instead of
the system's copy, for the duration of the profile's apply — swapped
reversibly via symlink retargeting (or zero-copy rename on non-overlay
paths) without copying large files or creating overlay whiteouts, and
restored cleanly on exit or reboot. For shipped profiles, install fetches
pinned binaries from `binaries.lock` into the shared `profiles/binaries/`
tree, which is resolved automatically for every profile declaring the
key (a profile-local `binaries/` folder overrides if present). Custom or
offline binaries can be placed in either folder; if a declared binary is
missing, the engine logs a warning and skips only that executable swap
so the rest of the profile still applies.

### 5. Tuning the launch itself — the per-emulator sections

Some things must change after the system has assembled the command and
written its files — because the software would overwrite anything
changed earlier. Each section is named after the launcher piece it
talks to — whether a stock Batocera generator or an RGS custom generator
such as `linuxloaderGenerator.py`, `odinGenerator.py`, or
`sm2Generator.py` (`<something>Generator.py`). Prefix each key with the
generator's short/folder name (for example `mame`, `libretro`,
`hypseus_singe`, `linuxloader`); bare keys inside a matching block
qualify automatically, while already-prefixed keys stay untouched:

| Instruction | What it does | Real example |
| --- | --- | --- |
| `cli.drop` | remove an argument from the launch command (and its value) | `libretro.cli.drop = --set-shader` — no fake scanlines on the tube, from any source |
| `cli.add` | append an argument if it is not already there | `mame.cli.add = -autosync` |
| `cli.append` | append verbatim, for pairs that need to stay together | `amiberry.cli.append = -s gfx_vsync=true` |
| `cli.set` | replace the value of an existing argument, or append it if absent | `mame.cli.set = -video accel` |
| `config` | after the settings file is written, force single lines | `libretro.config = /userdata/system/configs/retroarch/retroarchcustom.cfg\|video_shader_enable=false` |
| `config.drop` | after writing, remove lines so the program's own default speaks again (restored at exit) | `mybox.config.drop = /path/file.ini\|ratio` |
| `config.xml` | after writing, force settings in a settings XML file, one named setting at a time (restored at exit) | `openmsx.config.xml = /userdata/system/configs/openmsx/share/settings.xml\|blur=0;scanline=0;glow=0` |
| `mouse = off` | hide the host cursor for that emulator | `xenia.mouse = off` |
| `runtime_dir` | make sure a folder exists before the emulator runs | `azahar.runtime_dir = /userdata/saves/3ds/azahar-emu` |
| `ensure` | before the launch, put a missing program file back into the folder the program reads | `openmsx.ensure = /usr/share/openmsx/skins/DejaVuSans.ttf.gz\|/userdata/system/configs/openmsx/share/skins/DejaVuSans.ttf.gz` |

Repeating the same operation accumulates entries in declaration order
(for example multiple `config` or `ensure` lines). On each launch the
operations run in order: `ensure` -> `runtime_dir` -> generator runs ->
`cli.*` -> `config` -> `config.xml` -> `config.drop`. Post-generate
edits (`config`, `config.xml`, and `config.drop`) are archived on first
apply and restored byte-for-byte on exit — only `ensure` is a permanent
repair that stays in place, because taking a missing stock file away at
exit would break the next launch again.

Two notes on `config.xml` and `ensure`:

- **`config.xml` edits the file, it never rewrites it.** A named setting
  already in the file keeps its place in it; a setting that is missing is
  added inside the settings section, with the same indentation as the ones
  around it. The rest of the file — header included — comes back exactly
  as the program wrote it on exit. Give the setting the name the program
  calls it and the value the program expects.
- **`ensure` fills a hole; it never replaces.** It is for a folder the
  program copies only once, at first use: when RGS updates, that folder
  keeps the old files and the program looks for something that is not
  there. Point it at the current program file and the missing copy is
  restored once, quietly.

### 6. Asking for a specific display mode — the system's `videomode` key

```
[amiga1200]
[batocera.conf]
amiga1200.videomode = 640x464.50
```

Asks, for that system only, for a resolution/refresh the tube can
handle — declared the same way RGS's own video-mode settings are, with
one extra capability: the value can be **bare** (`640x464`) to let the
safety preset place it at the nearest clean refresh, or **dotted**
(`640x464.50`) to hand the exact rate you want to the same safety
preset that governs every mode of the system — it delivers it as asked
or places it at the nearest safe refresh by its own rules. The launcher
switches to it on its own, computed with the same safety rules the rest
of the layer uses, and returns to the desktop signal at exit; a refusal
leaves the launch on the standard signal instead of breaking it. Each
dotted value (`640x480i.59.94`, `640x480i.57.524160`) registers its own
pool entry so multiple refresh rates at the same resolution coexist
cleanly (`max-*`, `auto`, and empty session-deletion values pass
validation untouched, while literal rasters are validated for shape and
unique pool-name timing). Advanced: the shipped tube profile uses this
key for the systems it
has measured (the compatibility map shows which ones) — reach for it
for another system only after you have measured it yourself.

### 7. A command pair for the session — `[runtime]`

For example, adjusting a helper program's font size while you play
(hypothetical — a recipe, not a shipped profile):

```
[+rgs]
[runtime]
font.apply = sed -i 's/-fs 16/-fs 10/' /userdata/system/crt-dual/session/xterm.args
font.undo = sed -i 's/-fs 10/-fs 16/' /userdata/system/crt-dual/session/xterm.args
env = RGS_CRT_XTERM_FS=10
path.prepend = /userdata/system/crt-dual/src/runtime/bin
```

The section belongs to the block above it, and that block is the system's
identifier written exactly as the menu names it — here `+rgs` (the stock
utility menu), not `rgs`. A block naming a system that does not exist is
accepted and simply never applies, so take the name from your emulator's
system list rather than from the folder you think it is.

This is the **last resort** of the toolbox: reach for it only when the
need is not a setting (1), a line in a settings file (2), a whole file
(3), a program (4) or a launch option (5). `<id>.apply` runs at game
start, its `<id>.undo` runs at game exit in reverse order, with the
same rights the launcher itself has. **Both halves are mandatory:**
`./verify.sh` rejects a profile whose command has no undo — a change
that cannot be undone is a design error, not a profile.

`env` and `path.prepend` hand the game itself extra environment entries
(a variable, a folder searched for programs) for that one launch. They
must be declared this way and never faked inside a command: the
launcher only passes its own environment to the game, so the entries
are planted in the launcher's own process and die with it — gone by
construction, nothing to undo. `[global]`, system blocks, typed blocks,
and per-game blocks can each declare their own `[runtime]` section, and
each command, `env`, or `path.prepend` entry runs only when its owning
block matches. Each command runs under `/bin/sh -c` with a 15-second
timeout; a command that fails or times out logs a warning and the game
runs anyway, and because it is not recorded as applied, its undo does
not fire at exit.

Two built-in engine `env` levers used in the shipped profiles:

- `env = RGS_STDIO_DETACH=1` — streams game stdout/stderr with `[stdout]`
  and `[stderr]` tags and returns immediately when the direct game
  process exits instead of waiting on background gamescope/Wine pipe
  holders.
- `env = RGS_DROP_CAP_NET_ADMIN=1` — drops Linux `CAP_NET_ADMIN` for the
  launch tree so cabinet titles cannot reconfigure `eth0` and knock out
  LAN, NFS, or SSH.

## Recipes that do the rounds

**"Give my arcade games the real MAME":** the shipped profile puts the
binary swaps in `[emulator.mame]` and `[core.mame]` (4), an authored
`mame.ini` in `[mame]` (3), and `cli.drop` in `[emulator.mame]` to stop
the launcher's hardcoded audio override from beating the ini (5), while
leaving standalone vs libretro to your EmulationStation choice (add
`mame.emulator = mame` in `[batocera.conf]` if you want to pin it).

**"Stop the smoothing/filters on this system":** a `[batocera.conf]`
key if RGS knows one (`snes.smooth = false` style), or `cli.drop` +
`config` for what only RetroArch itself forces.

**"Change one option deep in an emulator's file, only while I play":**
the keypatch (2) — nothing on disk survives the session.

**"Adopt the one-line bezel fix":** the stock-compat profile ships a
commented corrective (the black-border case on integer-scaled bezels).
Copy that profile folder to a name of your own, uncomment the two lines
there, run `./verify.sh` (your folder is validated, never drift) — done.
That is profile maintenance in one move.

## Maintenance rules that keep you safe

- **Reversibility is the contract.** Whatever your profile applies at
  game start, the exit gives back — if you find a change that cannot
  be undone, that is a design error: fix it before using it.
- **Test the undo:** install, launch the system you tuned, exit,
  `./verify.sh`. Clean after the exit is the proof the profile is
  well-formed in practice, not just on paper.
- **Keep it small.** One system, one effect, then the next. A profile
  that touches everything is a profile you cannot debug.
- **Comment your whys.** The shipped specs carry a single factual line
  above each non-default override stating why the mechanism is needed
  (never dates, GPU names, or test history).
- **What `./verify.sh` checks on every profile:** non-empty `label`,
  valid `[display] target` (`crt` or `lcd`), valid `videomode` raster
  shapes and unique pool-name timings, paired `<id>.apply`/`.undo`
  commands, no legacy `[configs/<path>]` headers, no conflicting
  `[configs]` targets, existing `[configs]` source files, and valid
  `[keypatch]` lines (missing `[binaries]` warn without failing). Crash
  recovery runs automatically at boot and before the next launch
  (lock-serialized).
- **When a knob seems missing, say so.** A genuinely missing
  capability is a framework question for the maintainers, not a
  per-profile hack.
