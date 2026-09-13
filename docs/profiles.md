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
| **RGS 15 kHz CRT** | The tube experience. Games launch at their native signal, CRT-emulation filters are switched off (the tube is the filter), and each supported system carries its own tested settings — which emulator to use, how it should output, what to leave at its defaults. |
| **RGS stock (compat)** | **It changes nothing.** A game launched under it runs exactly as plain RGS runs it. Its purpose is to be the proof: the layer can be told to step aside completely, and "completely" is measured, not promised — the compatibility run produced the same modes, the same logs and the same settings as an untouched system. |

## Where you meet profiles

The chooser only appears when a real choice exists:

| Your setup | Profiles that fit you | What happens |
| --- | --- | --- |
| Tube + LCD | one for each | You are asked which experience to run. |
| One display, several profiles that fit it | 2 or more | You are asked to pick between them. |
| One display, one matching profile | 1 | No question — it applies directly. |
| Nothing connected | — | Stock behavior, always. |

The rule behind the table: the system checks what you actually have
plugged in and offers only what can work. It never assumes "CRT always"
— if there is no tube, there is no tube experience offered.

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
- If two settings could apply, the more specific one wins: a
  system-level choice beats an emulator-level one beats the common
  ground.

What a profile may adjust for a game: which emulator or core runs the
system, the display signal to aim for, the emulator's own options
(shaders, filters, fullscreen behavior), command-line arguments the
emulator is launched with, and — where an emulator reads a settings
file — single lines rewritten for the session and restored afterwards,
byte for byte.

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

- **Errors surface early.** A malformed profile is rejected at install
  time — it never reaches a game launch.
- **Nothing permanent.** Whatever the profile changes at game start,
  the exit gives back — values, files, the works.
- **Nothing invisible.** `./verify.sh` fails if any session ever
  stranded a trace of a profile behind.

## Switching between profiles

You choose at the prompt when both experiences fit your hardware.
Changing your mind mid-session is not how profiles work: they belong to
the game boundary — a new game, a new choice. Removing or adding a
profile folder takes effect at the next install/verify check, not
mid-game.
