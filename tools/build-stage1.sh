#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
# Build CDN boot content separately from the installer app.
set -eu
cd "$(dirname "$0")/.."
root=$PWD
output=${1:-"$root/releases/boot/m1n1.bin"}
case "$output" in /*) ;; *) output="$root/$output" ;; esac
stage1_work=$(mktemp -d)
trap 'rm -rf "$stage1_work"' EXIT HUP INT TERM
if [ -n "${M1N1_STAGE1:-}" ]; then
    # Supplied qualified binaries already include their branding.
    cp "$M1N1_STAGE1" "$stage1_work/m1n1.bin"
else
    test -f bootloader/Makefile
    make -C bootloader RELEASE=1 CHAINLOADING=1 NO_DISPLAY=1 -j4
    make -C bootloader RELEASE=1 CHAINLOADING=1 NO_DISPLAY=1 -j4
    cp bootloader/build/m1n1.bin "$stage1_work/m1n1.bin"
    sh tools/append-boot-logo.sh "$stage1_work/m1n1.bin" artwork
fi
test -s "$stage1_work/m1n1.bin"
mkdir -p "$(dirname "$output")"
cp "$stage1_work/m1n1.bin" "$output"
chmod 644 "$output"
(cd "$(dirname "$output")" && /usr/bin/shasum -a 256 "$(basename "$output")") > "$output.sha256"
echo "Prepared $output and $output.sha256 for CDN upload"
