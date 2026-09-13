# Third-party components

This repository bundles the following third-party components. All are
GPL-2.0 licensed (compatible with this repository's LICENSE) and are
shipped for stock Batocera, where the equivalent tool is not present
(verified: no x11vnc/wayvnc/tigervnc on stock Batocera 43.1).

## x11vnc 0.9.17

- **Purpose**: VNC server for the X11 desktop (`vnc` / `vnc-scaled`
  launchers and the `zz_crt_dual_vnc` autostart service).
- **License**: GPL-2.0 (x11vnc is distributed under the GNU GPL v2).
- **Provenance**: binary built 2025-04-11, ported from a private
  development repository (not part of this public tree).
  Source: <https://github.com/LibVNC/x11vnc> (tag 0.9.17).
- **Modifications**: none — the binary is used as-is. Its only runtime
  adaptation is a `libcrypt.so.1` symlink to the system's
  `libcrypt.so.2` (stock Batocera 43 ships only .2; the crypt ABI is
  stable — see `src/vnc/vnc-env.sh`).

## Bundled shared libraries (in `src/vnc/binaries/`)

| File | Component | License |
| --- | --- | --- |
| `libvncserver.so.1` | LibVNCServer (server library for x11vnc) | GPL-2.0 |
| `libvncclient.so.1` | LibVNCClient (client library for x11vnc) | GPL-2.0 |
| `libsasl2.so.2` | Cyrus SASL (SASL support for x11vnc) | BSD-style (Cyrus SASL license) |

## Switchres (runtime dependency — NOT bundled)

- **Purpose**: CRT modeline generation. Called at runtime through its C
  wrapper API (`sr_*`, `switchres_wrapper.h`) via the ctypes helper
  `src/api/switchres_api.py` — see `docs/SWITCHRES-API.md`.
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

## GPL compliance note

- The bundled binaries are dynamically linked against the system's own
  GPL-compatible libraries (X11, openssl, cairo, …) where possible; the
  three bundled libraries above are shipped alongside because stock
  Batocera does not provide them.
- The source for x11vnc / LibVNCServer is available from the upstream
  links above; the exact build configuration used for the bundled
  binaries is recorded in the provenance note of this file (built from
  upstream tags, no source modifications). If a source copy is required,
  please open an issue in this repository.
- This file exists to satisfy the obligations of the GPL before any
  public distribution.
