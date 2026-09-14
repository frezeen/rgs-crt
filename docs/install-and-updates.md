# Install & updates

This layer runs INSIDE stock RGS and reverts cleanly. This page is the
full story of what that means: what the install does, what "clean"
means, and what happens when RGS itself updates underneath.

## Installing

The target of the install is an **updated, stock RGS system** — the RGS
you get by running RGS's own installation script over an untouched
Batocera, then running their update tool at least once (the RGS upgrade
script inside EmulationStation's Batocera config list). The updater run
is not a formality: it completes the RGS setup and stamps the version
record that this layer's install and self-check read. A box where RGS
was fullinstalled but never updated is refused outright, and the
message says exactly what to do. Beyond that, the details of building
or updating RGS itself belong to RGS's official channels, not to this
manual. This layer extends that stock RGS from the inside; it assumes
nothing beyond it and modifies none of it permanently.

`./install.sh` installs onto a **stock box only**. If the box already
has the layer, it says so and stops — the answer is `./uninstall.sh`
first. There is deliberately no "upgrade in place" path: every version
is installed fresh onto stock, which is what keeps the promise that
removal returns you to exactly where you started.

At install the system:

- records the RGS and Batocera versions it is being installed onto
  (this is the memory its later self-check compares against),
- takes a whole-file snapshot of the stock files it has no pristine
  copy of anywhere else (the system config and the version record,
  plus the launcher's mode script, which the layer adjusts to
  understand the per-game video-mode keys — the adjustment carries the
  stock behavior untouched wherever the layer is absent, the insurance
  copy makes the uninstall restore byte-exact, and the boot service
  re-applies the adjustment after every system update),
- backs up the value of every setting it will own before setting it,
- places its hook so it is consulted at every game start and stop, and
  its boot service so it runs late, after RGS's own boot setup.

When it finishes there is no automatic reboot: you connect the CRT,
reboot once, and the first tube session begins.

## AMD machines and the classic display stack

On an AMD machine, the install also chooses the display stack the tube
will receive its picture through. Kernels from **6.19** onward can feed
an analog CRT with the modern stack; earlier kernels can feed only the
digital ports — the flat panel lights up, the tube stays dark. So on a
pre-6.19 kernel with one of those AMD cards, the layer pins the classic
display stack at install (it also re-checks the pin at every boot: an
RGS update to a kernel at 6.19 or later lifts it on its own). The choice
is yours: `rgs-15khz.amdgpu-legacy=off` in `batocera.conf` keeps the
modern stack and the layer will not touch the choice again.

## Intel machines and the display patch

On Intel gen9 integrated graphics (most desktop Intel chips from roughly
6th to 9th generation), the system's own display driver refuses to feed
an interlaced picture to the tube unless a small patch is applied to it.
Without it, progressive 15 kHz pictures work but true 480i does not —
which is exactly what the tube needs for the desktop and for
console-class systems.

So on an Intel machine of that generation, the install places the
display patch from the community project
[amxcs/batocera-crt-15khz-intel](https://github.com/amxcs/batocera-crt-15khz-intel)
(GPL-2.0, credited below and in the main page). It fetches the ready-made
patch for the exact system the box runs — **this requires the box to be
on the network at install time**. If that is not possible, place the
patch file yourself in `src/service/i915/binaries/` inside the project
folder before installing; the verifier warns, without failing, while it
is missing.

The patch survives an RGS update the same way the rest of the layer's
boot work does: it is checked against the running system at every boot,
and if a system update replaced the driver underneath, the layer keeps
the stock driver loading instead — the screen stays alive, and the
verifier tells you the patch needs to be refreshed (recovery: the usual
`./uninstall.sh` + `./install.sh`). Nothing about the patch is active on
non-Intel machines: nothing is placed, nothing to manage.

## The arcade binary is yours to supply

The tube profile runs arcade games (the MAME systems) through
**GroovyMAME** — the special MAME build that generates video modes for
arcade CRTs on the fly. Its binaries are large, third-party and
license-sensitive, so this project never ships them, in this repository
or on the box.

To light up the arcade path:

- get a GroovyMAME build for Linux x86_64 (the official GroovyMAME
  project is the source; the certification here was done on **0.289** —
  newer builds usually behave, but they are your re-test, not our
  claim);
- place the executable as:
  `/userdata/system/crt-dual/profiles/rgs-15khz/binaries/mame` — the
  file is simply named `mame`, and must be runnable;
- run `./verify.sh`: while the binary is absent the verifier WARNs
  printing that full expected path, and still reports clean — every
  non-arcade system works untouched; once it is placed, the warning
  disappears and arcade launches use it.

Without the binary, what you skip is the arcade certification (the
native-mode per-game path described in the compatibility map); nothing
else in the layer is affected.

## `./verify.sh` — the gate

Exit 0 = clean. There are exactly **two** clean states and anything
mixed between them fails with a listing:

- **INSTALLED** — every piece the install placed is present and
  byte-identical to what it should be, the profiles are valid, the
  settings the layer owns are set, the recorded RGS version still
  matches the live one, and no trace of any game session is stranded.
- **STOCK** — nothing of the layer is left (before any install, or
  after a complete uninstall).

The verifier **warns** (never fails) about missing user-procured
binaries: they are yours to download, and the warning tells you which
ones and where they go, so you can test everything that does not need
them.

Run it after install, after uninstall, and whenever something looks
wrong. It is also what the check tool and the update self-check agree
with — a green `verify.sh` is the definition of "this system is fine".

When something needs reporting to the developers, `./report.sh` (the
companion next to these three) bundles every log they need into one
zip — the project README explains the two-minute flow.

## Removing

`./uninstall.sh` restores the exact stock state: stops and removes its
services, takes out every file it added, restores each owned setting to
the value it had before the install (or removes the line, if the
setting did not exist), and leaves your snapshot insurance copy outside
the package (nothing of the pre-install state is ever destroyed). It
refuses to run mid-game. Afterwards `./verify.sh` must report the clean
**STOCK** state — that is the reversibility proof, and it is the same
proof the project certified with before any CRT feature existed.

## After an RGS system update

An RGS update changes the system under the layer — and the layer knows
it is not the only actor, so it never silently hopes for the best:

- On the first boot after an update, the layer re-checks itself against
  the **future** system state (an RGS update stages new system files
  that activate at boot).
- Everything still lines up → it quietly carries on, and re-records the
  new version. You notice nothing.
- It cannot guarantee itself → it **holds**: the CRT-targeting profiles
  step aside so games keep launching with plain stock behavior,
  nothing is deleted, and the boot log + the check tool tell you.
  Recovery is always the same two commands: `./uninstall.sh` then
  `./install.sh` from the current package.
- Each launch also passes a fast runtime check; a failing check logs
  loudly and the game still launches stock-safe — the layer never
  blocks a game to make a point.

"Extend, don't replace" cuts both ways: an RGS update always wins, and
the layer either re-qualifies against it or gets out of the way.

## The check tool

An entry in the "Batocera config" menu (the same list as RGS's own
tools) shows the verdict for every active screen:

| Screen | Meaning | Your options |
| --- | --- | --- |
| **GREEN** | Everything is aligned with what was installed. | Nothing to do. |
| **RED** | An RGS update changed the system and the self-check could not vouch for it. | ESC — keep playing, games run exactly like stock while held. ENTER — uninstall the layer and reboot: pure stock RGS, one press. |

Today the tool only checks. Tomorrow it updates: the same entry —
the very place where RGS's own update scripts live in the menu — is
designed to fetch a new version of this layer and apply it as a clean
uninstall + install of the fresh package, one press, same guarantee.
Deliberately built as a slot for that future; not wired today.

## Known noise (harmless, ours, by design)

If you read the launch log of a **stock-profile session on a
box with a CRT attached**, you may find exactly two lines per session
of the form `checkModeExists invalid video mode ...`. They are noise
produced by the layer's own desktop setting being validated by stock
machinery — not a fault and not an RGS bug. One of the two rejections
is actually load-bearing: it stops the system from clobbering the tube
desktop the moment a session ends. The desktop stays correct, games
are unaffected, and there is nothing to fix. In pure-CRT sessions
nothing is logged.

## Getting a new version of the layer

This repository is republished as a chain of certified snapshots. When
a new version is announced: download the ZIP again, uninstall, install
from the fresh folder. No git is needed on the box — the ZIP is always
the latest published state, and the published tree is the one that was
tested, never a pile of development leftovers.
