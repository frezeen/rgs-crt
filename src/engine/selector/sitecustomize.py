# SPDX-License-Identifier: GPL-2.0
# Copyright (C) 2026 FreZeeN
# Part of crt-dual — https://github.com/frezeen
"""CRT-DUAL — RAM monkey-patch for configgen (import hook).

Strategy:
  - Patch via import hook: load the stock module, then modify functions
    in RAM. No stock .py is ever modified on disk, no overlay/.pyc issue,
    no backup/restore. Survives Batocera updates: the patch applies to
    whatever the CURRENT module content is at import time.
  - Minimal surface: ONE patch (emulatorlauncher) for ONE verified stock
    flaw — the per-game emulator selection must be written to
    batocera.conf BEFORE configgen resolves the generator, but the stock
    gameStart hook runs AFTER that. Configs/keys alone cannot fix this
    ordering (verified on stock Batocera 43.1, 2026-08-10:
    emulatorlauncher.py:103 get_generator() vs :165 gameStart hook).
  - Guarded: patched behavior reads the profile state file at CALL time;
    with no profile active it behaves exactly like stock.
  - Self-verifying: _PATCHER_RESULTS -> verify.sh (a patcher that stops
    matching after an update is a FAIL, not a silent no-op).

Deployment: install.sh copies this file to
/usr/lib/python3.12/site-packages/sitecustomize.py — Python auto-imports
it at every interpreter startup, so the import hook activates by itself.
"""
import contextlib
import importlib.abc
import logging
import os  # RGS-15KHZ-EXT (genconfig-archive): CRT_DUAL_BACKUP_ROOT seam
import sys
from pathlib import Path

_log = logging.getLogger('crt-dual')

# State files : single writer = first_script.sh.
# /tmp/crt-dual/profile = the ACTIVE profile name (or absent = stock).
PROFILE_STATE = Path('/tmp/crt-dual/profile')


def _active_profile() -> str:
    """The profile name written by first_script.sh, or '' = stock."""
    # Patch-discipline: NEVER raise from the hook path — any failure means
    # stock behavior, which is the safe default.
    with contextlib.suppress(Exception):
        if PROFILE_STATE.is_file():
            name = PROFILE_STATE.read_text().strip()
            return name
    return ''


# ──────────────────────────────────────────────
# PATCH: emulatorlauncher — gameStart BEFORE the emulator is resolved
# ──────────────────────────────────────────────
def _patch_emulatorlauncher(module):
    """start_rom: run the gameStart hook BEFORE Emulator() reads
    batocera.conf, so the profile chosen by the selector is applied before
    configgen resolves the generator (emulator/core).

    Stock flaw (verified on box 2026-08-10, emulatorlauncher.py):
      :84  system = Emulator(args, rom)   # reads batocera.conf
      :103 generator = get_generator(system.config.emulator, ...)
      :165 callExternalScripts(..., "gameStart", ...)   # our hook — TOO LATE
    The selector writes mame.emulator=mame via the profile at gameStart;
    with stock ordering that write lands AFTER the generator was chosen, so
    the game always launches with the pre-existing emulator (libretro).

    Fix: hoist the gameStart call to the top of start_rom (before
    Emulator()), and suppress the duplicate gameStart inside the original
    (a flag on callExternalScripts). The gameStop call stays inside the
    original — it runs after the emulator exits, which is correct.
    """
    orig_start_rom = getattr(module, 'start_rom', None)
    if orig_start_rom is None:
        _log.warning("crt-dual: emulatorlauncher.start_rom not found")
        return False

    _orig_ces = module.callExternalScripts
    _sys_scripts = module.SYSTEM_SCRIPTS
    _user_scripts = module.USER_SCRIPTS
    _gs_ran = [False]  # mutable flag for the closure

    def _patched_ces(folder, event, args):
        if event == 'gameStart' and _gs_ran[0]:
            return  # hoisted gameStart already ran — skip the duplicate
        return _orig_ces(folder, event, args)

    def patched_start_rom(args, maxnbplayers, rom, original_rom):
        system_name = args.system
        # gameStart FIRST — before Emulator() reads batocera.conf, so the
        # profile applied by the selector is visible to get_generator().
        # emulator/core are passed empty: they are exactly what the
        # selector decides at this point (it runs before configgen knows).
        _orig_ces(_sys_scripts, "gameStart", [system_name, "", "", original_rom])
        _orig_ces(_user_scripts, "gameStart", [system_name, "", "", original_rom])
        _gs_ran[0] = True
        module.callExternalScripts = _patched_ces
        try:
            return orig_start_rom(args, maxnbplayers, rom, original_rom)
        finally:
            module.callExternalScripts = _orig_ces  # restore
            _gs_ran[0] = False

    module.start_rom = patched_start_rom
    _log.info("crt-dual: emulatorlauncher.start_rom monkey-patched (gameStart first)")
    return True


# GENERIC profile-driven patch engine ( / docs/PROFILES.md)
# ──────────────────────────────────────────────
# The universal system: the PROFILE declares WHAT to touch in its [patches]
# spec section, the ENGINE writes the marker (/tmp/crt-dual/patches), and
# THIS patcher applies it generically to any configgen generator module.
# No named-patch registry: the profile speaks of operations on the
# generated command / config, not of implementation names.
#
# Supported operations (the 4 categories covering ~90% of the old repo's
# patches, analyzed 2026-08-10):
# A. <emu>.cli.drop = -flag [...]   remove flag(+value) from the command
# <emu>.cli.add  = -flag [...]   append flags if absent
# <emu>.cli.set  = -flag value   replace the value of an existing flag
# B. <emu>.mouse    = off           getMouseMode -> False (no host cursor)
# C. <emu>.config   = <path>|<key=value;key2=value2>   post-write edits
#    <emu>.config.drop = <path>|<key[;key2]>  post-write line REMOVAL
#      (RGS-15KHZ-EXT: let the core's own default fire unforced)
# D. <emu>.runtime_dir = <path>     mkdir -p before the emulator runs
#
# Call-time gate (old repo's race lesson): generator modules are imported
# LAZY by get_generator AFTER the hoisted gameStart wrote the marker, but
# the module is cached across games. The wrapper therefore reads the
# CURRENT marker at every call — a profile change between sessions takes
# effect without re-import. No ops declared = passthrough = stock.
PATCH_STATE = Path('/tmp/crt-dual/patches')

# RGS-15KHZ-EXT (genconfig-archive): persistent prev-line archives for
# generator `.config` post-write edits. Without this, forced values
# persist in living files after gameStop (remove has nothing to restore):
# the keypatch path archives per key, `.config` never did. Layout mirrors
# merge.py `_keypatch_prev` (archive full line or "" for absent, first
# apply wins so crash-reruns keep the ORIGINAL prev). Restore lives in
# merge.py `restore_genconfig` (gameStop). `.config.drop` archives the
# REMOVED lines (all occurrences, original order) under the same layout —
# a dropped line is restored byte-back at gameStop.
_GENCONFIG_BACKUP_ROOT = Path(
    os.environ.get('CRT_DUAL_BACKUP_ROOT') or '/userdata/system/crt-dual/backups')


def _genconfig_prev(target: str, key: str, name: str) -> Path:
    d = (_GENCONFIG_BACKUP_ROOT / name / "genconfig"
         / target.replace("/", "__").replace(".", "__"))
    d.mkdir(parents=True, exist_ok=True)
    return d / key.replace(".", "__").replace("/", "__")


def _marker_lines() -> list:
    try:
        if not PATCH_STATE.is_file():
            return []
        return PATCH_STATE.read_text().splitlines()
    except Exception as e:
        _log.warning('crt-dual: patches marker unreadable (%s): %s — treating as no ops declared', PATCH_STATE, e)
        return []


def _marker_ops(short: str) -> dict:
    """Ops declared for generator `short` -> {op: [values]}."""
    ops: dict = {}
    prefix = short + '.'
    for line in _marker_lines():
        key, _, val = line.partition('=')
        key = key.strip()
        if key.startswith(prefix):
            ops.setdefault(key[len(prefix):], []).append(val.strip())
    return ops


def _find_generator_class(module):
    """The generator class of a configgen generator module (any naming).
    PREFERS the class DEFINED in this module (cls.__module__ matches) —
    a generator module imports its base (Generator) and dir() lists it
    first alphabetically, so wrapping the first *Generator found would
    wrap the base class and silently no-op for the actual generator
    (a generic wrap made mame.cli.drop never apply because the wrapper
    landed on Generator instead of MameGenerator)."""
    for name in dir(module):
        if name.endswith('Generator'):
            cls = getattr(module, name)
            if (isinstance(cls, type) and hasattr(cls, 'generate')
                    and getattr(cls, '__module__', '') == module.__name__):
                return cls
    # fallback: no locally-defined class (some generators inherit only)
    for name in dir(module):
        if name.endswith('Generator'):
            cls = getattr(module, name)
            if isinstance(cls, type) and hasattr(cls, 'generate'):
                return cls
    return None


def _apply_cli_ops(cmd, cli: dict) -> None:
    """A. CLI operations on the generated command array."""
    for subop, values in cli.items():
        for raw in values:
            tokens = raw.split()
            if subop == 'drop':
                for flag in tokens:
                    while flag in cmd:
                        i = cmd.index(flag)
                        if i + 1 < len(cmd) and not str(cmd[i + 1]).startswith('-'):
                            del cmd[i:i + 2]  # flag + its value
                        else:
                            del cmd[i]
            elif subop == 'add':
                for flag in tokens:
                    if flag not in cmd:
                        cmd.append(flag)
            elif subop == 'append':
                # RGS-15KHZ-EXT: blind append, tokens verbatim in order, no
                # presence check. For `-s key=value` pairs: `drop`/`add`
                # are per-token (`-s` already in cmd gets skipped while the
                # value lands bare and corrupts the command); append keeps
                # the pair together. Caller responsibility (no dedup);
                # generate() runs once per launch so no accumulation risk.
                for token in tokens:
                    cmd.append(token)
            elif subop == 'set':
                if len(tokens) < 2:
                    continue
                flag, value = tokens[0], tokens[1]
                for i, a in enumerate(cmd):
                    if a == flag and i + 1 < len(cmd):
                        cmd[i + 1] = value
                        break
                else:
                    cmd.extend([flag, value])


def _apply_config_edits(path: str, entries: str, name: str | None = None) -> None:
    """C. key=value edits on a config file the generator rewrites each
    launch (line-based: replace an existing line starting with the key,
    else append). Best-effort for ini-style files.
    RGS-15KHZ-EXT (genconfig-archive): archive the pre-edit full line
    (or absence) per key under backups/<profile>/genconfig/ on FIRST
    apply, so merge.py restore_genconfig can value-restore at gameStop.
    name=None reads the active profile from /tmp/crt-dual/profile
    (seams pass it explicitly). No profile (stock) = apply without
    archive, exactly the old behavior. Archive failures never block the
    game (warn only) — bookkeeping must not break a launch."""
    try:
        if name is None:
            name = _active_profile()
        archive = bool(name)
        if not archive:
            _log.warning("crt-dual: config post-write with no active profile — no archive")
        p = Path(path)
        if not p.is_file():
            _log.warning("crt-dual: config post-write file missing: %s", path)
            return
        lines = p.read_text().splitlines()
        changed = False
        for item in entries.split(';'):
            key, _, value = item.partition('=')
            key = key.strip()
            value = value.strip()
            if not key:
                continue
            idx = next((i for i, ln in enumerate(lines)
                        if ln.strip().split('=', 1)[0].strip() == key), None)
            if archive:
                try:
                    prev_file = _genconfig_prev(path, key, name)
                    if not prev_file.exists():
                        prev_file.write_text(lines[idx] if idx is not None else "")
                except OSError as e:
                    _log.warning("crt-dual: genconfig archive failed %s:%s: %s",
                                 path, key, e)
            replaced = False
            for i, ln in enumerate(lines):
                if ln.strip().split('=', 1)[0].strip() == key:
                    lines[i] = f'{key}={value}'
                    replaced = True
                    changed = True
                    break
            if not replaced:
                lines.append(f'{key}={value}')
                changed = True
        if changed:
            with p.open('w') as _fh:
                _fh.write('\n'.join(lines) + '\n')
    except Exception as e:
        _log.warning("crt-dual: config post-write failed %s: %s", path, e)


def _apply_config_drop(path: str, keys: str, name: str | None = None) -> None:
    """RGS-15KHZ-EXT: C-drop — remove whole lines for the named keys from
    a config file the generator rewrote each launch. Line-based, exact key
    match before '='. Best-effort (missing file = warn, like C).
    RGS-15KHZ-EXT (genconfig-archive): archive the REMOVED lines per key
    (all occurrences, original order, first apply wins) under
    backups/<profile>/genconfig/ so merge.py restore_genconfig puts them
    back at gameStop — reversibility without archive is a design error
    (profile-discipline 9). Same rules as _apply_config_edits: name=None
    reads the active profile; no profile = no archive; archive failure
    warns but never blocks the game."""
    try:
        if name is None:
            name = _active_profile()
        p = Path(path)
        if not p.is_file():
            _log.warning("crt-dual: config-drop file missing: %s", path)
            return
        drop = {k.strip() for k in keys.split(';') if k.strip()}
        if not drop:
            return
        lines = p.read_text().splitlines()
        kept = [ln for ln in lines
                if ln.strip().split('=', 1)[0].strip() not in drop]
        if len(kept) == len(lines):
            return  # nothing matched — no write, no archive (restore no-op)
        if name:
            for key in drop:
                try:
                    removed = [ln for ln in lines
                               if ln.strip().split('=', 1)[0].strip() == key]
                    if not removed:
                        continue  # key not present — nothing to restore
                    prev_file = _genconfig_prev(path, key, name)
                    if not prev_file.exists():
                        prev_file.write_text("\n".join(removed))
                except OSError as e:
                    _log.warning("crt-dual: genconfig archive failed (drop) %s:%s: %s",
                                 path, key, e)
        else:
            _log.warning("crt-dual: config-drop with no active profile — no archive")
        with p.open('w') as _fh:
            _fh.write('\n'.join(kept) + '\n')
    except Exception as e:
        _log.warning("crt-dual: config-drop failed %s: %s", path, e)


def _patch_generic(module, short: str) -> bool:
    """Wrap the generator's generate()/getMouseMode() with call-time gates
    for the profile-declared ops. Returns True when a generator class was
    found (the wrapper is installed and self-verifying via _PATCHER_RESULTS)."""
    cls = _find_generator_class(module)
    if cls is None:
        return False

    orig_generate = cls.generate
    orig_mm = getattr(cls, 'getMouseMode', None)

    def patched_generate(self, *args, **kwargs):
        ops = _marker_ops(short)
        # D. runtime_dir: mkdir -p before the emulator runs
        for d in ops.get('runtime_dir', []):
            try:
                Path(d).mkdir(parents=True, exist_ok=True)
            except OSError as e:
                _log.warning("crt-dual: runtime_dir mkdir %s failed: %s", d, e)
        result = orig_generate(self, *args, **kwargs)
        if result is not None and hasattr(result, 'array'):
            cli = {}
            for k, v in ops.items():
                if k.startswith('cli.'):
                    cli.setdefault(k[4:], []).extend(v)
            if cli:
                _apply_cli_ops(result.array, cli)
        # C. config post-write (after the generator wrote its config)
        for entry in ops.get('config', []):
            path, _, kv = entry.partition('|')
            if path and kv:
                _apply_config_edits(path.strip(), kv)
        # RGS-15KHZ-EXT: C-drop — line removal post-generate
        for entry in ops.get('config.drop', []):
            path, _, keys = entry.partition('|')
            if path and keys:
                _apply_config_drop(path.strip(), keys)
        return result

    cls.generate = patched_generate

    if orig_mm is not None:
        def patched_getMouseMode(self, *args, **kwargs):
            ops = _marker_ops(short)
            if ops.get('mouse') == ['off']:
                return False
            return orig_mm(self, *args, **kwargs)

        cls.getMouseMode = patched_getMouseMode

    _log.info("crt-dual: %s.generate monkey-patched (generic profile ops)", short)
    return True


# ──────────────────────────────────────────────
# REGISTRY: module -> patcher
# ──────────────────────────────────────────────
# Always-on mechanisms (our framework): emulatorlauncher hoist. Generator
# modules are handled generically by _patch_generic (profile-driven).
_PATCHERS = {
    'configgen.emulatorlauncher': _patch_emulatorlauncher,
    # utils.videoMode: NOT patched — the raster channel lives in the stock
    # launcher (the applied resolution-crt-patch hunks announce+generate the
    # declared keys natively; verify.sh 4d owns the drift check).
}


# Last run results (module -> True/False). Consumed by verify.sh — the
# single check that the stock patterns still match the current modules.
_PATCHER_RESULTS = {}


class _CrtDualPatchLoader(importlib.abc.Loader):
    """Load the stock module, then apply the RAM patch (if any)."""
    def __init__(self, original, module_name):
        self._orig = original
        self._name = module_name

    def create_module(self, spec):
        if hasattr(self._orig, 'create_module'):
            return self._orig.create_module(spec)
        return None

    def exec_module(self, module):
        self._orig.exec_module(module)
        patcher = _PATCHERS.get(self._name)
        if patcher is None:
            # generic profile-driven patcher for ANY configgen generator
            # module : wrap generate()/getMouseMode()
            # with call-time gates. Recorded in _PATCHER_RESULTS so a
            # generator class that stops existing after a Batocera update
            # is a visible FAIL when the profile declares ops for it.
            if self._name.startswith('configgen.generators.'):
                short = self._name.rsplit('.', 2)[-2]
                try:
                    _PATCHER_RESULTS[self._name] = _patch_generic(module, short)
                except Exception as e:  # never break configgen at import time
                    _log.error("crt-dual: generic patch failed for %s: %s", self._name, e)
                    _PATCHER_RESULTS[self._name] = False
            return
        try:
            # Contract: True = >=1 patch applied, False = stock pattern not found.
            _PATCHER_RESULTS[self._name] = patcher(module)
        except Exception as e:  # never break configgen at import time
            _log.error("crt-dual: patch failed for %s: %s", self._name, e)
            _PATCHER_RESULTS[self._name] = False


class _CrtDualMetaFinder(importlib.abc.MetaPathFinder):
    """Intercept imports of registered modules OR any configgen generator
    module (generic profile-driven patches), wrap their loader."""
    def find_spec(self, fullname, path, target=None):
        if fullname not in _PATCHERS and not fullname.startswith('configgen.generators.'):
            return None
        for finder in sys.meta_path:
            if finder is self:
                continue
            try:
                spec = finder.find_spec(fullname, path, target)
                if spec is not None:
                    break
            except Exception:
                continue
        else:
            return None
        if spec is not None and spec.loader is not None:
            spec.loader = _CrtDualPatchLoader(spec.loader, fullname)
        return spec


# Activate the hook BEFORE all other finders.
sys.meta_path.insert(0, _CrtDualMetaFinder())

# Force-import emulatorlauncher so the hook triggers at startup
# (emulatorlauncher is the entry point of configgen launches).
if 'configgen.emulatorlauncher' not in sys.modules:
    with contextlib.suppress(Exception):
        import importlib
        importlib.import_module('configgen.emulatorlauncher')

_log.debug("crt-dual: import hook installed, %d modules registered", len(_PATCHERS))
