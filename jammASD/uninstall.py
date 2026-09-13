#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0
# Copyright (C) 2026 FreZeeN
# Part of crt-dual — https://github.com/frezeen
import os
import sys
import shutil
import subprocess

# RGS-15KHZ-EXT (2026-09-10): env-overridable paths (hermetic seam
# tests/seams/test_jammasd_udev_deploy.sh); defaults are the live box.
JAMMDIR = os.environ.get("JAMMASD_DIR", "/userdata/system/jammASD")
YAML = os.environ.get(
    "JAMMASD_YAML",
    "/userdata/system/configs/keyboardToPads/inputs/ASDJammASDInterfaceKeyboard.v04d8.pf3ad.yml",
)
UDEV_DST = os.environ.get(
    "JAMMASD_UDEV_DST", "/etc/udev/rules.d/99-jammASD-xbox.rules"
)
UDEV_LEGACY = os.environ.get(
    "JAMMASD_UDEV_LEGACY", "/userdata/system/udev/rules.d/99-jammASD-xbox.rules"
)
SERVICE_FILE = os.environ.get(
    "JAMMASD_SERVICE_FILE", "/userdata/system/services/jammASD"
)

def main():
    print("=== JammASD Xbox Daemon — Python Uninstaller ===")

    # 1. Stop and Disable service
    if os.path.exists(SERVICE_FILE):
        print("[INFO] Stopping and disabling jammASD service...")
        subprocess.run(["batocera-services", "stop", "jammASD"])
        subprocess.run(["batocera-services", "disable", "jammASD"])
        try:
            os.remove(SERVICE_FILE)
            print("[OK] Service stopped, disabled, and removed.")
        except Exception as e:
            print(f"[WARN] Could not remove service file: {e}")
    else:
        subprocess.run(["pkill", "-f", "jammASD_xbox.py"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        print("[OK] Daemon stopped.")

    # 2. Remove udev rule(s) — current /etc location + legacy userdata
    # copy — and reload udev (removal persisted at the end).
    removed = False
    for rule in (UDEV_DST, UDEV_LEGACY):
        if os.path.exists(rule):
            try:
                os.remove(rule)
                removed = True
                print(f"[OK] Udev rule removed: {rule}")
            except Exception as e:
                print(f"[WARN] Could not remove udev rule {rule}: {e}")
    if not removed:
        print("[--] Udev rule not found.")
    else:
        try:
            subprocess.run(["udevadm", "control", "--reload-rules"], check=True)
            print("[OK] Udev rules reloaded.")
        except Exception as e:
            print(f"[WARN] udev reload failed: {e}")

    # 3. Restore keyboardToPads YAML
    if os.path.exists(YAML + ".bak"):
        try:
            shutil.move(YAML + ".bak", YAML)
            print("[OK] keyboardToPads YAML restored.")
        except Exception as e:
            print(f"[WARN] Could not restore YAML file: {e}")
    elif os.path.exists(YAML):
        print("[--] YAML is already present, no action needed.")
    else:
        print("[--] YAML backup not found, manual restore might be needed.")

    # 4. Clean up deployed files
    if os.path.exists(JAMMDIR):
        try:
            shutil.rmtree(JAMMDIR)
            print(f"[OK] Removed deployed files from {JAMMDIR}.")
        except Exception as e:
            print(f"[WARN] Could not remove deployed folder {JAMMDIR}: {e}")

    # RGS-15KHZ-EXT (2026-09-10): persist the /etc rule removal — the
    # overlay upper is restored from the saved image at reboot, so an
    # unsaved removal would bring the rule back.
    if removed:
        try:
            subprocess.run(["batocera-save-overlay"], check=True)
            print("[OK] Overlay saved (udev removal persists).")
        except Exception as e:
            print(f"[WARN] overlay save failed: {e} — the rule may reappear after reboot")

    print("\n=== Uninstall complete. Please reboot your system. ===")

if __name__ == "__main__":
    main()
