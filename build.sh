#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
set -eu
cd "$(dirname "$0")"
root=$PWD
if [ "$(uname -s)" != Darwin ]; then
    echo 'The SwiftUI installer must be packaged on macOS. Provide BOOT_ASSETS_DIR or build m1n1 separately and provide M1N1_STAGE1.' >&2
    exit 1
fi
. ./scripts/version.sh
version=$installer_release
if [ "${PREVIEW:-0}" != 0 ]; then
    echo 'Use scripts/build-app.sh for previews; release archives must contain the real installer.' >&2
    exit 1
fi
if [ -z "${BOOT_ASSETS_DIR:-}" ] && [ -z "${M1N1_STAGE1:-}" ]; then
    test -f bootloader/Makefile
    make -C bootloader RELEASE=1 CHAINLOADING=1 NO_DISPLAY=1 -j4
    make -C bootloader RELEASE=1 CHAINLOADING=1 NO_DISPLAY=1 -j4
    mkdir -p build
    cp bootloader/build/m1n1.bin build/m1n1.bin
    sh tools/append-boot-logo.sh build/m1n1.bin artwork
    M1N1_STAGE1="$root/build/m1n1.bin"
fi
export M1N1_STAGE1
staging=$(mktemp -d)
trap 'rm -rf "$staging"' EXIT HUP INT TERM
sh scripts/build-app.sh "$staging/Gravity Installer.app"
cp install.sh "$staging/install.sh"
printf '%s\n' "$version" > "$staging/version.tag"
mkdir -p releases
tar --no-mac-metadata --no-fflags --no-acls --no-xattrs -czf "releases/installer-$version.tar.gz" -C "$staging" .
(cd releases && /usr/bin/shasum -a 256 "installer-$version.tar.gz" > "installer-$version.tar.gz.sha256")
cp scripts/bootstrap-prod.sh scripts/bootstrap-dev.sh releases/
printf '%s\n' "$version" > releases/latest
echo "Built releases/installer-$version.tar.gz"
