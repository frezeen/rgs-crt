# Profiles

This layer runs INSIDE stock RGS and reverts cleanly. Profiles are how
it knows what to change for your games — and what to leave alone.

## What a profile is

A profile is a **named set of per-game settings** that the system
applies the moment a game starts and reverts the moment it exits.
Nothing a profile does is permanent: every value it touches is
remembered and given back. A profile whose change could not be undone
would be a design error, and the whole system is built so that one
cannot exist.

Think of it as a costume for the machine: put it on when a game needs
it, take it off when the game is over.

## What ships today

| Profile | What it does |
| --- | --- |
| **RGS 15 kHz CRT** | The tube experience. Games launch at their native signal, CRT-emulation filters are switched off (the tube is the filter). The systems with their own tuning carry it; the rest ride the common base plus their emulator family — the compatibility map shows which is which. |
| **RGS stock (compat)** | **It changes no stock display or emulator visuals.** A game launched under it runs with plain RGS visuals, while sharing the updated MAME 0.289 binaries and the network/clean-exit safety guards (so LAN/NFS never freezes on cabinet titles and games exit cleanly on LCD too). |

## Where you meet profiles

The chooser only appears when a real choice exists:

| Your setup | Profiles that fit you | What happens |
| --- | --- | --- |
| Tube + LCD | one for each | You are asked which experience to run — the picker shows an arcade cabinet for CRT and a flat-panel TV for LCD. |
| One display, several profiles that fit it | 2 or more | You are asked to pick between them. |
| One display, one matching profile | 1 | No question — it applies directly. |
| Nothing connected | — | Stock behavior, always. |

The rule behind the table: the system checks what you actually have
plugged in and offers only what can work. It never assumes "CRT always"
— if there is no tube, there is no tube experience offered.

When the chooser opens, it draws visual panels for the two shipped
profiles (an arcade cabinet for `CRT`, a flat-panel TV for `LCD`) and
text panels (from `label` and `description`) for any custom profile you
add. You can navigate with keyboard arrows, arcade stick, or D-pad, and
confirm with Enter, Space, or any gamepad button; after a 10-second
countdown it picks the display-compatible default, and clears the screen
to black before closing so no frame lingers behind the game.

## What a profile decides for a game

Inside a profile, settings are scoped, not sprayed:

- **Common ground** applies to every launch (which output drives the
  games, and the universal choices like filters-off on the tube).
- **Per-system settings** apply only when that system's game starts —
  a PlayStation 2 game gets the PS2 tuning, a Super Nintendo game gets
  nothing PS2-related.
- A system without its own entry still gets the common ground and the
  emulator's own defaults — being unlisted means "run as designed",
  never "broken".
- Per-game blocks (`[<system>["<rom>"]]`) can scope any setting, file,
  or command to a single title.
- A profile can pin an emulator or core for a system or title even when
  EmulationStation passes its own emulator flag on the command line,
  while stock or user-saved per-game pins in `batocera.conf` still take
  precedence over system-level profile pins.
- Leaving a `batocera.conf` key empty removes a stock setting for the
  session and restores it when the game exits.
- If a declared binary is missing, only that executable swap falls back
  to stock (with a warning) while the rest of the profile stays active.
- If a `[runtime]` start command fails or times out, it is not recorded
  as applied, so its undo does not run at exit.
- If two settings could apply, the more specific one wins: a
  per-game choice beats a core choice beats a system-level choice beats
  an emulator-level one beats the common ground.
- Per-game generator edits keep each declaration's scope even when
  several titles use the same operation key.

What a profile may adjust for a game: which emulator or core runs the
system, the display signal to aim for, the emulator's own options
(shaders, filters, fullscreen behavior), command-line arguments the
emulator is launched with, and — where an emulator reads a settings
file, whether it is a plain list or a settings XML — single settings
rewritten for the session and restored afterwards, byte for byte.
A profile may also put a missing program file back where the program
expects it (the tube profile repairs the MSX emulator's font folder this
way); that one is kept, not undone, because the file belongs there.
For the rare need that is none of those, a profile can run a **small
command** when the game starts and its declared undo when the game ends
— both halves are mandatory, so a change that cannot be undone is
rejected before it ever ships. The same section can also hand the game
extra environment entries (a variable, a folder searched for programs)
that only that game's launch ever sees.

## How many profiles can you have

No limit: a profile is a plain-text folder, and the system discovers
them rather than knowing them in advance. Two ship today because two
experiences make sense to certify; a third, fourth and fifth are yours
to invent. Every profile follows the same construction — applied per
game, reverted on exit, checked at install time.

## Writing your own

A profile folder is:

- a plain-text **settings file** (the profile itself: the choices
  described above, grouped per system),
- an optional folder of **config files** for the few emulators that
  need a whole file instead of single settings,
- an optional folder of **binaries** you procured yourself (never
  shipped, never required — the verifier only tells you what a profile
  expects).

The hands-on manual — every instruction a profile can use, working
examples taken from the shipped profiles, recipes and maintenance
rules — is **[Writing and maintaining profiles](writing-profiles.md)**.

Guarantees you get from the framework, not from the individual profile:

- **Errors surface early.** A malformed profile is a loud, listed
  failure in `./verify.sh` — and if a launch meets one anyway, it falls
  back to stock behavior instead of using it.
- **Nothing permanent.** Whatever the profile changes at game start,
  the exit gives back — values, files, the works. The single exception
  is a repair that puts one of the emulator's own files back where the
  emulator looks for it; it stays, because the next launch needs it.
- **Nothing invisible.** `./verify.sh` fails if any session ever
  stranded a trace of a profile behind.
- **A hard stop is cleaned.** If the box loses power or a session dies
  mid-game, automatic recovery runs both at boot and before the next
  launch: it cleans half-applied files, binaries, keypatches, and
  runtime records, heals any leftover `batocera.conf` keys back against
  the first-install stock snapshot, and sweeps stray compositor/Wine
  processes and mounts.

## Switching between profiles

You choose at the prompt when both experiences fit your hardware.
Changing your mind mid-session is not how profiles work: they belong to
the game boundary — a new game, a new choice. Removing or adding a
profile folder takes effect at the next game launch, not mid-game.
