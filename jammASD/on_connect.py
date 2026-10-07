#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0
# Copyright (C) 2026 FreZeeN
# Part of rgs-crt — https://github.com/frezeen
import sys
import time
import subprocess

def main():
    if len(sys.argv) < 2:
        sys.exit(0)
    devname = sys.argv[1]
    time.sleep(0.9)
    # Kills evsieve passthrough that keyboardToPads starts when no config is found.
    # Our Python daemon grabs the device; evsieve gets no events anyway.
    subprocess.run(["pkill", "-f", f"evsieve.*{devname}"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

if __name__ == "__main__":
    main()
