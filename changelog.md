# Changelog

## 2026-10-10 — a game that will not let go no longer strands the tube

**Closing a game always brings the menu back.** Some games, closed
normally, did not fully let go of the screen: the game ended, but the
picture stayed frozen on its last frame and the menu never returned — with
no way out from the cabinet, and the desktop left on the other screen. The
layer now notices that the game has let go and finishes the hand-over on its
own: the menu comes back on the tube and the desktop returns to normal, with
no reboot, no command, and nothing to do at the cabinet.

This is not specific to one system. The check is built on a property that
holds for any game — whether the program that was running it has really
released it — so games added later are covered without anything to update.

## 2026-10-09 — the check entry gets a picture, keeps its place, and RGS 43.55 is certified

**A proper picture for the check entry.** "RGS-CRT CHECK & UPDATE" now shows
a wheel in the Batocera config menu instead of blank space. It is drawn flat
and transparent on purpose — no glow, no 3D — because the whole point of this
layer is text you can read on a tube, and lettering that blooms on a 480i
phosphor is the exact fault it exists to prevent. It comes with the install,
so a fresh box has it too: nothing to fetch or place by hand.

**The entry stops vanishing.** EmulationStation rewrites its game list every
time it records a launch, and it was quietly dropping the check entry while it
did. The layer now puts it back at every boot, so the entry stays in the menu
where you look for it.

**Certified on RGS 43.55.** This release is built and checked against RGS
43.55. Updating RGS and then opening the check entry is all that is needed —
and it reports what it found, as it always has.

**An RGS update that changes the rules is caught instead of ignored.** The
layer's picture settings are read by RGS itself. If an RGS update changes the
way they are read, the layer now notices at the next check rather than
quietly doing nothing: the tube profile stands down, your games keep launching
with stock behavior, and the check screen says exactly why.

## 2026-10-08 — the manual matches the box, and every setting in one place

**The manual now says what the box does.** Version numbers, the boot-time
measurement of the lowest video clock, the check entry's name, the log
location and the license are all stated where you look for them — no more
stale numbers, no more guessing where to look.

**Every setting in one table.** All six settings the layer reads from
`batocera.conf` are now listed together with what each one does,
including the tube refresh rate for 50 Hz screens.

**A clearer message when the install refuses a git checkout.** Running
the one-command install from a developer checkout now tells you plainly
to download the release archive instead.

## 2026-10-07 — the PSP and the Nintendo 3DS fill the tube, and the setup survives a reboot

**PlayStation Portable no longer letterboxes.** The tube profile already
asked for a full-screen PSP picture, but the emulator was never actually
told: that setting lives inside one of the emulator's own settings groups
and the key was landing outside it, so the game kept its own proportions
with black bars down both sides. The picture now reaches the tube's edges
and fills the 4:3 glass edge to edge. The render itself is untouched — the
console's own scale, sharp filtering, so the image is enlarged rather than
softened.

**Nintendo 3DS shows both screens, filling the tube.** The handheld's two
screens are laid out at the same size, one above the other, each widened
to the width of the tube: no black bars, and together they cover the glass
from top to bottom on the tube's 480i signal. Giving the two screens equal
size costs a little width, so the picture reads slightly wider than the
hardware's own — the deliberate trade for a full picture, and both screens
stay usable (the lower one is the touch screen). The layout is written
while the game runs and put back exactly as it was when it closes.

**Games keep the tube setup after a reboot.** At boot, RGS rewrites the
program it uses to start games. The layer re-applies its own changes to
that program at the same moment, and could lose the race — after a reboot
the box could report itself as no longer clean, and the tube's own setup
stayed undone until the next game launch. The layer now waits for RGS to
finish first, and if RGS takes unusually long it carries on anyway rather
than stalling the boot.

## 2026-10-07 — one command installs and updates, from the box itself

**Install and update with a single command.** The layer now installs —
and later updates — with one command run over SSH on the box itself:

```
curl -fsSL https://raw.githubusercontent.com/frezeen/rgs-crt/main/get.sh | bash
```

An update removes the old layer and installs the new one in one go,
then asks for a reboot. No download-and-copy step on your computer
first.

**The check entry updates too.** The green/red screen in the Batocera
config menu now offers a newer release certified for your box when one
exists: one press applies it the same clean way. A release built for a
newer RGS than the box runs is never offered — update RGS itself first.

**The arcade binary arrives on its own.** The arcade path needs its
special MAME build; the install now fetches the tested build
automatically, so there is nothing to hunt down and place by hand.

**The clean-state check no longer fails after removal.** Removing the
layer and then running the clean-state check used to fail on a box with
nothing of the layer left; it now correctly reports the clean, stock
state.

## 2026-10-07 — the Raw Thrills shooters reach the tube, and a fuller diagnostic report

**Raw Thrills gun shooters on the tube.** The tube profile now covers the Raw
Thrills system, so its gun games start on the 15 kHz signal instead of staying
on the LCD. Both titles installed on this machine — Big Buck Hunter Pro and
Aliens Armageddon — were checked on the glass: the picture fills the 4:3 frame
with no letterbox and no stretch. They run on two different engines (one
through Wine, one through the native loader), and both were verified.

**A fuller diagnostic report.** The one-command diagnostic snapshot now
carries the fields that decide what a machine actually shows: the GPU driver
and OpenGL library versions, the kernel's display messages, the full display
geometry including the scaling transform, the monitor list, and each output's
rotation. That is the evidence behind a wrong-looking picture, collected in a
single file you can send.
