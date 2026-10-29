#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
# Build a native arm64 app. PREVIEW=1 builds a safe, self-contained demo bundle.
set -eu
cd "$(dirname "$0")/.."
root=$PWD
. ./scripts/version.sh
output=${1:-"$root/dist/Gravity Installer.app"}
configuration=${CONFIGURATION:-release}
swift build -c "$configuration" --arch arm64
binary_dir=$(swift build -c "$configuration" --arch arm64 --show-bin-path)
mkdir -p "$output/Contents/MacOS" "$output/Contents/Resources"
cp "$binary_dir/gravity-installer" "$output/Contents/MacOS/gravity-installer"
cp "$root/Resources/Info.plist" "$output/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $installer_version" "$output/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $installer_build_number" "$output/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :GravityRelease string $installer_release" "$output/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :GravityRevision string $installer_revision" "$output/Contents/Info.plist"
cp "$root/install.sh" "$output/Contents/Resources/launch.sh"
cp "$root/LICENSE" "$output/Contents/Resources/"
# Clean obsolete resources when rebuilding an existing output bundle.
rm -f "$output/Contents/Resources/NOTICE"
rm -rf "$output/Contents/Resources/licenses/asahi-installer"
if [ "${PREVIEW:-0}" = 1 ]; then
    /usr/libexec/PlistBuddy -c 'Add :GravityDemo bool true' "$output/Contents/Info.plist"
else
    logo=${LOGO:-"$root/artwork/logos/icns/GravityLinux_logomark.icns"}
    test -f "$logo"
    mkdir -p "$output/Contents/Resources/boot" "$output/Contents/Resources/licenses/gravity-artwork"
    if [ -n "${BOOT_ASSETS_DIR:-}" ]; then
        test -d "$BOOT_ASSETS_DIR"
        cp -R "$BOOT_ASSETS_DIR/." "$output/Contents/Resources/boot/"
    else
        test -f "${M1N1_STAGE1:?Set BOOT_ASSETS_DIR or M1N1_STAGE1 to qualified boot assets}"
        cp "$M1N1_STAGE1" "$output/Contents/Resources/boot/m1n1.bin"
    fi
    cp "$logo" "$output/Contents/Resources/logo.icns"
    cp "$logo" "$output/Contents/Resources/Gravity.icns"
    cp "$root/artwork/LICENSE" "$root/artwork/README.md" "$root/artwork/TRADEMARKS.md" "$output/Contents/Resources/licenses/gravity-artwork/"
fi
# Sign outside the bundle. codesign recognizes an app's main executable even
# when passed its file path and otherwise creates a seal over all resources.
# installation.json, boot.bin and stage2.json are intentionally added later.
signature_work=$(mktemp -d)
trap 'rm -rf "$signature_work"' EXIT HUP INT TERM
cp "$output/Contents/MacOS/gravity-installer" "$signature_work/gravity-installer"
/usr/bin/codesign --force --sign - --identifier org.gravitylinux.installer "$signature_work/gravity-installer"
cp "$signature_work/gravity-installer" "$output/Contents/MacOS/gravity-installer"
rm -rf "$output/Contents/_CodeSignature"
/usr/bin/codesign --verify --strict --ignore-resources "$output/Contents/MacOS/gravity-installer"
echo "Built $output"
