#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
# Append the logo payload understood by m1n1 to a generated bootloader binary.
set -eu

binary=$1
artwork=$2
test -f "$binary"
logo_tmp=$(mktemp -d)
trap 'rm -rf "$logo_tmp"' EXIT HUP INT TERM

for size in 256 128; do
    magick "$artwork/logos/png_$size/GravityLinux_logomark.png" \
        -background black -flatten -depth 8 -resize "${size}x${size}!" \
        "rgba:$logo_tmp/gravity_$size.rgba"
done
# Only append after both conversions succeed.
printf 'm1n1_logo_256128' >> "$binary"
cat "$logo_tmp/gravity_256.rgba" "$logo_tmp/gravity_128.rgba" >> "$binary"
