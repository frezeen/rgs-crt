# Changelog

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
