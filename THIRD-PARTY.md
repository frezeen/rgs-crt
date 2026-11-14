# Third-party components

This repository bundles the following third-party components. All are
under free-software licenses compatible with this repository's LICENSE
(GPL-2.0): the VNC server is GPL-2.0-or-later, the JPEG library is under
the libjpeg-turbo triple license (IJG / BSD-3-Clause / zlib). They are
shipped for stock Batocera, where no VNC server is present (verified: no
wayvnc/tigervnc/x0vncserver on stock Batocera 43.1).

## TigerVNC 1.12.0 (SHIPPED — `src/engine/vnc/binaries/X0tigervnc`)

- **Purpose**: VNC shadow server for the X11 desktop (the `vnc` /
  `vnc-scaled` launchers and the `zz_crt_dual_vnc` autostart service).
  It serves the display that is already running — it creates no virtual X.
- **License**: GPL-2.0-or-later. Copyright (C) 1998-2022 TigerVNC Team
  and others (the project forks TightVNC, which derives from AT&T's VNC);
  the upstream licence text is `LICENCE.TXT`.
- **Provenance**: Debian bookworm package `tigervnc-scraping-server`
  `1.12.0+dfsg-8` (amd64), binary extracted as-is from the package's
  `data.tar.xz`; version verified live: `X0tigervnc --version` ->
  `TigerVNC Server version 1.12.0, built 2023-01-06`. Corresponding
  source: <https://github.com/TigerVNC/tigervnc> (tag v1.12.0) and the
  Debian source package `tigervnc 1.12.0+dfsg-8`.
- **Modifications**: none — the binary is used as-is. It needs no runtime
  symlink: it links the system's X11/GnuTLS/PAM libraries plus the
  bundled `libjpeg.so.62` (below).

## Bundled shared library (SHIPPED — `src/engine/vnc/binaries/`)

| File | Component | License |
| --- | --- | --- |
| `libjpeg.so.62` | libjpeg-turbo 2.1.5 | IJG / BSD-3-Clause / zlib (three compatible BSD-style licenses) |

- **Provenance**: Debian bookworm package `libjpeg62-turbo` `1:2.1.5-2`
  (amd64), library extracted as-is. Stock Batocera 43 ships
  `libjpeg.so.8` only and X0tigervnc links `.62`; the library travels
  beside the binary and is loaded through `LD_LIBRARY_PATH`
  (`src/engine/vnc/vnc-env.sh`), nothing is installed system-wide.
  Upstream: <https://github.com/libjpeg-turbo/libjpeg-turbo> (2.1.5) —
  copyright (C) 2009-2023 D. R. Commander and (C) 1991-2020 Thomas G.
  Lane / Guido Vollbeding; the three license texts live in the project's
  `LICENSE.md` and remain embedded in the library.
- **Modifications**: none.

## GPL compliance note (TigerVNC)

- The shipped binary is an UNMODIFIED upstream release; the complete GNU
  GPL v2 text is this repository's `LICENSE` file, and the upstream
  notices remain embedded in the binary.
- **Written offer (GPL-2 section 3b)**: this project offers, valid for
  at least three years from 2026-11-14 (the date of the first public
  distribution of this binary), to give any third party the complete
  corresponding source code of the components above, for no more than
  the cost of physically performing the distribution, on request through
  this repository's issue tracker. The links above are the exact source
  releases the bundled binary was built from.
- The binary is dynamically linked against the system's own libraries
  (X11, Xdamage/Xfixes/Xrandr/Xtst, GnuTLS, PAM, pixman, zlib) — none of
  those are bundled; the one library in the table is shipped alongside
  because stock Batocera does not provide it.

## Profile picker artwork (SHIPPED — `src/engine/selector/assets/`)

- **Files**: `crt.png` (arcade cabinet), `lcd.png` (flat-panel TV),
  `arrow.png` (selection arrow) — the pictures the profile picker draws.
- **Purpose**: `src/engine/selector/selector-ui.py` shows one picture per
  profile instead of a text button; the arrow marks the chosen panel.
- **License**: none claimed and none needed — the artwork was supplied by
  the project owner and carries no stock-library licence, watermark or
  third-party mark. The shipped files are that artwork with the background
  keyed out to alpha, so it composites on the picker's black raster; no
  other modification.
- **Provenance**: owner-supplied (2026-11-03), committed at the owner's
  request. If a picture is ever replaced by a third-party asset, its
  licence and source belong in this section.
- **Shipped**: yes — travels with `src/selector` in `install.sh` and is
  synced by `deploy.sh`; used only by the picker.

## Switchres (runtime dependency — NOT bundled)

- **Purpose**: CRT modeline generation. Called at runtime through its C
  wrapper API (`sr_*`, `switchres_wrapper.h`) via the layer's own ctypes
  helper.
- **License**: GPL-2.0+ (compatible with this repository's LICENSE).
- **Provenance**: the stock shared library shipped by Batocera x86
  (verified: `/usr/lib64/libswitchres.so.2.2.1` on Batocera 43.1, the
  same library `/usr/bin/switchres` links). Nothing is bundled, built,
  or modified by this repository.
- **Upstream**: <https://github.com/antonioginer/switchres>

## amxcs batocera-crt-15khz-intel (prebuilt i915 patch — NOT committed)

- **Purpose**: true interlaced 480i output on Intel gen9 graphics
  (DISPLAY_VER 9 — Skylake HD 530 through Coffee Lake UHD 630). Stock
  gen9 i915 rejects Y-tiled scanout in IF-ID interlace mode while
  Mesa/glamor allocates Y-tiled buffers, so every 480i modeset fails;
  the patched driver advertises only LINEAR/X_TILED on gen9 and
  interlace works. Without it this layer still gets progressive 15 kHz
  on Intel, not 480i.
- **What this project uses**: ONLY the prebuilt kernel module
  (`i915-patched-6.18.16.ko`, release tag `batocera-43.1`) plus the
  module-swap-at-boot MECHANISM (stock `S00bootcustom` runs
  `/boot/boot-custom.sh` before udev; `/lib/modules` is on the RAM
  overlay and reverts every boot). The installer and every other script
  of that project are NOT used — they manage ES modes / batocera.conf
  keys / the boot command line, which would fight this layer.
- **License**: GPL-2.0 (the patch modifies Linux kernel source, so
  GPL-2.0 is a condition of the kernel's own licence — amxcs's words,
  honored as-is).
- **Provenance**: downloaded by `install.sh` from the project's public
  release URL at install time (or user-procured into
  `src/service/i915/binaries/`, which is gitignored — the binary is
  never committed). vermagic is verified against the running kernel
  before every deploy; a mismatch is refused.
- **Upstream / source offer**: <https://github.com/amxcs/batocera-crt-15khz-intel>
  (the patch source, the build instructions against the exact Batocera
  kernel, and the boot-swap mechanism documentation).
- **Modifications to their artifacts**: the boot hook is THIS project's
  own rewrite (vermagic-checked before swapping — their hook swaps
  unconditionally and documents the resulting "upgrade = no display"
  caveat; the check is the update-safe variant). The module binary is
  used byte-for-byte as published.

## User-procured binaries (NOT bundled)

GroovyMAME (`profiles/<name>/binaries/`, large third-party builds) is
user-supplied and gitignored; `verify.sh` warns while it is missing and
the arcade path then runs the stock emulator. See
`docs/install-and-updates.md` ("The arcade binary is yours to supply").
