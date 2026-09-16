# Setups & screens

This layer runs INSIDE stock RGS and reverts cleanly.

What you get depends on what you have plugged in — and the system
adapts instead of asking you to configure anything. There are three
setups, and switching between them is just plugging a cable.

## The three setups

| You have plugged in | What the box does |
| --- | --- |
| **Tube + LCD** | The desktop mirrors on both screens. When you start a game, you are asked which experience to run: the tube, or the LCD exactly like stock RGS. Your answer applies while you play; the desktop keeps showing on both between games. |
| **Tube only** | No question, no choice: everything runs on the tube. Menus sit on a safe 480i desktop mode, games switch to their own native signal, and return to the menu signal when they exit. |
| **LCD only** | The layer is invisible. Menus and games behave exactly like plain stock RGS — this "identical to stock" claim is not a promise, it is a measured result: the compatibility was certified on a real box (same modes, same logs, same settings) before any CRT feature existed. |

## Why the other screen goes dark during a game

When you play on the tube, the LCD turns off for the duration of the
game — and the same in reverse when you play stock on the LCD. This is
hardware safety, not cosmetics: a signal made for one kind of display
fed to the other is the classic way to damage it (a 15 kHz signal the
LCD cannot sync to, or pushing a 31 kHz signal into a tube that expects
15). Turning the unused display off removes the question entirely. It
comes back the moment the game exits, with the desktop restored.

## What a game does to the tube

Each supported game gets the video signal its original hardware made:
a Super Nintendo game outputs a real SNES signal, an arcade board its
own resolution and refresh. On setups where the native signal is
outside what a tube can safely show (very low resolutions, or very high
refresh needs), the game runs fullscreen at the best quality
alternative that stays in the safe range — the compatibility map marks
those systems individually, with the measured numbers.

The frequency range used has been demonstrated safe on the reference
tube (13.6–16.2 kHz); nothing is ever forced below it.

## Changing screens while the machine is running

This is not a paper feature: live re-plugging was exercised through the
weeks of tube certification on the reference machines, and it works —
the system re-reads what is connected when you are not playing, so
plugging in the tube, or removing the LCD, is picked up between games
and never during one (touching the display while a game owns it is
exactly what could disturb the picture).

The full, honest picture, because this manual tells you everything:

- after a plug or unplug, the new arrangement is applied when you are
  back in the menu — your next game launch sees it, chooser included;
- on the machines tested here — NVIDIA and AMD — plugging and
  unplugging either screen is picked up automatically, with exactly
  one exception stated below;
- the one exception: on the AMD machine's **analog port**, connecting
  or disconnecting the CRT is the one event that hardware cannot
  capture on its own. For that single case a connected controller
  carries the trigger: **Select + L1** re-scans the connections and
  the change is applied. Everywhere else
  the re-scan simply never needs to be used;
- Intel hardware was last exercised on an older revision: until the
  re-test lands, no claim in either direction about its detection;
- said with total transparency: across several weeks of active testing
  the machine crashed **two or three times in total** around a plug
  event. Nothing partial and nothing to repair — a reboot resolved
  every one of them and came back up correct for the cables actually
  connected. The guaranteed reset remains a reboot, which re-reads
  every port from scratch — the certified path of the whole system.

| Situation | What you see |
| --- | --- |
| You plug the tube in between games | The desktop adapts; the next game launch offers the tube experience. |
| You unplug the LCD | Same box, now a pure tube machine: no prompts, everything on the CRT. |
| You plug or unplug the CRT — on the AMD machine's analog port | The one manual case: press Select + L1 on a controller; the re-scan applies it. |
| A change looks ignored (any other case) | Reboot — always correct. |
| It happens mid-game | Nothing — intentionally. The change is picked up once you are back in the menu. |

## A powerful feature, meant for real moments

Worth saying plainly: live plug and unplug is one of the most advanced
and delicate things this system does. Screen detection is a different
story on every graphics card and every connector type, and the layer
carries that complexity precisely so you are never stuck when your
cable situation changes. It is tested extensively and it works — that
is not in doubt.

It is still not meant as a routine. The natural, stable shape of a
cabinet is: the screens you want are wired before you power on, and
they stay. Boot is the fresh, total re-read of every port; a
between-games re-plug is the machinery working overtime for the times
you genuinely need it — moving the cabinet, borrowing an LCD, swapping
tube for a session. Taking cables in and out continuously asks the
analog world to be re-read for no benefit: sure, it holds — but why
put it through the exercise? Wire your setup at boot, play, and let
the hot path be the exception you reach for, not the habit.

## The desktop itself

With a tube present, the desktop runs on a 640x480 interlaced signal —
the classic arcade mode — so EmulationStation and the menus are fully
usable on glass, and a connected LCD mirrors the same image. During a
stock-profile game session the LCD switches back to its normal
full-resolution mode for the game, tube dark; when the session ends,
the mirrored desktop returns.
