# SPDX-License-Identifier: GPL-2.0
# Copyright (C) 2026 FreZeeN
# Part of crt-dual — https://github.com/frezeen
# vnc-env.sh — shared environment for the bundled x11vnc
#
# Sourced by: src/vnc/vnc, src/vnc/vnc-scaled (and anything else in the
# package that launches x11vnc). Sets the binary dir, LD_LIBRARY_PATH and
# the runtime libcrypt.so.1 symlink.
#
# Why the libcrypt symlink: the bundled x11vnc (0.9.17) links
# libcrypt.so.1, but stock Batocera 43 ships only libcrypt.so.2. The
# crypt ABI is stable — symlinking .2 as .1 works (verified on box:
# x11vnc -version runs clean).
#
# The launcher is self-contained: LD_LIBRARY_PATH is set here, nothing
# is inherited from any external framework.

VNC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" 2>/dev/null || VNC_DIR="/userdata/system/crt-dual/src/vnc"
VNC_BIN="$VNC_DIR/binaries"
export LD_LIBRARY_PATH="$VNC_BIN${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

# Runtime symlink libcrypt.so.1 -> the system's libcrypt.so.2 (created
# here, removed with the package at uninstall; recreated if stale).
if [ ! -e "$VNC_BIN/libcrypt.so.1" ]; then
	_c2=""
	command -v ldconfig >/dev/null 2>&1 && _c2=$(ldconfig -p 2>/dev/null | awk '/libcrypt\.so\.2/{print $NF; exit}')
	[ -z "$_c2" ] && [ -f /usr/lib/libcrypt.so.2 ] && _c2="/usr/lib/libcrypt.so.2"
	[ -z "$_c2" ] && [ -f /lib/libcrypt.so.2 ] && _c2="/lib/libcrypt.so.2"
	[ -n "$_c2" ] && ln -sf "$_c2" "$VNC_BIN/libcrypt.so.1" 2>/dev/null || true
fi
