#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0
# Copyright (C) 2026 FreZeeN
# Part of crt-dual — https://github.com/frezeen
"""
JammASD → dual Xbox 360 uinput daemon.

Grabs JammASD keyboard device exclusively, emits 2 uinput Xbox 360 joysticks
(VID=0x045E PID=0x028E) plus a virtual keyboard for hotkeys (Tab/Esc/P).
Reconnects automatically on USB disconnect.
"""

import os, sys, time, signal, select, logging, subprocess
import yaml
import evdev
from evdev import UInput, ecodes as ec

SCRIPT_DIR  = os.path.dirname(os.path.abspath(__file__))
CONFIG_FILE = os.path.join(SCRIPT_DIR, 'config.yml')

XBOX_VID, XBOX_PID, XBOX_VER = 0x045E, 0x028E, 0x0110

log = logging.getLogger('jammASD')


# ── Xbox 360 uinput capabilities ─────────────────────────────────────────

def _xbox_caps():
    A = evdev.AbsInfo
    return {
        ec.EV_KEY: [
            ec.BTN_SOUTH, ec.BTN_EAST, ec.BTN_NORTH, ec.BTN_WEST,
            ec.BTN_TL,    ec.BTN_TR,
            ec.BTN_SELECT, ec.BTN_START, ec.BTN_MODE,
            ec.BTN_THUMBL, ec.BTN_THUMBR,
        ],
        ec.EV_ABS: [
            (ec.ABS_X,     A(0, -32768, 32767, 16, 128, 0)),
            (ec.ABS_Y,     A(0, -32768, 32767, 16, 128, 0)),
            (ec.ABS_Z,     A(0, 0, 255, 0, 0, 0)),
            (ec.ABS_RX,    A(0, -32768, 32767, 16, 128, 0)),
            (ec.ABS_RY,    A(0, -32768, 32767, 16, 128, 0)),
            (ec.ABS_RZ,    A(0, 0, 255, 0, 0, 0)),
            (ec.ABS_HAT0X, A(0, -1, 1, 0, 0, 0)),
            (ec.ABS_HAT0Y, A(0, -1, 1, 0, 0, 0)),
        ],
    }


# ── Digital axis: two opposing keys → ±32767 ─────────────────────────────

class _Axis:
    __slots__ = ('_n', '_p')

    def __init__(self): self._n = self._p = False

    def set(self, is_neg: bool, pressed: bool):
        if is_neg: self._n = pressed
        else:      self._p = pressed

    @property
    def v(self) -> int:
        if self._n and not self._p: return -32767
        if self._p and not self._n: return  32767
        return 0


# ── Player: one Xbox 360 virtual joystick ────────────────────────────────

class Player:
    _COMBO = {ec.BTN_SOUTH, ec.BTN_EAST, ec.BTN_WEST, ec.BTN_NORTH}

    def __init__(self, cfg: dict, mode_flag: list):
        self.name  = cfg['name']
        j          = cfg['joystick']
        self._xn   = getattr(ec, j['x_neg'])
        self._xp   = getattr(ec, j['x_pos'])
        self._yn   = getattr(ec, j['y_neg'])
        self._yp   = getattr(ec, j['y_pos'])
        self._btn  = {getattr(ec, k): getattr(ec, v)
                      for k, v in cfg['buttons'].items()}
        self._trig = {getattr(ec, k): getattr(ec, v)
                      for k, v in cfg.get('triggers', {}).items()}
        self._ax_x = _Axis()
        self._ax_y = _Axis()
        self._ui   = None
        self._mode         = mode_flag  # shared [bool]: False=HAT, True=ABS
        self._combo_keys   = {k for k, v in self._btn.items() if v in self._COMBO}
        self._combo_state  = set()

    def open(self):
        self._ui = UInput(_xbox_caps(), name=self.name,
                          vendor=XBOX_VID, product=XBOX_PID, version=XBOX_VER)
        log.info('%s → %s', self.name, self._ui.device.path)

    def close(self):
        if self._ui:
            try: self._ui.close()
            except Exception: pass
            self._ui = None

    def reset(self):
        self._ax_x = _Axis()
        self._ax_y = _Axis()
        self._ui.write(ec.EV_ABS, ec.ABS_X, 0)
        self._ui.write(ec.EV_ABS, ec.ABS_Y, 0)
        self._ui.write(ec.EV_ABS, ec.ABS_HAT0X, 0)
        self._ui.write(ec.EV_ABS, ec.ABS_HAT0Y, 0)
        self._ui.write(ec.EV_ABS, ec.ABS_Z,  0)
        self._ui.write(ec.EV_ABS, ec.ABS_RZ, 0)
        self._ui.syn()

    def _toggle_mode(self):
        self._mode[0] = not self._mode[0]
        self._ax_x = _Axis()
        self._ax_y = _Axis()
        self._ui.write(ec.EV_ABS, ec.ABS_X, 0)
        self._ui.write(ec.EV_ABS, ec.ABS_Y, 0)
        self._ui.write(ec.EV_ABS, ec.ABS_HAT0X, 0)
        self._ui.write(ec.EV_ABS, ec.ABS_HAT0Y, 0)
        self._ui.syn()
        log.info('%s mode → %s', self.name, 'ABS (analog)' if self._mode[0] else 'HAT (digital)')

    def handle(self, ev) -> None:
        if ev.type != ec.EV_KEY or ev.value == 2:
            return
        pressed = ev.value == 1
        code    = ev.code

        if code in self._combo_keys:
            if pressed:
                self._combo_state.add(code)
                if self._combo_state == self._combo_keys:
                    self._toggle_mode()
            else:
                self._combo_state.discard(code)

        if code in (self._xn, self._xp):
            self._ax_x.set(code == self._xn, pressed)
            val = self._ax_x.v
            if self._mode[0]:
                self._ui.write(ec.EV_ABS, ec.ABS_X, val)
            else:
                self._ui.write(ec.EV_ABS, ec.ABS_HAT0X, -1 if val < 0 else (1 if val > 0 else 0))
            self._ui.syn()
        elif code in (self._yn, self._yp):
            self._ax_y.set(code == self._yn, pressed)
            val = self._ax_y.v
            if self._mode[0]:
                self._ui.write(ec.EV_ABS, ec.ABS_Y, val)
            else:
                self._ui.write(ec.EV_ABS, ec.ABS_HAT0Y, -1 if val < 0 else (1 if val > 0 else 0))
            self._ui.syn()
        elif code in self._trig:
            self._ui.write(ec.EV_ABS, self._trig[code], 255 if pressed else 0)
            self._ui.syn()
        elif code in self._btn:
            self._ui.write(ec.EV_KEY, self._btn[code], int(pressed))
            self._ui.syn()
        else:
            pass


# ── Hotkey passthrough: virtual keyboard for Tab/Esc/P ───────────────────

class HotkeyDev:
    def __init__(self, cfg: dict):
        self._map = {getattr(ec, k): getattr(ec, v) for k, v in cfg.items()}
        self._ui  = None
        self._intercepted_esc = False

    def open(self):
        self._ui = UInput({ec.EV_KEY: sorted(set(self._map.values()))},
                          name='JammASD Hotkeys')
        log.info('Hotkeys → %s', self._ui.device.path)

    def close(self):
        if self._ui:
            try: self._ui.close()
            except Exception: pass
            self._ui = None

    def handle(self, ev) -> None:
        if ev.type != ec.EV_KEY or ev.value == 2:
            return
        if ev.code in self._map:
            mapped_code = self._map[ev.code]
            if mapped_code == ec.KEY_ESC:
                if ev.value == 1: # key press
                    if os.system("pgrep -f shadps4 > /dev/null") == 0:
                        os.system("export DISPLAY=:0; xdotool key alt+F4")
                        self._intercepted_esc = True
                        return
                    else:
                        self._intercepted_esc = False
                elif ev.value == 0: # key release
                    if self._intercepted_esc:
                        self._intercepted_esc = False
                        return
            
            self._ui.write(ec.EV_KEY, mapped_code, ev.value)
            self._ui.syn()


# ── Main daemon ───────────────────────────────────────────────────────────

class Daemon:
    def __init__(self, cfg: dict):
        self._path    = cfg['device_path']
        self._delay   = float(cfg.get('reconnect_delay', 2.0))
        self._mode    = [False]  # shared: False=HAT (default), True=ABS
        self._players = [Player(p, self._mode) for p in cfg['players']]
        hk_cfg        = cfg.get('hotkeys') or {}
        self._hotkeys = HotkeyDev(hk_cfg) if hk_cfg else None
        self._outputs = self._players + ([self._hotkeys] if self._hotkeys else [])
        self._src     = None
        self._running = True
        signal.signal(signal.SIGTERM, lambda *_: setattr(self, '_running', False))
        signal.signal(signal.SIGINT,  lambda *_: setattr(self, '_running', False))

    def _kill_competitors(self):
        """Kill keyboardToPads/evsieve holding the JammASD device."""
        try:
            real = os.path.basename(os.path.realpath(self._path))
            subprocess.run(['pkill', '-f', f'evsieve.*{real}'],        capture_output=True)
            subprocess.run(['pkill', '-f', f'keyboardToPads.*{real}'], capture_output=True)
        except Exception:
            pass

    def _open_src(self) -> bool:
        try:
            dev = evdev.InputDevice(self._path)
            dev.grab()
            self._src = dev
            log.info('Grabbed %s', dev.name)
            return True
        except FileNotFoundError:
            return False
        except Exception as ex:
            log.warning('Cannot grab source: %s', ex)
            return False

    def _close_src(self):
        if self._src:
            try: self._src.ungrab()
            except Exception: pass
            try: self._src.close()
            except Exception: pass
            self._src = None

    def run(self):
        self._kill_competitors()
        time.sleep(1.2)   # wait for keyboardToPads uinput devices to disappear

        for out in self._outputs:
            out.open()

        log.info('Virtual devices ready. Waiting for JammASD at %s', self._path)

        while self._running:
            if not self._open_src():
                time.sleep(self._delay)
                continue

            for p in self._players:
                p.reset()

            try:
                while self._running:
                    r, _, _ = select.select([self._src.fd], [], [], 0.5)
                    if r:
                        for ev in self._src.read():
                            for out in self._outputs:
                                out.handle(ev)
            except OSError as ex:
                log.warning('Device lost (%s) — retry in %.1fs', ex, self._delay)
                self._close_src()
                self._kill_competitors()   # kill new evsieve started by udev on reconnect
                time.sleep(self._delay)

        self._close_src()
        for out in self._outputs:
            out.close()
        log.info('Stopped.')


# ── Entry point ───────────────────────────────────────────────────────────

def main():
    with open(CONFIG_FILE) as f:
        cfg = yaml.safe_load(f)

    handlers = [logging.StreamHandler(sys.stdout)]
    if cfg.get('log_path'):
        handlers.append(logging.FileHandler(cfg['log_path']))
    logging.basicConfig(
        level=logging.INFO,
        format='%(asctime)s %(levelname)s %(message)s',
        handlers=handlers,
    )

    Daemon(cfg).run()


if __name__ == '__main__':
    main()
