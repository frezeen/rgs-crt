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

One command installs the layer, and the same command updates it
later. Over SSH, as root:

```
curl -fsSL https://raw.githubusercontent.com/frezeen/rgs-crt/main/get.sh | sudo bash
```

It fetches the current release, and when the box already has the layer
it removes the old one first — every version still lands fresh onto
stock, which is what keeps the promise that removal returns you to
exactly where you started. Then it installs the new release and checks
itself. No git is needed on the box. Updating needs no preparation on
your side: nothing has to be removed by hand first.

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
- records your boot-display settings before touching anything (the layer
  pins none of them — your box keeps its own values),
- is consulted at every game start and stop, and its boot service —
  order-independent against RGS's own boot setup by design, so neither
  can wait for the other.

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

## The lowest clock your chain can produce (dotclock)

Some GPU/adapter combinations cannot produce the very low video clocks
that a few consoles' native resolutions need — asking for them shows a
black screen instead of a game. At the **first game you launch on a CRT**
the layer measures the real limit of your chain (a few quick mode changes
on the tube, once, before the game starts). On the RetroArch path it then
asks for the game's native resolution only when the chain can produce it;
below the limit the picture is widened instead — same game, full screen,
never black. The standalone arcade path keeps its own authored settings
and is not touched by the measurement. The desktop (480i) never depends on this: it boots
the same on every machine. `rgs-15khz.dotclock_min=off` in `batocera.conf`
keeps the emulators' own behavior and stops the measuring; a number
(e.g. `rgs-15khz.dotclock_min=25`) pins the floor by hand.

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
patch file yourself — the verifier prints the exact name it expects
(`i915-patched-<your-kernel>.ko`) and the folder
(`src/service/i915/binaries/`, inside the project folder) — before
installing; it warns, without failing, while the file is missing.

The patch survives an RGS update the same way the rest of the layer's
boot work does: it is checked against the running system at every boot,
and if a system update replaced the driver underneath, the layer keeps
the stock driver loading instead — the screen stays alive, and the
verifier tells you the patch needs to be refreshed
(recovery: run the install command above again). Nothing about the patch is active on
non-Intel machines: nothing is placed there, and if a box that had the
patch is moved back to a non-Intel graphics card, the layer removes its
own files from the boot partition by itself at the next start — there is
nothing to clean up by hand.

## The arcade binary arrives with the install

The tube profile runs arcade games (the MAME systems) through
**GroovyMAME** — the special MAME build that generates video modes for
arcade CRTs on the fly. Its binaries are large third-party builds, so
this project never ships them in this repository.

You do nothing extra for it: the install fetches the tested build
automatically from the project's public release, checks it, and places
it where the arcade path expects it (the certification here was done on
**0.289**). Updating later re-uses the binary already on the box when
it matches, instead of downloading it again.

If the box was offline at install time and the binary is missing, the
verifier says which one and where it goes
(`/userdata/system/crt-dual/profiles/rgs-15khz/binaries/mame` — the
file is simply named `mame`, and must be runnable), and still reports
clean — every non-arcade system works untouched; once it is placed, the
warning disappears and arcade launches use it.

Without the binary, what you skip is the arcade certification (the
native-mode per-game path described in the compatibility map); nothing
else in the layer is affected.

## `./verify.sh` — the gate

Exit 0 = clean. There are exactly **two** clean states and anything
mixed between them fails with a listing:

- **INSTALLED** — every piece the install placed is present and
  byte-identical to what it should be, the profiles are valid, the
  recorded setting backups are present (the layer pins no boot
  setting), the recorded RGS version still matches the live one, and no
  trace of any game session is stranded.
- **STOCK** — nothing of the layer is left (before any install, or
  after a complete uninstall).

The verifier **warns** (never fails) about missing user-procured
binaries: they are yours to download, and the warning tells you which
ones and where they go, so you can test everything that does not need
them.

Run it after install, after uninstall, and whenever something looks
wrong. One timing note: on an AMD machine, run it **after the first
reboot** — the first boot completes one display setting. It is also what the check tool and the update self-check agree
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
  Recovery is always the same: the check tool's update choice below,
  or the single install command again.
- Each launch also passes a fast runtime check; a failing check logs
  loudly and the game still launches stock-safe — the layer never
  blocks a game to make a point.

"Extend, don't replace" cuts both ways: an RGS update always wins, and
the layer either re-qualifies against it or gets out of the way.

## The check tool

An entry in the "Batocera config" menu (the same list as RGS's own
tools) shows one verdict for the box:

| Verdict | Meaning | Your options |
| --- | --- | --- |
| **GREEN** | Everything is aligned with what was installed. The screen shows the installed release and whether it is up to date. | Up to date: nothing to do. Update available: ENTER applies the update, ESC closes. |
| **RED** | An RGS update changed the system and the self-check could not vouch for it. | ESC — keep playing, games run exactly like stock while held. ENTER — uninstall the layer and reboot: pure stock RGS, one press. When a newer release certified for this box is available, ENTER applies the update instead and U keeps the one-press uninstall. |

When a newer release certified for this box is available, the tool
offers it on the same screen: one press applies it as a clean removal
of the old layer plus a fresh install of the new one, then reboots into
it. A release built for a newer RGS than the box runs is never offered —
update RGS itself first. With no network the tool behaves exactly as
before: it checks, and offers only the uninstall.

## Remote access (VNC)

The layer ships a VNC server (x11vnc) for test and tuning sessions. It
starts at boot and serves port **5900 without a password** — a
documented limitation for local-network use. Handy to watch the
machine's output from another screen; keep the box on a trusted network,
or stop it when you do not need it:

```
batocera-services stop zz_crt_dual_vnc
```

The server ships with the layer (x11vnc and its libraries travel in the
repository and are installed with everything else — nothing to
download) and is free software: x11vnc and LibVNCServer under
GPL-2.0-or-later (x11vnc keeps its upstream OpenSSL linking exception),
the SASL library under the Carnegie Mellon BSD-style license. The
required notices and the written source offer live in
[THIRD-PARTY.md](../THIRD-PARTY.md). If the binary is ever missing
(damaged install), the boot service says so once and stays off instead
of retrying.

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

Installing and updating are the same command — run it again over SSH
and the box moves to the current release on its own:

```
curl -fsSL https://raw.githubusercontent.com/frezeen/rgs-crt/main/get.sh | sudo bash
```

No git is needed on the box. The same release can also arrive through
the check tool's update choice above.
