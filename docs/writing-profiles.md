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

When two blocks set the same setting, **the more specific one wins**:
core beats system beats emulator beats global.

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

Applied at game start, given back at game exit. If the setting did not
exist before, it is removed again — your file never accumulates junk.

### 2. Single lines in an emulator's own settings file — `[keypatch/...]`

```
[naomi]
[keypatch/configs/retroarch/config/Flycast/naomi.opt]
reicast_internal_resolution = "640x480"
```

Rewrites the named lines in the live file for the session (the path is
relative to the box's system config folder, or absolute), keeps the
previous content, restores it byte-for-byte when the game exits.
This is the right tool for any settings file the emulator owns and may
rewrite itself — it always operates on the current content, so it
cannot silently rot.

### 3. Whole files the profile provides — `[configs]`

```
[mame]
[configs]
mame.ini = configs/mame/mame.ini
```

The file from your `configs/` folder takes over the target path for
the session, the stock one is restored byte-identical at exit. Use
this only for content you author and that does not belong to the
system (a launcher config, a game list) — **never** for living files
the software rewrites on its own; a frozen copy of those rots quietly.
For those, use the keypatch above.

### 4. A program of your own — `[binaries]`

```
[mame]
[binaries]
mame = /usr/bin/mame/mame
```

The file named in your `binaries/` folder is what launches, instead of
the system's copy, for the duration of the profile's apply. Swapped
reversibly and never copied over the original. Binaries are yours to
procure; the project never ships them, the verifier only tells you
when one is expected.

### 5. Tuning the launch itself — the per-emulator sections

Some things must change after the system has assembled the command and
written its files — because the software would overwrite anything
changed earlier. Each section is named after the launcher piece it
talks to (keep the naming of the shipped profiles: `<something>Generator.py`):

| Instruction | What it does | Real example |
| --- | --- | --- |
| `cli.drop` | remove an argument from the launch command (and its value) | `libretro.cli.drop = --set-shader` — no fake scanlines on the tube, from any source |
| `cli.add` | append an argument if it is not already there | `mame.cli.add = -autosync` |
| `cli.append` | append verbatim, for pairs that need to stay together | `amiberry.cli.append = -s gfx_vsync=true` |
| `cli.set` | replace the value of an argument already present | `mame.cli.set = -video accel` |
| `config` | after the settings file is written, force single lines | `libretro.config = /userdata/system/configs/retroarch/retroarchcustom.cfg\|video_shader_enable=false` |
| `config.drop` | after writing, remove lines so the program's own default speaks again (restored at exit) | `mybox.config.drop = /path/file.ini\|ratio` |
| `mouse = off` | hide the host cursor for that emulator | `xenia.mouse = off` |
| `runtime_dir` | make sure a folder exists before the emulator runs | `azahar.runtime_dir = /userdata/saves/3ds/azahar-emu` |

Everything here is session-scoped: archived and restored on exit like
the rest.

### 6. Asking for a specific display mode — `[display] mode`

```
[amiga1200]
[display]
mode = 640x464@50
```

Asks, for that system only, for a resolution/refresh the tube can
handle — computed with the same safety rules the rest of the layer
uses, switched live, back to the desktop signal at exit; a refusal
leaves the launch on the standard signal instead of breaking it.
Advanced: the shipped tube profile does not need it (it lets each
emulator choose its native mode) — reach for it only for a system you
have measured and know better than the defaults.

## Recipes that do the rounds

**"Give my arcade games the real MAME":** the `[mame]` block of the
tube profile above — settings that redirect the launch (1), the binary
swap (4), an authored `mame.ini` (3), and `cli.drop` to stop the
launcher's hardcoded audio override from beating the ini (5).

**"Stop the smoothing/filters on this system":** a `[batocera.conf]`
key if RGS knows one (`snes.smooth = false` style), or `cli.drop` +
`config` for what only RetroArch itself forces.

**"Change one option deep in an emulator's file, only while I play":**
the keypatch (2) — nothing on disk survives the session.

**"Adopt the one-line bezel fix":** the stock-compat profile ships a
commented corrective (the black-border case described in
[Stock RGS notes](rgs-stock-issues.md) §2) — uncomment two lines, run
`./verify.sh`, done. That is profile maintenance in one move.

## Maintenance rules that keep you safe

- **Reversibility is the contract.** Whatever your profile applies at
  game start, the exit gives back — if you find a change that cannot
  be undone, that is a design error: fix it before using it.
- **Test the undo:** install, launch the system you tuned, exit,
  `./verify.sh`. Clean after the exit is the proof the profile is
  well-formed in practice, not just on paper.
- **Keep it small.** One system, one effect, then the next. A profile
  that touches everything is a profile you cannot debug.
- **Comment your whys.** The shipped specs carry the reason and the
  measured result beside each group — six months later, that is the
  difference between tuning and archaeology.
- **When a knob seems missing, say so.** A genuinely missing
  capability is a framework question for the maintainers, not a
  per-profile hack.
