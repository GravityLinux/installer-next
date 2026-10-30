#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
set -eu
cd "$(dirname "$0")"
if [ "$(uname -s)" != Darwin ]; then
    echo 'The SwiftUI installer must be packaged on macOS.' >&2
    exit 1
fi
. ./scripts/version.sh
version=$installer_release
if [ "${PREVIEW:-0}" != 0 ]; then
    echo 'Use scripts/build-app.sh for previews; release archives must contain the real installer.' >&2
    exit 1
fi
staging=$(mktemp -d)
trap 'rm -rf "$staging"' EXIT HUP INT TERM
sh scripts/build-app.sh "$staging/Gravity Installer.app"
cp install.sh "$staging/install.sh"
printf '%s\n' "$version" > "$staging/version.tag"
mkdir -p releases
tar --no-mac-metadata --no-fflags --no-acls --no-xattrs -czf "releases/installer-$version.tar.gz" -C "$staging" .
(cd releases && /usr/bin/shasum -a 256 "installer-$version.tar.gz" > "installer-$version.tar.gz.sha256")
cp scripts/bootstrap.sh releases/bootstrap.sh
printf '%s\n' "$version" > releases/latest
echo "Built releases/installer-$version.tar.gz"
