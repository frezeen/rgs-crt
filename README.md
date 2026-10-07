# RGS 15 kHz — classic games on a real CRT, inside RGS

A 15 kHz CRT layer for RGS (Batocera-based): your console and arcade
games run at the signal they were designed around, on an arcade tube —
while RGS stays exactly what it is. This layer runs **inside** stock
RGS: it extends how games are launched, replaces no RGS tooling, and
removes itself back to the exact stock state at any time.

---

## What you get

| | What you see on the screen |
| --- | --- |
| Native signals | A SNES game outputs a SNES signal, a Dreamcast game a 480i arcade signal, an arcade board its own native mode — crisp pixels and correct refresh. Where a system's native signal is outside what a tube can show, it runs fullscreen at the best quality alternative instead; for a few HD consoles that alternative is a deliberate full-bleed stretch, and the compatibility map marks exactly which systems those are. |
| No fake CRT effects | Smoothing and scanline-style filters are switched off on the tube. The tube is the filter. |
| The menu keeps working | Between games the desktop runs on the tube, on a connected LCD, or on both. Pick whichever you plugged in. |
| It always gives things back | Every setting a game needed is reverted the moment the game exits. The desktop, the values, everything returns to what it was. |
| A safety net you can see | A check entry in the Batocera config menu shows green when everything is aligned and red when an RGS update changed the system underneath — with a one-press return to pure stock RGS. While red, games keep running exactly as stock. The same entry is also where this layer updates itself in one press when a newer release is available. |

## Three ways to plug it in

| Your setup | What happens |
| --- | --- |
| **Tube + LCD** | The desktop shows on both. When you start a game you choose the experience: the tube, or the LCD exactly like stock RGS. During a tube game the LCD goes dark on purpose (and back on when the game ends). |
| **Tube only** | Everything runs on the tube: menus at a safe 480i desktop mode, games at their native signal. No prompts. |
| **LCD only** | The layer is invisible: the box behaves like plain stock RGS. This is not an afterthought — "identical to stock" is a certified behavior, proven before any CRT feature existed. |

Plugging or unplugging a screen while the machine runs is detected
between games — never during one, because touching the display mid-game
is the one thing that could disturb the tube. On the NVIDIA and AMD
machines tested this is automatic in every direction with a single
documented exception: on the AMD machine's analog port, plugging or
unplugging the CRT is caught with one controller press — the setups
page has the exact words. Rebooting is always the
fresh, correct state. And a word of sense: this is a powerful, complex
feature meant for real moments — wire the screens you want before you
boot, and reach for the hot path when you genuinely need it, not as a
routine.

Full walkthrough: **[docs/setups.md](docs/setups.md)**

## Profiles: the experiences you choose between

A profile is a named set of per-game settings applied when a game
starts and reverted when it exits. Two ship today:

| Profile | What it does |
| --- | --- |
| **RGS 15 kHz CRT** | The tube experience: native resolutions per game, filters off, settings tuned per system. |
| **RGS stock (compat)** | Changes nothing — the same game, exactly as plain RGS runs it. The proof that this layer can be told to step aside completely. |

There is no limit to how many profiles you can have: each one is a
plain-text folder, and a chooser appears only when there is a real
choice to make. How profiles work and what to expect:
**[docs/profiles.md](docs/profiles.md)** — and to write or maintain
your own, with every instruction available and working examples:
**[docs/writing-profiles.md](docs/writing-profiles.md)**.

## Quick start

**Prerequisite: an updated, stock RGS.** RGS itself is what you get by
taking an untouched Batocera and applying RGS's own installation script
to it — the plain, official RGS, exactly as its team publishes it. One
step of that flow matters specifically for this layer: after
installing RGS, **run its update tool at least once** (the RGS upgrade
script in EmulationStation's Batocera config list). That completes the
RGS setup and stamps the version record every install here is checked
against; a box that never ran the updater will be refused, with exactly
that instruction printed. Everything else about obtaining, installing
or updating RGS lives on RGS's official channels; this project
deliberately does not duplicate those steps.

Over SSH, as root, one command installs the layer — and the same
command updates it later:

```
curl -fsSL https://raw.githubusercontent.com/frezeen/rgs-crt/main/get.sh | sudo bash
```

Updating needs no preparation: if the layer is already installed, the
same command removes the old one first. Nothing has to be removed by
hand.

After it finishes: connect the CRT and reboot once — the first boot
completes one display setting. Then, from the installed folder
(`/userdata/roms/rgs_crt`), `./verify.sh` must report clean (exit 0):
that is the gate for everything else. To remove the layer entirely,
`./uninstall.sh` from the same folder returns the box to exact stock.

Details — what the install owns, what an RGS update does to it, how the
check tool decides green vs red: **[docs/install-and-updates.md](docs/install-and-updates.md)**

## What is supported today

Every claim about a system carries a verdict:

- **TESTED** — launched on a real tube and measured (resolution,
  frequency, on-screen result), with the numbers kept.
- **family** — shares a pipeline already certified by a TESTED launch
  of the same kind; expected to work, not yet individually launched.
- **pending** — declared untested, usually no content on the test box.
  Never presented as working.

The honest per-system map lives in **[docs/emulators-status.md](docs/emulators-status.md)**.

## Bonus: a JammASD arcade control board? It speaks two gamepads

If your cabinet is wired with a
[JammASD ASD275](https://www.webasd.com/public/doc/ASD275/ASD275A_BrochureIT.pdf)
arcade interface — a board that presents itself to the system as one
big keyboard — this repository ships a small bonus companion for it: a
daemon that takes the board's keys and hands every emulator **two
ordinary Xbox 360 controllers** instead. No keyboard-to-pad mapping
fights, nothing to configure per emulator; two players just have pads.

What it does on the cabinet:

- both players' directions act as a classic d-pad, which is what retro
  games expect; press your four face buttons together to switch the
  directions to a real analog stick for the few games that want
  genuine stick deflection (back the same way, any time);
- face buttons, shoulders, analog triggers and Start/Select map from
  physical keys with a readable, editable default set per player;
- a handful of system keys (Tab, Esc, P, Enter, backtick) pass through
  for menus and pausing, and the board's combined Start combo exits
  games;
- if the board is unplugged and re-plugged, the pads come back on
  their own.

It is deliberately **separate from everything else in this project**:
it has its own installer and uninstaller, the CRT layer's install /
verify / uninstall never touch it, and skipping it changes nothing
about the display features above. One command installs it, one removes
it, and the `jammASD` folder holds its configuration plus the board's
pinout reference for wiring:

```
sudo python3 jammASD/install.py      # deploy + start its own service
sudo python3 jammASD/uninstall.py    # reverse everything, reboot to finish
```

Honest scope: this companion is a gift within a gift — built for the
same cabinet and shipped because someone else with the same hardware
may need it, but it is not part of the tube certification runs, so it
earns no "TESTED" verdict here. Try it on your own wiring; it checks
its dependencies and reports loudly.

## Status & limitations

- Tested on two reference machines: RGS 43.43 (Batocera 43.1 base),
  x86_64, one with an **NVIDIA GTX 970** and one with an **AMD R9
  270X**, arcade tube in the demonstrated 13.6–16.2 kHz range. An
  **Intel** gen9 iGPU path exists since the current revision: the install
  places a small display patch (from
  [amxcs/batocera-crt-15khz-intel](https://github.com/amxcs/batocera-crt-15khz-intel),
  credited at the bottom of this page) that unlocks true 480i on those
  chips — its behavior on this layer is on the list for a first live
  verdict before it is claimed as proven. Other hardware is not claimed
  at all: `./verify.sh` plus your report is how the map grows.
- On **AMD** machines running a kernel below 6.19, the layer pins the
  classic display stack at install: the modern one shipped a signal on
  digital ports only, so a CRT on the analog output stayed dark while
  the flat panel lit up. If you prefer the modern stack regardless,
  set `rgs-15khz.amdgpu-legacy=off` in `batocera.conf` — the layer
  re-checks the choice at every boot.
- The first time you launch a game on a CRT the layer measures the
  lowest video clock your chain can produce (a few quick mode changes on
  the tube, once) and remembers it: games then run at their native
  resolution when the chain supports it, and are gently widened when it
  does not — a screen that would go black shows the game instead. The
  desktop and the boot never depend on this. Set
  `rgs-15khz.dotclock_min=off` in `batocera.conf` to keep the emulators'
  own values untouched, or a number (e.g. `25`) to pin the floor yourself.
- Live screen re-plugging was used through weeks of testing and works;
  across the whole test period the box crashed two or three times
  around a plug event, every time recovered by a reboot (the setups
  page states it with the same honesty).
- The arcade path runs on **GroovyMAME** (the CRT-capable MAME build):
  the install fetches the tested build automatically from the project's
  public release — it is still never shipped in this repository (the VNC
  server is the exception — it ships
  with the layer, see [THIRD-PARTY.md](THIRD-PARTY.md)). If the box was
  offline and the binary is missing, the verifier
  tells you exactly which one
  is missing and at which path to place it — and warns without
  blocking, so everything else keeps working meanwhile
  ([details](docs/install-and-updates.md#the-arcade-binary-arrives-with-the-install)).
- After an RGS system update, reinstalling this layer is required if
  its self-check cannot vouch for the new system — by design, so you
  never run a half-verified setup.
- Two stock RGS behaviors found on the way (with evidence) are
  documented for the RGS team in
  **[docs/rgs-stock-issues.md](docs/rgs-stock-issues.md)** — none of
  them is caused by this layer.

## The manual

| Page | Read it when |
| --- | --- |
| [Setups & screens](docs/setups.md) | You want to know what the tube and the LCD do — and why the LCD goes dark during games. |
| [Profiles](docs/profiles.md) | You want to understand the choice you're given. |
| [Writing & maintaining profiles](docs/writing-profiles.md) | You want to build your own, or tune the shipped ones — every command, with examples. |
| [Install & updates](docs/install-and-updates.md) | You want to know exactly what the install touches, and what happens after an RGS update. |
| [Compatibility map](docs/emulators-status.md) | You want to know if your system works — with the measured numbers. |
| [Stock RGS notes](docs/rgs-stock-issues.md) | You hit something that looks like RGS's own behavior, not ours. |

## Credits

The true 480i picture on Intel gen9 graphics is made possible by the
community project **[batocera-crt-15khz-intel](https://github.com/amxcs/batocera-crt-15khz-intel)
by amxcs** — the diagnosis, the patch and the ready-made display patch
this layer places on those machines are their work, released under the
GNU GPL v2, which this project honors as-is. The same respect runs the
other way: the arcade kernel work this layer relies on in the RGS/Batocera
system itself comes from the community patch set
[D0023R/linux_kernel_15khz](https://github.com/D0023R/linux_kernel_15khz),
which Batocera ships. Thank you — the tube experience stands on both.

## Reporting a problem

We diagnose from complete evidence, never from descriptions — and the
project gives you the collector, so this is three steps, done over SSH
with the LCD and CRT plugged in the way you want reported:

1. **If a game is on screen and stuck, end it cleanly first** (the
   stock swissknife does exactly that, and the layer restores on the
   game's exit):

   ```
   batocera-es-swissknife --emukill
   ```

2. **One command, run from the installed folder
   (`/userdata/roms/rgs_crt` — the folder the install uses; as root —
   over SSH you already are; without root the bundle
   may miss system state):**

   ```
   ./report.sh
   ```

   It collects everything we need in one pass: a diagnostic snapshot of
   the display (which screens are connected, what they report, the GPU,
   live mode timings), the gate's verdict, every relevant log, the
   installed state and the display lines from the system log — and zips
   it all. If the folder is gone, run the install command again and
   report from there.
   `report.sh` writes only its
   own report folder and zip; the snapshot inside it looks at the
   display while gathering — nothing on the box is modified.

3. **Send the printed `rgs-crt-report-….zip`.** Everything inside is
   complete by design — just add to your message which GPU you have,
   which socket the CRT hangs off, and what you saw. For picture
   quality questions, a photo of the actual glass still beats any
   description.
