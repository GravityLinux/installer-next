#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
# Append the logo payload understood by m1n1 to a generated bootloader binary.
set -eu

binary=$1
artwork=$2
test -f "$binary"
if command -v magick >/dev/null 2>&1; then
    image_converter=magick
elif command -v convert >/dev/null 2>&1; then
    image_converter=convert
else
    echo 'ImageMagick is required to build the boot logo (magick or convert).' >&2
    exit 1
fi
logo_tmp=$(mktemp -d)
trap 'rm -rf "$logo_tmp"' EXIT HUP INT TERM

for size in 256 128; do
    "$image_converter" "$artwork/logos/png_$size/GravityLinux_logomark.png" \
        -background black -flatten -depth 8 -resize "${size}x${size}!" \
        "rgba:$logo_tmp/gravity_$size.rgba"
done
# Only append after both conversions succeed.
printf 'm1n1_logo_256128' >> "$binary"
cat "$logo_tmp/gravity_256.rgba" "$logo_tmp/gravity_128.rgba" >> "$binary"
