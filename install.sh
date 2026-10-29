#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
set -eu
cd "$(dirname "$0")"
export LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8
if [ -x "$PWD/../MacOS/gravity-installer" ]; then
    binary="$PWD/../MacOS/gravity-installer"
else
    binary="$PWD/Gravity Installer.app/Contents/MacOS/gravity-installer"
fi
if [ "$(uname -m)" != arm64 ]; then
    exec /usr/bin/arch -arm64 /bin/sh "$PWD/$(basename "$0")" "$@"
fi
if [ -f installer_data.json ]; then
    set -- --catalog "$PWD/installer_data.json" "$@"
elif [ -n "${INSTALLER_DATA:-}" ]; then
    set -- --catalog "$INSTALLER_DATA" "$@"
fi
if [ -n "${REPO_BASE:-}" ]; then set -- --repository "$REPO_BASE" "$@"; fi
terminal=0
privileged=0
demo=0
for argument in "$@"; do
    case "$argument" in
        --tui) terminal=1; privileged=1 ;;
        --api|--inspect) privileged=1 ;;
        --demo) demo=1 ;;
    esac
done
if [ "$terminal" = 1 ]; then
    # curl | sh leaves stdin connected to the bootstrap script. The interactive
    # client must read from the user's terminal; API clients retain their pipes.
    if ! (: </dev/tty) 2>/dev/null; then
        echo 'The TUI needs an interactive terminal. Use --api for piped automation.' >&2
        exit 1
    fi
    exec </dev/tty >/dev/tty 2>/dev/tty
fi
if [ "$demo" = 0 ] && [ "$privileged" = 1 ] && [ "$(id -u)" != 0 ]; then
    exec /usr/bin/sudo "$binary" "$@"
fi
exec "$binary" "$@"
