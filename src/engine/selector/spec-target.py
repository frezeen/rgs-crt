#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0
# Copyright (C) 2026 FreZeeN
# Part of crt-dual — https://github.com/frezeen
"""spec-target.py — print a profile's [display] target.

One helper for the two call sites that used to inline the same bootstrap
(selector-core.sh profile discovery, apply_profile.sh display switch):
one authoritative parser (merge.parse_spec), one crash-safe fallback.
A profile with a broken spec falls back to 'crt', exactly like before.

Usage: spec-target.py <profile-dir>
Exit 0 always; prints the target (crt/lcd) or 'crt' on any failure.
"""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
try:
    import merge
    _label, _desc, dt, *_ = merge.parse_spec(Path(sys.argv[1]))
    print(dt)
except Exception:
    print("crt")
