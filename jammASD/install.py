#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0
# Copyright (C) 2026 FreZeeN
# Part of crt-dual — https://github.com/frezeen
import os
import sys
import shutil
import subprocess

# RGS-15KHZ-EXT (2026-09-10): every path is env-overridable so the seam
# test (tests/seams/test_jammasd_udev_deploy.sh) can run this installer
# hermetically; defaults are the live box. No path may stay hardcoded — a
# partial seam would leak to the live system (test-flow §Tracked seams).
JAMMDIR = os.environ.get("JAMMASD_DIR", "/userdata/system/jammASD")
YAML = os.environ.get(
    "JAMMASD_YAML",
    "/userdata/system/configs/keyboardToPads/inputs/ASDJammASDInterfaceKeyboard.v04d8.pf3ad.yml",
)
CUSTOM = os.environ.get("JAMMASD_CUSTOM", "/userdata/system/custom.sh")
# RGS-15KHZ-EXT (2026-09-10): udev reads /etc/udev/rules.d on RGS
# (verified on the box: `udevadm test` lists only /etc,/lib,/usr/lib,/run
# rules) — the old /userdata/system/udev/rules.d target was never read.
UDEV_DST = os.environ.get(
    "JAMMASD_UDEV_DST", "/etc/udev/rules.d/99-jammASD-xbox.rules"
)
UDEV_LEGACY = os.environ.get(
    "JAMMASD_UDEV_LEGACY", "/userdata/system/udev/rules.d/99-jammASD-xbox.rules"
)
LOG_FILE = os.environ.get("JAMMASD_LOG", "/var/log/jammASD_install.log")
HOTKEYGEN_DIR = os.environ.get(
    "JAMMASD_HOTKEYGEN_DIR", "/userdata/system/configs/hotkeygen"
)
SERVICE_DIR = os.environ.get("JAMMASD_SERVICE_DIR", "/userdata/system/services")
HOTKEYGEN_MAPPING = "JammASD_Hotkeys-01-01.mapping"

class Tee:
    def __init__(self, filename, mode="w"):
        self.file = open(filename, mode, encoding="utf-8")
        self.stdout = sys.stdout

    def write(self, message):
        self.file.write(message)
        self.stdout.write(message)

    def flush(self):
        self.file.flush()
        self.stdout.flush()

def main():
    # Redirect output to log file
    sys.stdout = Tee(LOG_FILE, "w")
    sys.stderr = sys.stdout

    print("=== JammASD Xbox Daemon — Python Installer ===")

    # 1. Check dependencies
    try:
        import evdev
        import yaml
        print("[OK] Python dependencies (evdev, yaml) are available.")
    except ImportError as e:
        print(f"[ERR] Missing Python dependency: {e.name}. Please ensure evdev and pyyaml are installed.")
        sys.exit(1)

    # 2. Get script source directory
    script_src = os.path.dirname(os.path.abspath(__file__))

    # 3. Deploy files to JAMMDIR
    print(f"[INFO] Deploying files to {JAMMDIR}...")
    os.makedirs(JAMMDIR, exist_ok=True)
    
    for item in os.listdir(script_src):
        s = os.path.join(script_src, item)
        d = os.path.join(JAMMDIR, item)
        if os.path.isdir(s):
            if item != "__pycache__":
                shutil.copytree(s, d, dirs_exist_ok=True)
        else:
            shutil.copy2(s, d)

    # Make deployed scripts executable
    for script in ["install.py", "uninstall.py", "on_connect.py"]:
        path = os.path.join(JAMMDIR, script)
        if os.path.exists(path):
            os.chmod(path, 0o755)
    print(f"[OK] Files successfully deployed.")

    # 4. Backup old keyboardToPads YAML
    if os.path.exists(YAML):
        bak_path = YAML + ".bak"
        try:
            shutil.move(YAML, bak_path)
            print(f"[OK] Backed up legacy keyboardToPads YAML to {os.path.basename(bak_path)}")
        except Exception as e:
            print(f"[WARN] Could not backup YAML file: {e}")
    elif os.path.exists(YAML + ".bak"):
        print("[OK] keyboardToPads YAML is already backed up.")
    else:
        print("[--] keyboardToPads YAML not found (standard keyboard mapping is disabled or inactive).")

    # 5. Stop conflicting keyboardToPads / evsieve / old daemon processes
    print("[INFO] Stopping any conflicting processes...")
    for proc_name in ["keyboardToPads", "evsieve", "jammASD_xbox.py"]:
        subprocess.run(["pkill", "-f", proc_name], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    print("[OK] Conflicting processes stopped.")

    # 6. Install udev rules
    # RGS-15KHZ-EXT (2026-09-10): deploy to the path udev actually reads
    # and drop the legacy userdata copy a previous version may have left
    # (that copy was inert).
    print(f"[INFO] Copying udev rule to {UDEV_DST}...")
    os.makedirs(os.path.dirname(UDEV_DST), exist_ok=True)
    src_rule = os.path.join(JAMMDIR, "99-jammASD-xbox.rules")
    if os.path.exists(src_rule):
        shutil.copy2(src_rule, UDEV_DST)
        os.chmod(UDEV_DST, 0o644)
        subprocess.run(["udevadm", "control", "--reload-rules"], check=True)
        if os.path.exists(UDEV_LEGACY):
            os.remove(UDEV_LEGACY)
            print(f"[OK] Legacy udev rule removed from {UDEV_LEGACY}.")
        print("[OK] Udev rules loaded successfully.")
    else:
        print("[ERR] 99-jammASD-xbox.rules not found in deployed files.")
        sys.exit(1)

    # 7. Create service script for Batocera
    service_dir = SERVICE_DIR
    os.makedirs(service_dir, exist_ok=True)
    service_file = os.path.join(service_dir, "jammASD")
    
    print(f"[INFO] Registering jammASD system service in {service_file}...")
    service_content = """#!/bin/bash

case "${1}" in
    start)
        nohup python3 /userdata/system/jammASD/jammASD_xbox.py >>/var/log/jammASD_xbox.log 2>&1 &
        ;;
    stop)
        pkill -f jammASD_xbox.py
        ;;
    restart)
        $0 stop
        sleep 1
        $0 start
        ;;
esac
exit 0
"""
    with open(service_file, "w", encoding="utf-8") as f:
        f.write(service_content)
    os.chmod(service_file, 0o755)

    # 8. Enable service in Batocera
    print("[INFO] Enabling and starting service...")
    subprocess.run(["batocera-services", "enable", "jammASD"], check=True)
    
    # 9. Clean up legacy entry in custom.sh
    if os.path.exists(CUSTOM):
        try:
            with open(CUSTOM, "r", encoding="utf-8") as f:
                lines = f.readlines()
            new_lines = [line for line in lines if "jammASD_xbox.py" not in line]
            if len(new_lines) != len(lines):
                with open(CUSTOM, "w", encoding="utf-8") as f:
                    f.writelines(new_lines)
                print("[OK] Legacy custom.sh configuration cleaned up.")
        except Exception as e:
            print(f"[WARN] Failed to clean legacy custom.sh: {e}")

    # 10. Create hotkeygen mapping for JammASD Hotkeys virtual keyboard
    # Maps KEY_ESC (emitted by board on p1start+p2start) to the hotkeygen "exit" action,
    # so any emulator using hotkeygen context will receive the correct exit key (e.g. Alt+F4).
    print(f"[INFO] Installing hotkeygen mapping to {HOTKEYGEN_DIR}/{HOTKEYGEN_MAPPING}...")
    os.makedirs(HOTKEYGEN_DIR, exist_ok=True)
    mapping_path = os.path.join(HOTKEYGEN_DIR, HOTKEYGEN_MAPPING)
    with open(mapping_path, "w", encoding="utf-8") as f:
        f.write('{"KEY_ESC": "exit"}\n')
    os.chmod(mapping_path, 0o644)
    print("[OK] hotkeygen mapping installed (p1start+p2start → ESC → exit).")

    # 11. Start the service
    subprocess.run(["batocera-services", "restart", "jammASD"], check=True)
    
    # Verification
    pgrep_check = subprocess.run(["pgrep", "-f", "jammASD_xbox.py"], stdout=subprocess.DEVNULL)
    if pgrep_check.returncode == 0:
        print("[OK] JammASD Xbox daemon started and running via system service.")
    else:
        print("[ERR] Daemon failed to start. Please check log in /var/log/jammASD_xbox.log")
        sys.exit(1)

    # 12. Persist /etc (RGS-15KHZ-EXT 2026-09-10): Batocera's / is an
    # overlay restored from the saved image at every boot — an unsaved
    # udev rule would vanish at reboot. Fatal, same contract as the
    # engine's install.sh.
    print("[INFO] Saving overlay (udev rule must survive reboot)...")
    try:
        subprocess.run(["batocera-save-overlay"], check=True)
    except (FileNotFoundError, subprocess.CalledProcessError) as exc:
        print(f"[ERR] overlay save failed ({exc}) — udev rule would not survive reboot")
        sys.exit(1)
    print("[OK] Overlay saved.")

    print("\n=== Installation completed successfully ===")
    print("Log stored at: /var/log/jammASD_install.log")

if __name__ == "__main__":
    main()
