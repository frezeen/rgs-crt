#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0
# Copyright (C) 2026 FreZeeN
# Part of crt-dual — https://github.com/frezeen
"""merge.py — CRT-DUAL profile engine: apply/remove marked blocks.

The merge engine (bash glue + python merge). Orchestrated
by apply_profile.sh / remove_profile.sh. Parses a profile spec and:

  - keypatches LIVING files per key with value-restore (RGS-15KHZ-EXT:
    [keypatch/<path>] sections — corrective rewrite-or-append on the
    live file, previous line (or absence) archived per key and restored
    at gameStop; the batocera.conf pattern generalized, no frozen copies)
  - provides/restores FULL config files (profile configs/ -> runtime
    target, with persistent backup of the stock file)
  - swaps/restores profile binaries (symlink over the stock binary,
    overlay-safe pattern: the stock binary is the immutable overlay
    lower, so a symlink + rm restores stock with zero copy)

Stock files are NEVER touched outside our keypatched keys / provided
file; everything else in the file is preserved byte-for-byte .

Usage:
    merge.py apply   <profile-dir> <name> <target-root> <backup-root>
    merge.py remove  <profile-dir> <name> <target-root> <backup-root>
    merge.py validate <profile-dir> <name> <target-root>

Exit codes: 0 = ok, 1 = spec/fatal error, 2 = apply failed + rolled back.
All writes are atomic: temp + fsync + rename in the same directory.
"""
import contextlib
import os
import re
import shutil
import subprocess
import sys
import traceback
from pathlib import Path


# ──────────────────────────────────────────────────────────────
# Spec parsing
# ──────────────────────────────────────────────────────────────
class SpecError(Exception):
    pass


# File sections a profile can declare. Anything else in [..] is a SYSTEM
# BLOCK ([global], [mame], ...). Both use [..] so the INI coloring in an
# editor colors them identically — the parser disambiguates by this list
# plus the path/extension rule below.
_KNOWN_SECTIONS = frozenset((
    "display", "batocera", "batocera.conf", "config.files",
    "configs", "binaries", "patches",
))

# Duplicate batocera key precedence: least -> most specific. The runtime
# picks the definition of the most specific MATCHING block (an index into
# this tuple; a higher index wins).
_PRECEDENCE = ("global", "emulator", "system", "core")


def _is_section_header(header: str) -> bool:
    """True = a FILE section, False = a SYSTEM BLOCK ([global], [mame]).

    File sections are the known names ([display], [batocera.conf],
    [config.files], [binaries], [configs], [patches]), the legacy
    per-emulator [patches.<emu>], the key-injection [configs/<path>], and
    any header carrying a path/extension (a generator file like
    [mameGenerator.py], a bare target file like [mame.ini]) — a system
    name never contains '.' or '/'.

    Typed block tags ([system.mame], [emulator.libretro], [core.snes9x])
    carry a '.' but are BLOCKS — the explicit prefix wins over the
    path/extension rule (capability 2026-08-11: match by emulator/core).
    """
    if header in _KNOWN_SECTIONS:
        return True
    if header.startswith(("system.", "emulator.", "core.")):
        return False  # typed block tags — see docstring
    if header.startswith(("patches.", "configs/", "keypatch/")):
        return True
    if "." in header or "/" in header:
        return True
    return False


def parse_spec(profile_dir: Path):
    """Parse spec.conf -> (label, desc, display_target, batocera, patches, ...,
    display_modes). display_modes: RGS-15KHZ-EXT, "mode" -> [(block, WxH@R)].

    batocera: dict key -> value (global batocera.conf keys, [batocera])
    patches: dict key -> value (RAM patches the profile activates, [patches])
    keypatch: dict target_path -> list[(block, key_line)] (RGS-15KHZ-EXT:
        [keypatch/<path>] sections — per-key live patch with restore)

    Block syntax: a profile
    is grouped in SYSTEM blocks `[mame]` / `[snes]` (applied ONLY when a
    game of that system starts) plus a `[global]` block (applied on
    every launch). Inside a block, the sections are named after the FILE
    they modify: [batocera.conf], [mameGenerator.py], [config.files],
    [keypatch/<path>], [binaries]. Both blocks and sections use [..] (so
    Notepad++ INI coloring colors them all); the parser disambiguates: an
    unknown header is a SYSTEM BLOCK, a known file-section name is a
    section (_is_section_header). The parser QUALIFIES every key with the
    active block name, so the returned dicts are flat and the runtime
    (merge apply / sitecustomize) is unchanged — a key inside [mame]
    [batocera.conf] becomes mame.emulator=... exactly as before.

    Legacy flat syntax (no blocks) still parses unchanged.

    RGS-15KHZ-EXT: flat file injection ([configs/<path>] target sections,
    bare target files, ini sub-sections) is REMOVED — it deleted
    pre-existing stock lines on remove (measured). Such a header raises
    SpecError (fail loud at install/verify, never silent).
    """
    spec = profile_dir / "spec.conf"
    if not spec.is_file():
        raise SpecError(f"spec.conf missing in {profile_dir}")

    label = ""
    desc = ""
    display_target = "crt"  # default if missing
    batocera = {}           # global keys -> value
    patches = {}            # RAM patches -> value
    configs = {}            # full-file configs: profile_rel_file -> target
    binaries = {}           # binary swap: profile_rel_binary -> target
    keypatch = {}           # RGS-15KHZ-EXT: per-key live patch: target -> [(block, line)]
    display_modes = {}      # RGS-15KHZ-EXT: per-game SwitchRes want: "mode" -> [(block, value WxH@R)]
    blocks = set()          # blocks declared ([mame], [global], [system.mame]...)
    block_of = {}           # section -> block it belongs to (runtime filter)
    block_type = {}         # block name -> match kind: always/system/emulator/core
    current_keypatch = None  # RGS-15KHZ-EXT: active [keypatch/<path>] target
    block = ""              # active block ([mame]) or "" (legacy flat)
    in_display = False
    in_batocera = False
    in_patches = False
    in_configs = False
    in_binaries = False
    in_keypatch = False     # RGS-15KHZ-EXT
    patches_prefix = ""

    def _key(k: str) -> str:
        """KEY EXACTNESS: batocera.conf keys
        are written EXACTLY as they end up in the file — mame.emulator
        stays mame.emulator, es.resolution stays global. No qualify/strip
        magic: anyone who knows Batocera keys writes the final key. Only
        PATCH ops are qualified with the active block when written bare
        (cli.drop in [mameGenerator.py] -> mame.cli.drop): the block
        declares the generator (mame/libretro), the profile writes the
        op. An already-prefixed key (mame.cli.drop) is left untouched.
        batocera.conf keys are NEVER qualified here."""
        if in_patches and block and block != "global":
            prefix = block + "."
            return k if k.startswith(prefix) else f"{block}.{k}"
        return k

    for raw in spec.read_text(errors="replace").splitlines():
        stripped = raw.strip()
        if not stripped or stripped.startswith("#"):
            continue
        if stripped.startswith("{") and stripped.endswith("}"):
            # legacy alias: {mame} (first block format, replaced by [mame]
            # 2026-08-10 so Notepad++ INI colors blocks like sections)
            block = stripped[1:-1].strip()
            blocks.add(block)
            block_type.setdefault(block, "global" if block == "global" else "system")
            current_keypatch = None
            in_display = in_batocera = in_patches = in_configs = in_binaries = in_keypatch = False
            patches_prefix = ""
            continue
        if stripped.startswith("[") and stripped.endswith("]"):
            header = stripped[1:-1].strip()
            if not _is_section_header(header):
                # SYSTEM BLOCK: [global] / [mame] / [emulator.libretro] —
                # everything until the next section belongs to it.
                # Disambiguated from sections by the known-section list
                # (_is_section_header): INI coloring colors both
                # identically, the parser knows which headers are files.
                # Typed tags ([system.X], [emulator.Y], [core.Z]) declare
                # the match kind; a bare tag is a system block.
                block = header
                if block.startswith("system."):
                    block = block[len("system."):]
                    block_type[block] = "system"
                elif block.startswith("emulator."):
                    block = block[len("emulator."):]
                    block_type[block] = "emulator"
                elif block.startswith("core."):
                    block = block[len("core."):]
                    block_type[block] = "core"
                else:
                    block_type.setdefault(block, "global" if block == "global" else "system")
                blocks.add(block)
                current_file = None
                current_keypatch = None
                current_section = None
                in_display = in_batocera = in_patches = in_configs = in_binaries = in_keypatch = False
                patches_prefix = ""
                continue
            in_display = header == "display"
            in_batocera = header == "batocera" or header == "batocera.conf"
            in_patches = header == "patches" or header.endswith("Generator.py")
            in_configs = header in ("configs", "config.files")
            in_binaries = header == "binaries"
            in_keypatch = header.startswith("keypatch/")
            patches_prefix = ""
            if header.startswith("patches."):
                # per-emulator patch section: [patches.mame] -> the
                # emulator name is prepended to every key inside, so the
                # marker stays flat (mame.cli.drop=-sound) and the RAM
                # patcher is unchanged. docs/PROFILES.md §1 [patches].
                in_patches = True
                patches_prefix = header[len("patches."):].strip() + "."
            if header in ("display", "configs", "binaries", "batocera", "batocera.conf", "patches") or in_patches or in_configs or in_binaries or in_keypatch:
                current_keypatch = None
                if in_keypatch:
                    # RGS-15KHZ-EXT: the block is stored per entry (targets
                    # are unique paths — no block_of collision class).
                    current_keypatch = header[len("keypatch/"):].strip()
                elif block and header not in ("display", "patches", "batocera", "batocera.conf"):
                    block_of[header] = block
                    # RGS-15KHZ-EXT (configs scope): the apply filters look up
                    # the legacy spelling "config.files" while the canonical
                    # section header is "configs" — record both so a [configs]
                    # section inherits its owning block's match. Without the
                    # alias the provision stayed global (live 2026-09-10:
                    # mame.ini provided on every model2/sm2 launch).
                    if header == "configs":
                        block_of["config.files"] = block
            elif "/" in header or "." in header:
                # RGS-15KHZ-EXT: flat file injection ([configs/<path>],
                # bare target files, ini sub-sections) is REMOVED — it
                # deleted pre-existing stock lines on remove (measured).
                # Use [keypatch/<path>] (living files) or [configs]
                # (authored full files). Loud here: parse feeds validate
                # AND apply alike, so a stale section fails at install,
                # never silently at gameStart.
                raise SpecError(
                    f"flat file injection removed: [{header}] — "
                    "use [keypatch/<path>] for living files")
            else:
                # Bare headers are ALWAYS system blocks (see above) — this
                # branch is unreachable; loud instead of silent misparse.
                raise SpecError(f"unknown section: [{header}]")
            continue
        key = stripped.split("=", 1)[0].strip()
        value = stripped.split("=", 1)[1].strip() if "=" in stripped else ""
        if in_display:
            if key == "target" and value in ("crt", "lcd"):
                display_target = value
            # RGS-15KHZ-EXT (display want): per-system [display] mode =
            # WxH@R wish; SwitchRes (arcade_15) resolves the SAFE modeline
            # at gameStart. Stored per block; filtered most-specific at
            # apply, like batocera keys. Shape checked in do_validate.
            elif key == "mode" and value:
                display_modes.setdefault("mode", []).append((block, value))
            continue
        if in_batocera:
            if key:
                full = _key(key)
                # a key may be declared in several blocks (always + a
                # typed block); keep EVERY definition — the runtime picks
                # the most specific matching one (precedence, _filter)
                batocera.setdefault(full, []).append((block, value))
            continue
        if in_patches:
            if key:
                # RGS-15KHZ-EXT: duplicate keys accumulate NEWLINE-separated,
                # one marker line per op value. Space-join was correct only
                # for cli flags and CORRUPTED config ops (two path|kv entries
                # fused on one line: the second never applied, the first got
                # the path embedded — measured 2026-09-06, mupen stayed
                # 960x720 + video_shader line mangled live). Newline is safe
                # for cli too (sitecustomize splits each line on whitespace).
                full_key = patches_prefix + _key(key)
                if full_key in patches:
                    patches[full_key] = patches[full_key] + "\n" + value
                else:
                    patches[full_key] = value
            continue
        if in_configs:
            if key:
                configs[key] = value
            continue
        if in_binaries:
            if key:
                binaries[key] = value
            continue
        if in_keypatch:
            # RGS-15KHZ-EXT: block stored per entry (targets unique).
            if key and current_keypatch:
                keypatch.setdefault(current_keypatch, []).append((block, stripped))
            continue
        if key == "label":
            label = value
        elif key == "description":
            desc = value
        # Any other key outside a known section is ignored (pre-existing
        # leniency for top-level label/description placement — not extended).
        continue
    return (label, desc, display_target, batocera, patches,
            configs, binaries, blocks, block_of, block_type, keypatch,
            display_modes)  # RGS-15KHZ-EXT: 12th element (display want)


def parse_mappings(profile_dir: Path):
    """Parse the [configs] and [binaries] mapping sections.

    configs: dict profile_relative_file -> absolute target path
    binaries: dict profile_relative_binary -> absolute target path
    """
    spec = profile_dir / "spec.conf"
    configs, binaries = {}, {}
    section = None
    for raw in spec.read_text(errors="replace").splitlines():
        stripped = raw.strip()
        if not stripped or stripped.startswith("#"):
            continue
        if stripped.startswith("[") and stripped.endswith("]"):
            section = stripped[1:-1].strip()
            continue
        if section not in ("configs", "binaries") or "=" not in stripped:
            continue
        src, dst = (p.strip() for p in stripped.split("=", 1))
        (configs if section == "configs" else binaries)[src] = dst
    return configs, binaries


# ──────────────────────────────────────────────────────────────
# Atomic write
# ──────────────────────────────────────────────────────────────
def atomic_write(path: Path, content: bytes | str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.parent / f".{path.name}.{os.getpid()}.tmp"
    data = content.encode() if isinstance(content, str) else content
    with open(tmp, "wb") as f:
        f.write(data)
        f.flush()
        os.fsync(f.fileno())
    os.replace(tmp, path)


# ──────────────────────────────────────────────────────────────
# Marked-block injection / removal
# ──────────────────────────────────────────────────────────────
# ──────────────────────────────────────────────────────────────
# Configs (full-file provision) and binaries (symlink swap)
# ──────────────────────────────────────────────────────────────
def provide_configs(profile_dir: Path, configs: dict, target_root: Path,
                    backup_root: Path, name: str) -> None:
    """Backup stock -> copy profile file to target (atomic)."""
    for rel, dst in configs.items():
        src = profile_dir / "configs" / rel
        if not src.is_file():
            raise SpecError(f"configs file missing: {src}")
        dstp = Path(dst) if dst.startswith("/") else target_root / dst
        bak = backup_root / name / "configs" / rel
        bak.mkdir(parents=True, exist_ok=True)
        if (bak / "stock").exists() or (bak / "absent").exists():
            pass  # pre-clean already archived the stock state
        elif dstp.is_file():
            shutil.copy2(dstp, bak / "stock")
        else:
            (bak / "absent").touch()
        atomic_write(dstp, src.read_bytes())
        print(f"  provided {rel} -> {dstp}")


def restore_configs(profile_dir: Path, configs: dict, target_root: Path,
                    backup_root: Path, name: str) -> None:
    for rel, dst in configs.items():
        dstp = Path(dst) if dst.startswith("/") else target_root / dst
        bak = backup_root / name / "configs" / rel
        if (bak / "stock").is_file():
            atomic_write(dstp, (bak / "stock").read_bytes())
            print(f"  restored stock {rel} -> {dstp}")
        elif (bak / "absent").exists():
            dstp.unlink(missing_ok=True)
            print(f"  removed provided {rel} (stock had none)")
        shutil.rmtree(bak, ignore_errors=True)


# ──────────────────────────────────────────────────────────────
# batocera.conf global keys ([batocera] spec section)
# ──────────────────────────────────────────────────────────────
# A profile can set GLOBAL emulator keys (e.g. mame.emulator=mame so ES
# launches the profile's standalone binary instead of a libretro core).
# The stock tool batocera-settings-set is the canonical write path
# (verified: writes `key=value`, no spaces). Reversible: the previous
# value (or absence) is archived per key; remove restores it exactly.
BATOCERA_SET = "/usr/bin/batocera-settings-set"
BATOCERA_GET = "/usr/bin/batocera-settings-get"
BATOCERA_CONF = "/userdata/system/batocera.conf"


def _batocera_prev(key: str, backup_root, name: str) -> Path:
    d = Path(backup_root) / name / "batocera"
    d.mkdir(parents=True, exist_ok=True)
    return d / key.replace(".", "__")


def _batocera_set_inplace(key: str, value: str) -> None:
    # RGS-15KHZ-EXT (position fix, 2026-09-08): batocera-settings-set always
    # APPENDS at file end (proven: a test write lands on the last line),
    # relocating keys that live inside the RGS TUNING zone to the user
    # zone on every apply/restore (observed: global.bezel moved out of the
    # stock zone). In-place replace keeps the stock position; the stock
    # tool is used only when the key is absent (no position to keep).
    if os.path.exists(BATOCERA_CONF) and subprocess.run(
            ["grep", "-qsE", rf"^{re.escape(key)}=", BATOCERA_CONF]).returncode == 0:
        repl = value.replace("\\", "\\\\").replace("&", "\\&").replace("|", "\\|")
        subprocess.run(["sed", "-i", rf"s|^{re.escape(key)}=.*|{key}={repl}|", BATOCERA_CONF],
                       check=False, capture_output=True)
    else:
        subprocess.run([BATOCERA_SET, key, value], check=False, capture_output=True)


def apply_batocera(batocera: dict, backup_root, name: str) -> None:
    if not batocera:
        return
    if not os.path.exists(BATOCERA_SET):
        print(f"  WARN: {BATOCERA_SET} missing — batocera keys not applied")
        return
    for key, value in batocera.items():
        prev_file = _batocera_prev(key, backup_root, name)
        if not prev_file.exists():
            # archive the PREVIOUS state (value or absence) — first apply
            prev = ""
            if os.path.exists(BATOCERA_CONF):
                with contextlib.suppress(OSError):
                    with open(BATOCERA_CONF, encoding="utf-8", errors="replace") as f:
                        for ln in f:
                            if ln.strip().startswith(key + "="):
                                prev = ln.split("=", 1)[1].strip()
                                break
            prev_file.write_text(prev)
        if value == "":
            # RGS-15KHZ-EXT: empty value = session DELETE of a stock key
            # (default fires unforced). restore_batocera already restores
            # value-or-absence from the archive — no new restore path.
            with contextlib.suppress(OSError):
                subprocess.run(["sed", "-i", rf"/^{re.escape(key)}=/d", BATOCERA_CONF],
                               check=False, capture_output=True)
            print(f"  batocera: deleted {key} (session; prev archived)")
            continue
        _batocera_set_inplace(key, value)
        print(f"  batocera: {key}={value}")


def restore_batocera(batocera: dict, backup_root, name: str, remove_missing: bool = False) -> None:
    """Restore profile batocera keys at gameStop.

    remove_missing=True (the gameStop path, which knows the launched
    system): a key of the ACTIVE block without a prev-archive is removed
    from batocera.conf outright (sed, like the absent case) — the archive
    may be missing because the profile was first applied onto a dirty
    conf (pre-2026-08-11 double-prefix era) or a crashed first apply.
    Leaving it would freeze the profile's key as "stock".
    remove_missing=False (rollback path, no system): only keys with a
    recorded previous value are restored — nothing is touched on a
    guess."""
    if not batocera:
        return
    if not os.path.exists(BATOCERA_SET):
        return
    for key in batocera:
        prev_file = _batocera_prev(key, backup_root, name)
        if not prev_file.exists():
            if remove_missing:
                # active-block key, never archived -> remove the line
                # exactly (plain file, sed is the canonical removal)
                with contextlib.suppress(OSError):
                    subprocess.run(["sed", "-i", rf"/^{re.escape(key)}=/d", BATOCERA_CONF],
                                   check=False, capture_output=True)
                    print(f"  batocera: removed {key} (active block, no prev archive)")
            continue
        prev = prev_file.read_text()
        if prev:
            _batocera_set_inplace(key, prev)
            print(f"  batocera: restored {key}={prev}")
        else:
            # was absent before: remove the line exactly (no whiteout for
            # batocera.conf — plain file, sed is the canonical removal)
            with contextlib.suppress(OSError):
                subprocess.run(["sed", "-i", rf"/^{re.escape(key)}=/d", BATOCERA_CONF],
                               check=False, capture_output=True)
            print(f"  batocera: removed {key} (was absent before apply)")
        prev_file.unlink(missing_ok=True)


# ──────────────────────────────────────────────────────────────
# Keypatch files (RGS-15KHZ-EXT): per-key live patch with value-restore.
# The batocera.conf pattern (archive prev per key, restore value-or-
# absence at gameStop) generalized to any flat key=value file — no
# frozen copies, the live file is always the base, so stock evolution
# can never silently rot the profile.
# ──────────────────────────────────────────────────────────────
def _keypatch_prev(target: str, key: str, backup_root, name: str) -> Path:
    d = Path(backup_root) / name / "keypatch" / target.replace("/", "__").replace(".", "__")
    d.mkdir(parents=True, exist_ok=True)
    return d / key.replace(".", "__").replace("/", "__")


def _keypatch_key(line: str) -> str:
    return line.split("=", 1)[0].strip()


def _filter_keypatch(keypatch: dict, system: str | None, block_type: dict | None,
                     emulator: str | None = None, core: str | None = None) -> dict:
    """Keep only the entries whose block matches this launch (global and
    legacy-flat always; typed blocks on match — same rule as batocera)."""
    out: dict = {}
    for target, entries in keypatch.items():
        kept = [(b, ln) for b, ln in entries
                if _block_matches(b, block_type, system, emulator, core)]
        if kept:
            out[target] = kept
    return out


def apply_keypatch(keypatch: dict, target_root, backup_root, name: str) -> None:
    """Corrective rewrite-or-append per key on the LIVE file (single
    read, single atomic write per file). Previous full line archived per
    key on first apply (crash-rerun keeps the ORIGINAL prev, never the
    mid-state). Absent file: created, __absent__ recorded (remove deletes
    it again — no 0-byte residue)."""
    for target, entries in keypatch.items():
        p = Path(target) if target.startswith("/") else Path(target_root) / target
        if p.is_file():
            lines = p.read_text(errors="replace").splitlines()
        else:
            (Path(backup_root) / name / "keypatch"
             / target.replace("/", "__").replace(".", "__")).mkdir(parents=True, exist_ok=True)
            (Path(backup_root) / name / "keypatch"
             / target.replace("/", "__").replace(".", "__") / "__absent__").touch()
            lines = []
            print(f"  keypatch: {target} missing — creating (removed at gameStop)")
        changed = False
        for _block, line in entries:
            key = _keypatch_key(line)
            if not key or "=" not in line:
                raise SpecError(f"keypatch line without '=': {target}: {line}")
            prev_file = _keypatch_prev(target, key, backup_root, name)
            idx = next((i for i, l in enumerate(lines) if _keypatch_key(l) == key), None)
            dupes = [i for i, l in enumerate(lines) if _keypatch_key(l) == key][1:]
            if not prev_file.exists():
                prev_file.write_text(lines[idx] if idx is not None else "")
            if idx is None:
                lines.append(line)
                changed = True
            elif lines[idx] != line:
                lines[idx] = line
                changed = True
            for i in sorted(dupes, reverse=True):
                del lines[i]
                changed = True
            print(f"  keypatch: {target}: {key}={line.split('=', 1)[1].strip()}")
        if changed or not p.is_file():
            atomic_write(p, "\n".join(lines) + ("\n" if lines else ""))


def restore_keypatch(keypatch: dict, target_root, backup_root, name: str) -> None:
    """Restore archived lines per key (byte-exact, spacing kept); keys
    absent pre-apply are deleted; files created by apply are removed
    again when empty (unlink-if-empty — no residue). Archive cleaned."""
    for target, entries in keypatch.items():
        p = Path(target) if target.startswith("/") else Path(target_root) / target
        base = (Path(backup_root) / name / "keypatch"
                / target.replace("/", "__").replace(".", "__"))
        if not base.is_dir():
            continue  # never applied — nothing to do
        keys = list(dict.fromkeys(_keypatch_key(ln) for _, ln in entries if _keypatch_key(ln)))
        if p.is_file():
            lines = p.read_text(errors="replace").splitlines()
        else:
            lines = []
        for key in keys:
            prev_file = _keypatch_prev(target, key, backup_root, name)
            if not prev_file.exists():
                continue
            prev = prev_file.read_text(errors="replace")
            lines = [l for l in lines if _keypatch_key(l) != key]
            if prev:
                lines.append(prev)
                print(f"  keypatch: restored {target}: {key}")
            else:
                print(f"  keypatch: removed {target}: {key} (was absent before apply)")
            prev_file.unlink(missing_ok=True)
        (base / "__absent__").unlink(missing_ok=True)
        if not p.is_file() and not lines:
            pass  # stayed absent — clean
        elif not lines:
            with contextlib.suppress(OSError):
                p.unlink()  # only our lines were ever in it — no residue
                print(f"  keypatch: removed created file {target}")
        else:
            atomic_write(p, "\n".join(lines) + "\n")
        with contextlib.suppress(OSError):
            base.rmdir()  # archives unlinked above; empty dir goes too


# ──────────────────────────────────────────────────────────────
# Generator `.config` post-write edits (RGS-15KHZ-EXT genconfig-archive):
# the sitecustomize wrapper archives the pre-edit line-or-absence per key
# (first apply wins); gameStop value-restores here. Without this, forced
# values persist in living files after a clean remove (proven live:
# video_shader="" stranded post-game despite remove OK — stock never
# writes that key and RA exit-save is off, so nothing heals it).
# `.config.drop` is covered by the same archives: the wrapper stores the
# removed lines (all occurrences, original order) and restore puts them
# byte-back at gameStop (reversibility, profile-discipline 9).
# ──────────────────────────────────────────────────────────────
def _genconfig_prev(target: str, key: str, backup_root, name: str) -> Path:
    d = (Path(backup_root) / name / "genconfig"
         / target.replace("/", "__").replace(".", "__"))
    return d / key.replace(".", "__").replace("/", "__")


def restore_genconfig(patches: dict, target_root, backup_root, name: str) -> None:
    """Restore `.config` post-write edits from the wrapper archives
    (byte-exact lines; absence restores remove the key). Mirrors
    restore_keypatch; entries never applied (no archive dir) leave the
    file untouched. Files are never unlinked (the wrapper only ever
    edits pre-existing files)."""
    for full_key, value in patches.items():
        _head, _, op = full_key.rpartition(".")
        _gen, _, mid = _head.rpartition(".")
        if op == "config":
            pass  # force entries: `path|k=v[;k2=v2]`
        elif op == "drop" and mid == "config":
            pass  # RGS-15KHZ-EXT: `.config.drop` — path|key[;key2],
            # the archive holds the removed lines; bare keys still parse
            # through the same partition("=") below (no '=' = whole key).
            # NB op=="drop" alone would collide with `cli.drop` (mid!=config).
        else:
            continue  # cli.*, mouse, runtime_dir: no file residue
        for one in str(value).split("\n"):
            target, _, kv = one.partition("|")
            target = (target or "").strip()
            if not target or not kv.strip():
                continue
            p = Path(target) if target.startswith("/") else Path(target_root) / target
            base = (Path(backup_root) / name / "genconfig"
                    / target.replace("/", "__").replace(".", "__"))
            if not base.is_dir():
                continue  # never applied — nothing to do
            keys = []
            for item in kv.split(";"):
                k, _, _v = item.partition("=")
                k = k.strip()
                if k and k not in keys:
                    keys.append(k)
            if p.is_file():
                lines = p.read_text(errors="replace").splitlines()
            else:
                lines = []
            for key in keys:
                prev_file = _genconfig_prev(target, key, backup_root, name)
                if not prev_file.exists():
                    continue
                prev = prev_file.read_text(errors="replace")
                lines = [l for l in lines if l.strip().split("=", 1)[0].strip() != key]
                if prev:
                    lines.append(prev)
                    print(f"  genconfig: restored {target}: {key}")
                else:
                    print(f"  genconfig: removed {target}: {key} (was absent before apply)")
                prev_file.unlink(missing_ok=True)
            with contextlib.suppress(OSError):
                base.rmdir()  # archives unlinked above; empty dir goes too
            with contextlib.suppress(OSError):
                # parent skeleton too, when no other target dirs remain
                (Path(backup_root) / name / "genconfig").rmdir()
            atomic_write(p, "\n".join(lines) + ("\n" if lines else ""))


def _overlay_lower_path(rel: str) -> str | None:
    """Find the immutable lower-layer path for a stock file shadowed by the
    overlay upper (e.g. /usr/bin/mame/mame -> /overlay/base2/usr/bin/mame/mame).

    The lower squashfs holds the stock binary; the upper (tmpfs) only ever
    shadows it with a symlink. Returning the lower path gives the engine a
    whiteout-free RESTORE target: retargeting the symlink to it never touches
    the upper whiteout machinery (verified on stock 2026-08-10: ln -sfn over a
    lower file = symlink shadow, NO whiteout; rm/mv of the shadowing entry =
    whiteout char device in the upper that hides the stock forever).
    """
    for d in ("/overlay/base2", "/overlay/base", "/overlay_root/base2", "/overlay_root/base"):
        p = Path(d) / rel
        if p.is_file():
            return str(p)
    return None


def swap_binaries(profile_dir: Path, binaries: dict, target_root: Path,
                  backup_root: Path, name: str) -> None:
    """Symlink-swap the stock binary. NEVER rm a path that shadows a lower
    file (whiteout). The upper entry is ALWAYS a symlink: swap = retarget.
    Restore = retarget back to the immutable lower path (or the original
    symlink target) — zero copy, zero whiteout."""
    for rel, dst in binaries.items():
        src = profile_dir / "binaries" / rel
        if not src.is_file():
            raise SpecError(f"binaries file missing: {src} (user must procure it)")
        dstp = Path(dst)
        bak = backup_root / name / "binaries" / rel
        bak.mkdir(parents=True, exist_ok=True)
        if not (bak / "was_symlink").exists() and not (bak / "was_regular").exists():
            # RGS-15KHZ-EXT (stock-record defense): a was_symlink record must
            # be a CREDIBLE stock target — absolute, resolving to an existing
            # file, never inside the profile binaries tree we swap in. The
            # record self-consumes at restore (rmtree below), so a garbage
            # value (relative path / dangling / our own tree) was recorded as
            # "stock" on the next apply and restored verbatim FOREVER — live
            # 2026-09-10: /usr/bin/mame/mame -> "src/profiles/rgs-15khz/
            # binaries/mame" (relative, dangling from PWD=/userdata). Such a
            # state falls through to the overlay-lower truth instead.
            _cred = False
            if dstp.is_symlink():
                _cur = os.readlink(dstp)
                if os.path.isabs(_cur):
                    _curp = Path(_cur)
                    if (_curp.exists()
                            and not str(_curp).startswith(str(profile_dir) + os.sep)):
                        (bak / "was_symlink").write_text(_cur)
                        _cred = True
            if not _cred:
                lower = _overlay_lower_path(dst.lstrip("/"))
                if lower:
                    (bak / "stock_lower").write_text(lower)
                elif dstp.is_file():
                    # no immutable lower reachable (exotic mount / tests):
                    # keep an exact copy of the stock so restore is byte-exact
                    shutil.copy2(dstp, bak / "stock_copy")
                    print(f"  archived stock copy of {dstp} (no overlay lower found)")
                elif dstp.is_symlink():
                    # shadowing symlink with no reachable lower and no credible
                    # stock target: nothing stock to restore — record it so
                    # restore cleans the shadow + whiteout (regular-file path)
                    (bak / "was_regular").touch()
        dstp.parent.mkdir(parents=True, exist_ok=True)
        # retarget-only: if a regular file is still in place (first swap after
        # install without conversion), ln -sfn shadows it with no whiteout
        dstp.unlink(missing_ok=True)
        os.symlink(src, dstp)
        print(f"  swapped {rel} -> {dstp}")


def restore_binaries(profile_dir: Path, binaries: dict, target_root: Path,
                     backup_root: Path, name: str) -> None:
    for rel, dst in binaries.items():
        dstp = Path(dst)
        bak = backup_root / name / "binaries" / rel
        if not (bak / "was_symlink").exists() and not (bak / "was_regular").exists():
            continue  # nothing recorded (never swapped) — no-op
        target = None
        if (bak / "was_symlink").exists():
            target = (bak / "was_symlink").read_text().strip() or None
        elif (bak / "stock_lower").exists():
            target = (bak / "stock_lower").read_text().strip() or None
        if target:
            dstp.unlink(missing_ok=True)
            os.symlink(target, dstp)
            print(f"  restored stock {rel} -> {dstp} -> {target}")
        elif (bak / "stock_copy").is_file():
            atomic_write(dstp, (bak / "stock_copy").read_bytes())
            print(f"  restored stock {rel} (copied back)")
        else:
            # no immutable lower found (rare): remove the shadowing symlink and
            # the whiteout char device from the overlay upper, then revalidate
            if dstp.is_symlink():
                dstp.unlink(missing_ok=True)
            for upper in ("/overlay/overlay", "/overlay_root/overlay"):
                w = Path(upper) / dst.lstrip("/")
                try:
                    w.unlink(missing_ok=True)
                except OSError:
                    continue  # upper not reachable from this namespace; boot restores it
            print(f"  restored stock {rel} ({dstp}, whiteout cleanup)")
        shutil.rmtree(bak, ignore_errors=True)


# ──────────────────────────────────────────────────────────────
# Apply / remove / validate
# ──────────────────────────────────────────────────────────────
PATCH_STATE = "/tmp/crt-dual/patches"


def apply_patches(patches: dict) -> None:
    """Write the ACTIVE RAM patches marker . The engine
    applies — the sitecustomize.py patchers are PASSIVE: they read this file
    at import/call time and act only for declared patches. With no profile
    active the file is absent -> patchers behave exactly stock.
    RGS-15KHZ-EXT: one line per op VALUE (keys repeat) — the reader
    groups by key prefix, so multi-value ops (two libretro.config
    entries) each parse as path|kv."""
    Path(PATCH_STATE).parent.mkdir(parents=True, exist_ok=True)
    if patches:
        lines = []
        for k, v in patches.items():
            for one in str(v).split("\n"):
                lines.append(f"{k}={one}")
        Path(PATCH_STATE).write_text("\n".join(lines) + "\n")
    else:
        Path(PATCH_STATE).unlink(missing_ok=True)


def restore_patches(patches: dict) -> None:
    """Remove the active-patches marker at gameStop (next launch = stock)."""
    Path(PATCH_STATE).unlink(missing_ok=True)


# RGS-15KHZ-EXT (display want): per-game SwitchRes wish (WxH@R) for the
# hook's mode step. The profile declares WHAT geometry it wants; SwitchRes
# (stock arcade_15 preset) resolves the SAFE modeline at gameStart — the
# preset, not us, is the tube safety. Marker mirrors the patches pattern:
# written at apply (this launch only), removed at gameStop.
DISPLAY_WANT = "/tmp/crt-dual/display"


def _pick_display_mode(display_modes: dict, system, block_type, emulator=None, core=None) -> str:
    """Most-specific matching `mode` value (precedence core > system >
    emulator > always — same rule as batocera keys), or "" when no block
    declares one for this launch."""
    best = None  # (precedence_index, value)
    for blk, val in display_modes.get("mode", []):
        if not _block_matches(blk, block_type, system, emulator, core):
            continue
        prec = _PRECEDENCE.index(_block_kind(blk, block_type))
        if best is None or prec > best[0]:
            best = (prec, val)
    return best[1] if best else ""


def apply_display(display_modes: dict, system, block_type, emulator=None, core=None) -> None:
    """Write the ACTIVE display-want marker. Absent want -> marker absent
    (hook keeps dual)."""
    Path(DISPLAY_WANT).parent.mkdir(parents=True, exist_ok=True)
    want = _pick_display_mode(display_modes, system, block_type, emulator, core)
    if want:
        Path(DISPLAY_WANT).write_text(want.strip() + "\n")
    else:
        Path(DISPLAY_WANT).unlink(missing_ok=True)


def restore_display() -> None:
    """Remove the display-want marker at gameStop (next launch = stock)."""
    Path(DISPLAY_WANT).unlink(missing_ok=True)


def _block_kind(block: str, block_type: dict | None) -> str:
    """The match kind of a block: global/system/emulator/core. Bare
    blocks and legacy flat sections are global."""
    if not block or block == "global":
        return "global"
    return (block_type or {}).get(block, "system")


def _block_matches(block: str, block_type: dict | None, system: str | None,
                   emulator: str | None, core: str | None) -> bool:
    """Does the block apply to this launch? global/legacy -> yes; a typed
    block matches its kind ([system.X] -> X == system, [emulator.Y] ->
    Y == resolved emulator, [core.Z] -> Z == resolved core); a bare block
    is a system block (legacy [mame])."""
    if not block or block == "global":
        return True
    kind = (block_type or {}).get(block, "system")
    if kind == "emulator":
        return emulator is not None and emulator == block
    if kind == "core":
        return core is not None and core == block
    return block == system


def _conf_key(conf: Path, key: str) -> str:
    """batocera.conf lookup: the LAST `key=value` line wins (same as
    batocera-settings semantics). Returns '' when absent."""
    if not conf.is_file():
        return ""
    val = ""
    with contextlib.suppress(OSError):
        for ln in conf.read_text(errors="replace").splitlines():
            s = ln.strip()
            if s.startswith(key + "="):
                val = s.split("=", 1)[1].strip()
    return val


def _defaults_val(system: str, field: str, defaults_dir: Path) -> str:
    """Stock default library lookup, mirroring configgen Emulator()
    (verified 2026-08-11 on box 43.1): configgen-defaults-arch.yml
    overrides configgen-defaults.yml, per-system overrides [default].
    Returns '' when absent."""
    try:
        import yaml
    except ImportError as e:
        print(f"CRT-DUAL-MERGE: WARN defaults library skipped, pyyaml unavailable ({e})", file=sys.stderr)
        return ""
    for yml_name in ("configgen-defaults-arch.yml", "configgen-defaults.yml"):
        p = defaults_dir / yml_name
        if not p.is_file():
            continue
        try:
            data = yaml.safe_load(p.read_text(errors="replace"))
        except (OSError, yaml.YAMLError) as e:
            print(f"CRT-DUAL-MERGE: WARN defaults library unreadable ({p}): {e} — skipping to next file", file=sys.stderr)
            continue
        if not isinstance(data, dict):
            continue
        entry = data.get(system) or data.get("default") or {}
        if isinstance(entry, dict) and entry.get(field):
            return str(entry[field])
    return ""


def _resolve_emulator_core(system: str, target_root, defaults_dir=None):
    """The emulator/core the launched system will use, resolved exactly
    like configgen (Emulator.py:42-66,130): batocera.conf
    <system>.emulator/.core first, then the stock default library
    (configgen-defaults-arch.yml over configgen-defaults.yml, per-system
    over [default]). Returns (emulator, core) — each '' when unknown.

    The gameStart hook receives emulator/core EMPTY (the RAM patch hoists
    the hook before configgen resolves them, sitecustomize.py) — the
    engine resolves them itself for the [emulator.X]/[core.X] block match.
    Resolution is called TWICE by do_apply (RGS-15KHZ-EXT post-pin):
    PRE-pin (stock config) for the file-based selections, whose emulator
    keys live in system blocks and must not feed back; POST-pin (after the
    keys landed) for the runtime consumers — keypatch, display want and
    the resolve-record — matching what configgen reads at launch.
    do_remove prefers the apply-time record (RGS-15KHZ-EXT), live is
    fallback."""
    conf = Path(target_root) / "batocera.conf"
    emu = _conf_key(conf, system + ".emulator")
    core = _conf_key(conf, system + ".core")
    if defaults_dir is None:
        defaults_dir = Path("/usr/share/batocera/configgen")
    if not emu:
        emu = _defaults_val(system, "emulator", defaults_dir)
    if not core:
        core = _defaults_val(system, "core", defaults_dir)
    return emu, core


# RGS-15KHZ-EXT (resolve-record): gameStop must filter with the
# APPLY-time resolution, not the live one. A profile block that flips
# <system>.emulator with its own keys (e.g. [mame] libretro->standalone)
# would otherwise hide [emulator.*]/[core.*] sections from do_remove:
# apply resolves stock (match), remove re-resolves modified (no match)
# and the keypatch strands with exit 0 (measured live 2026-09-04 vf).
# do_apply records, do_remove prefers the record, live is the fallback.
# Backport for re-vendors: these 3 helpers + the 1-line call sites in
# do_apply/do_remove re-apply onto upstream; `git log --grep=RGS-15KHZ-EXT`.
def _resolve_record_path(backup_root, name: str) -> Path:
    return Path(backup_root) / name / ".resolve"


def _write_resolve(backup_root, name: str, system: str, emulator, core) -> None:
    try:
        p = _resolve_record_path(backup_root, name)
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(f"{system}\n{emulator or ''}\n{core or ''}\n")
    except OSError:
        pass  # record is an optimization; live resolution stays fallback


def _read_resolve(backup_root, name: str, system: str):
    """(emulator, core) recorded at apply, or None (absent/stale/other)."""
    try:
        lines = _resolve_record_path(backup_root, name).read_text().splitlines()
    except OSError:
        return None
    if len(lines) < 3 or lines[0] != system:
        return None
    return lines[1], lines[2]


def _filter_for_system(mapping: dict, system: str | None, block_of: dict, section: str, all_blocks: set | None = None, emulator: str | None = None, core: str | None = None, block_type: dict | None = None):
    """Keep only the entries belonging to the launched launch (system +
    resolved emulator/core).

    Block syntax: batocera keys are EXACT (2026-08-11 directive — written
    as they end up in the file: mame.emulator stays mame.emulator); a key
    may be declared in several blocks and every definition is kept in
    mapping (key -> list[(block, value)]) — the runtime picks the most
    specific MATCHING definition (precedence: core > system > emulator >
    always, the exact key wins unchanged). PATCH keys are qualified with
    the owning block ([mame] [mameGenerator.py] cli.drop ->
    mame.cli.drop — the marker keeps the generator prefix the RAM patcher
    reads, _marker_ops('mame')); the section's block decides the match.
    configs/binaries keys are bare (the section's block is known via
    block_of). system=None or "" (remove/validate/full apply) keeps
    everything.
    """
    if section == "batocera.conf":
        # NO early return on system=None here: the definitions map must
        # ALWAYS be collapsed to the final key->value form (a full apply
        # without a system only matches always/legacy blocks).
        out: dict = {}
        for k, defs in mapping.items():
            best = None  # (precedence_index, value) — most specific match
            for blk, val in defs:
                if not _block_matches(blk, block_type, system, emulator, core):
                    continue
                prec = _PRECEDENCE.index(_block_kind(blk, block_type))
                if best is None or prec > best[0]:
                    best = (prec, val)
            if best is not None:
                out[k] = best[1]
        return out
    if not system:
        return mapping
    if section.endswith("Generator.py") or section == "patches":
        block = block_of.get(section, "")
        if _block_matches(block, block_type, system, emulator, core):
            if not block or block == "global":
                out = dict(mapping)  # global/legacy: everything
            else:
                prefix = block + "."
                out = {k: v for k, v in mapping.items() if k.startswith(prefix)}
        else:
            out = {}
        if all_blocks:  # legacy flat / [global] bare keys -> global
            for k, v in mapping.items():
                if not any(k.startswith(b + ".") for b in all_blocks):
                    out[k] = v
        return out
    block = block_of.get(section, "")
    if _block_matches(block, block_type, system, emulator, core):
        return mapping  # always/legacy or a matching block
    return {}


def do_apply(profile_dir, name: str, target_root, backup_root, system: str | None = None):
    profile_dir = Path(profile_dir)
    target_root = Path(target_root)
    backup_root = Path(backup_root)
    _label, _desc, _dt, batocera, patches, configs, binaries, blocks, block_of, block_type, keypatch, display_modes = parse_spec(profile_dir)

    # per-system filter (block syntax): apply only the launched system's
    # block (+ always + legacy). system=None -> everything (validate path).
    # emulator/core are RESOLVED from the stock config (batocera.conf +
    # configgen-defaults) — the gameStart hook receives them empty (the
    # RAM patch hoists the hook before configgen resolves them,
    # sitecustomize.py). Matched only by [emulator.X]/[core.X] blocks.
    # PRE-pin resolution: drives the FILE-based selections only (keys,
    # patches, configs, binaries). The emulator-pinning keys live in system
    # blocks and must not feed back into their own block selection.
    emulator, core = _resolve_emulator_core(system, target_root) if system else (None, None)
    batocera = _filter_for_system(batocera, system, block_of, "batocera.conf", blocks, emulator, core, block_type)
    patches = _filter_for_system(patches, system, block_of, "mameGenerator.py", blocks, emulator, core, block_type)
    configs = _filter_for_system(configs, system, block_of, "config.files", blocks, emulator, core, block_type)
    binaries = _filter_for_system(binaries, system, block_of, "binaries", blocks, emulator, core, block_type)

    # pre-clean (crash level 1): half-provided files from a previous
    # session that ended without gameStop. Idempotent, no-op when clean —
    # the recovery rule: the backup archive is the truth, restore it
    # before applying fresh.
    restore_configs(profile_dir, configs, target_root, backup_root, name)
    restore_binaries(profile_dir, binaries, target_root, backup_root, name)

    # provide full configs + swap binaries + batocera keys + RAM patches
    provide_configs(profile_dir, configs, target_root, backup_root, name)
    swap_binaries(profile_dir, binaries, target_root, backup_root, name)
    apply_batocera(batocera, backup_root, name)
    apply_patches(patches)
    # RGS-15KHZ-EXT (post-pin resolve): configgen resolves AT LAUNCH, AFTER
    # this apply's own keys landed (the [mame] block pins mame.emulator=mame).
    # The runtime consumers must match the launch that will actually run,
    # not the pre-apply stock default (live 2026-09-10: a standalone-mame
    # session carried the [emulator.libretro] retroarch keypatch — mis-scoped).
    emulator, core = _resolve_emulator_core(system, target_root) if system else (None, None)
    if system:
        _write_resolve(backup_root, name, system, emulator, core)  # RGS-15KHZ-EXT (resolve-record, POST)
    apply_keypatch(_filter_keypatch(keypatch, system, block_type, emulator, core),
                   target_root, backup_root, name)
    apply_display(display_modes, system, block_type, emulator, core)  # RGS-15KHZ-EXT (display want)
    return True


def do_remove(profile_dir, name: str, target_root, backup_root, system: str | None = None):
    profile_dir = Path(profile_dir)
    target_root = Path(target_root)
    backup_root = Path(backup_root)
    _label, _desc, _dt, batocera, patches, configs, binaries, blocks, block_of, block_type, keypatch, display_modes = parse_spec(profile_dir)

    # per-system filter (mirror of do_apply): with the launched system
    # (gameStop passes it — first_script.sh remove_profile "$2"), only the
    # ACTIVE block's keys are restored/removed with remove_missing, so a
    # key of a block never applied to this game is never touched. Without
    # a system (rollback path) everything is processed with the old
    # skip-if-no-prev semantics.
    if system:
        # RGS-15KHZ-EXT (resolve-record): prefer the apply-time record —
        # live conf may carry our own emulator flip (see helper docstring).
        rec = _read_resolve(backup_root, name, system)
        emulator, core = rec if rec is not None else _resolve_emulator_core(system, target_root)
        batocera = _filter_for_system(batocera, system, block_of, "batocera.conf", blocks, emulator, core, block_type)

    restore_configs(profile_dir, configs, target_root, backup_root, name)
    restore_binaries(profile_dir, binaries, target_root, backup_root, name)
    restore_batocera(batocera, backup_root, name, remove_missing=bool(system))
    restore_patches(patches)
    restore_display()  # RGS-15KHZ-EXT (display want): marker always cleaned
    _em, _co = (emulator, core) if system else (None, None)
    restore_keypatch(_filter_keypatch(keypatch, system, block_type, _em, _co),
                     target_root, backup_root, name)
    # RGS-15KHZ-EXT (genconfig-archive): the SAME patches filter as
    # do_apply (same judge for apply and remove — the resolve-record
    # lesson), then value-restore the wrapper `.config` archives.
    restore_genconfig(_filter_for_system(patches, system, block_of, "mameGenerator.py",
                                         blocks, _em, _co, block_type),
                      target_root, backup_root, name)
    with contextlib.suppress(OSError):  # RGS-15KHZ-EXT (resolve-record): record consumed
        _resolve_record_path(backup_root, name).unlink()
    return True


def do_validate(profile_dir: Path, name: str, target_root: Path):
    """Static spec validation — called at install/verify, NEVER at gameStart."""
    label, _desc, display_target, batocera, patches, configs, binaries, blocks, block_of, block_type, keypatch, display_modes = parse_spec(profile_dir)
    if not label:
        raise SpecError("spec has no label")
    if display_target not in ("crt", "lcd"):
        raise SpecError(f"invalid [display] target: {display_target}")
    for _blk, val in display_modes.get("mode", []):  # RGS-15KHZ-EXT (display want)
        if not re.fullmatch(r"\d+x\d+@[\d.]+", (val or "").strip()):
            raise SpecError(f"invalid [display] mode (want WxH@R): {val}")
    configs, binaries = parse_mappings(profile_dir)
    for rel in configs:
        if not (profile_dir / "configs" / rel).is_file():
            raise SpecError(f"configs file missing: {profile_dir}/configs/{rel}")
    for rel in binaries:
        if not (profile_dir / "binaries" / rel).is_file():
            # binary is user-procured (official-script pattern): warn, not fail
            print(f"  WARN: {profile_dir}/binaries/{rel} missing — "
                  f"user must procure it (never shipped)")
    for target, entries in keypatch.items():
        p = Path(target) if target.startswith("/") else target_root / target
        if p.is_file() and not p.read_text(errors="replace"):
            raise SpecError(f"target file empty: {p}")
        for _block, line in entries:
            if "=" not in line:
                raise SpecError(f"keypatch line without '=': {target}: {line}")
    print(f"  spec OK: {name} — {label} ({display_target})")
    return True


def main():
    if len(sys.argv) < 5:
        print(__doc__)
        return 1
    cmd = sys.argv[1]
    if cmd == "validate":
        profile_dir, name, target_root = sys.argv[2:5]
        pd, tr = Path(profile_dir), Path(target_root)
        try:
            do_validate(pd, name, tr)
        except SpecError as e:
            print(f"CRT-DUAL-MERGE: {e}", file=sys.stderr)
            return 1
        except Exception:
            traceback.print_exc()
            return 1
        return 0
    if len(sys.argv) < 6:
        print(__doc__)
        return 1
    profile_dir, name, target_root, backup_root = sys.argv[2:6]
    system = sys.argv[6] if len(sys.argv) > 6 else None
    pd, tr, br = Path(profile_dir), Path(target_root), Path(backup_root)
    try:
        if cmd == "apply":
            do_apply(pd, name, tr, br, system)
        elif cmd == "remove":
            do_remove(pd, name, tr, br, system)
        else:
            print(f"unknown command: {cmd}", file=sys.stderr)
            return 1
    except SpecError as e:
        print(f"CRT-DUAL-MERGE: {e}", file=sys.stderr)
        return 1
    except Exception:
        traceback.print_exc()
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
