# Changelog

## 2026-10-07 — one command installs and updates, from the box itself

**Install and update with a single command.** The layer now installs —
and later updates — with one command run over SSH on the box itself:

```
curl -fsSL https://raw.githubusercontent.com/frezeen/rgs-crt/main/get.sh | sudo bash
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
