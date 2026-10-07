# Changelog

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
