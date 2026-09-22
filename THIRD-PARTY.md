# Third-party components

This repository bundles the following third-party components. All are
under free-software licenses compatible with this repository's LICENSE
(GPL-2.0): the VNC components are GPL-2.0-or-later (x11vnc carries an
explicit OpenSSL linking exception), the SASL library is under the
Cyrus SASL (Carnegie Mellon) BSD-style license. They are shipped for
stock Batocera, where the equivalent tool is not present (verified: no
x11vnc/wayvnc/tigervnc on stock Batocera 43.1).

## x11vnc 0.9.17 (SHIPPED — `src/engine/vnc/binaries/x11vnc`)

- **Purpose**: VNC server for the X11 desktop (the `vnc` / `vnc-scaled`
  launchers and the `zz_crt_dual_vnc` autostart service).
- **License**: GPL-2.0-or-later. Copyright (C) 2002-2010 Karl J. Runge
  and others. The upstream source header reads: "This is free software;
  you can redistribute it and/or modify it under the terms of the GNU
  General Public License as published by the Free Software Foundation;
  version 2 of the License, or (at your option) any later version", plus
  an explicit exception: "as a special exception, Karl J. Runge gives
  permission to link the code of its release of x11vnc with the OpenSSL
  project's 'OpenSSL' library (or with modified versions of it that use
  the same license) and distribute the linked executables. You must obey
  the GNU General Public License in all respects for all of the code used
  other than 'OpenSSL'." The distribution below relies on that exception
  (this box's x11vnc links the system OpenSSL 3 — nothing is bundled).
- **Provenance**: binary version verified live (`x11vnc -version` ->
  `0.9.17 lastmod: 2025-04-11`), built from the upstream release, ported
  from a private development repository (not part of this public tree).
  Corresponding source: <https://github.com/LibVNC/x11vnc> (tag 0.9.17).
- **Modifications**: none — the binary is used as-is. Its only runtime
  adaptation is a `libcrypt.so.1` symlink to the system's
  `libcrypt.so.2` (stock Batocera 43 ships only .2; the crypt ABI is
  stable — created at runtime by `src/engine/vnc/vnc-env.sh`, never
  shipped, never committed).
- **Shipped**: yes — it travels in this repository and is installed to
  the deployed package by `install.sh`, so the `vnc` command and the
  boot service work with no user action.

## Bundled shared libraries (SHIPPED — `src/engine/vnc/binaries/`)

| File | Component | License |
| --- | --- | --- |
| `libvncserver.so.1` | LibVNCServer 0.9.12 (server library for x11vnc) | GPL-2.0-or-later |
| `libvncclient.so.1` | LibVNCClient 0.9.12 (client library for x11vnc) | GPL-2.0-or-later |
| `libsasl2.so.2` | Cyrus SASL 2.1.28 (SASL support for x11vnc) | CMU BSD-style (text below) |

- **Provenance**: version strings read from the shipped binaries
  (`LibVNCServer 0.9.12`; `Cyrus SASL 2.1.28`); LibVNCServer is linked
  against the system GnuTLS (not OpenSSL), so the exception above is not
  needed for these libraries. Corresponding sources:
  <https://github.com/LibVNC/libvncserver> (tag v0.9.12) and
  <https://github.com/cyrusimap/cyrus-sasl> (release 2.1.28).
- **Modifications**: none.

## Cyrus SASL license (required notice for `libsasl2.so.2`)

```
/* CMU libsasl
 * Tim Martin
 * Rob Earhart
 * Rob Siemborski
 */
/*
 * Copyright (c) 1998-2003 Carnegie Mellon University.  All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions
 * are met:
 *
 * 1. Redistributions of source code must retain the above copyright
 *    notice, this list of conditions and the following disclaimer.
 *
 * 2. Redistributions in binary form must reproduce the above copyright
 *    notice, this list of conditions and the following disclaimer in
 *    the documentation and/or other materials provided with the
 *    distribution.
 *
 * 3. The name "Carnegie Mellon University" must not be used to
 *    endorse or promote products derived from this software without
 *    prior written permission. For permission or any other legal
 *    details, please contact
 *      Office of Technology Transfer
 *      Carnegie Mellon University
 *      5000 Forbes Avenue
 *      Pittsburgh, PA  15213-3890
 *      (412) 268-4387, fax: (412) 268-7395
 *      tech-transfer@andrew.cmu.edu
 *
 * 4. Redistributions of any form whatsoever must retain the following
 *    acknowledgment:
 *    "This product includes software developed by Computing Services
 *     at Carnegie Mellon University (http://www.cmu.edu/computing/)."
 *
 * CARNEGIE MELLON UNIVERSITY DISCLAIMS ALL WARRANTIES WITH REGARD TO
 * THIS SOFTWARE, INCLUDING ALL IMPLIED WARRANTIES OF MERCHANTABILITY
 * AND FITNESS, IN NO EVENT SHALL CARNEGIE MELLON UNIVERSITY BE LIABLE
 * FOR ANY SPECIAL, INDIRECT OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
 * WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN
 * AN ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING
 * OUT OF OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
 */
```

This product includes software developed by Computing Services at
Carnegie Mellon University (http://www.cmu.edu/computing/).

## GPL compliance note (x11vnc / LibVNCServer)

- The shipped binaries are UNMODIFIED upstream releases; the complete
  GNU GPL v2 text is this repository's `LICENSE` file, and the upstream
  notices remain embedded in the binaries.
- **Written offer (GPL-2 section 3b)**: this project offers, valid for
  at least three years from 2026-09-22 (the date of the first public
  distribution of these binaries), to give any third party the complete
  corresponding source code of the components above, for no more than
  the cost of physically performing the distribution, on request through
  this repository's issue tracker. The upstream links above are the
  exact source releases the bundled binaries were built from.
- The binaries are dynamically linked against the system's own
  libraries (X11, OpenSSL, GnuTLS, cairo, ...) — none of those are
  bundled; the three libraries in the table are shipped alongside
  because stock Batocera does not provide them.

## Switchres (runtime dependency — NOT bundled)

- **Purpose**: CRT modeline generation. Called at runtime through its C
  wrapper API (`sr_*`, `switchres_wrapper.h`) via the ctypes helper
  `src/engine/api/switchres_api.py` — see the engine's
  `docs/SWITCHRES-API.md`.
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
