# SPDX-License-Identifier: GPL-2.0
# Copyright (C) 2026 FreZeeN
# Part of crt-dual — https://github.com/frezeen
# vnc-env.sh — shared environment for the bundled TigerVNC shadow server
#
# Sourced by: src/vnc/vnc, src/vnc/vnc-scaled (and anything else in the
# package that launches the server). Sets the binary dir and
# LD_LIBRARY_PATH.
#
# Why a private library path: the bundled X0tigervnc (TigerVNC 1.12.0)
# links libjpeg.so.62, which stock Batocera 43 does not ship (it carries
# libjpeg.so.8 only). libjpeg-turbo is ABI-stable and ships beside the
# binary in binaries/ — nothing is installed system-wide.
#
# The launcher is self-contained: LD_LIBRARY_PATH is set here, nothing
# is inherited from any external framework.

VNC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" 2>/dev/null || VNC_DIR="/userdata/system/crt-dual/src/vnc"
VNC_BIN="$VNC_DIR/binaries"
export LD_LIBRARY_PATH="$VNC_BIN${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
