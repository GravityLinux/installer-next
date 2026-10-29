#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
set -eu
cd "$(dirname "$0")"
# Some Command Line Tools distributions ship Testing's plugin without registering
# its search path. Xcode toolchains normally discover it automatically.
compiler=$(xcrun --find swiftc)
plugin="$(dirname "$compiler")/../lib/swift/host/plugins/testing/libTestingMacros.dylib"
if [ -f "$plugin" ]; then
    exec swift test -Xswiftc -load-plugin-library -Xswiftc "$plugin" "$@"
fi
exec swift test "$@"
