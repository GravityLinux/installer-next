#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only

# Truncation guard: sh parses this complete block before executing it.
if true; then
    set -eu
    if [ ! -d /System ]; then
        echo 'Gravity Linux can only be installed from macOS or recoveryOS.' >&2
        exit 1
    fi
    export LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8
    export PATH="/usr/bin:/bin:/usr/sbin:/sbin:$PATH"

    export INSTALLER_BASE=${INSTALLER_BASE:-https://cdn.gravitylinux.org/installer-dev}
    export VERSION_FLAG=${VERSION_FLAG:-$INSTALLER_BASE/latest}
    export INSTALLER_DATA=${INSTALLER_DATA:-$INSTALLER_BASE/installer_data.json}
    export REPO_BASE=${REPO_BASE:-https://cdn.gravitylinux.org}
    set -- --developer "$@"

    installer_channel=development
    installer_applications=${GRAVITY_APPLICATIONS_DIR:-/Applications}
    installer_app="$installer_applications/Gravity Installer.app"
    installer_update_only=0
    installer_force=0
    installer_check=0
    installer_print_version=0
    for argument in "$@"; do
        case "$argument" in
            --update|--update-only) installer_update_only=1 ;;
            --reinstall) installer_update_only=1; installer_force=1 ;;
            --check-update) installer_check=1 ;;
            --version) installer_print_version=1 ;;
        esac
    done
    if [ "$installer_print_version" = 1 ]; then
        if [ -x "$installer_app/Contents/MacOS/gravity-installer" ]; then
            exec "$installer_app/Contents/MacOS/gravity-installer" --version
        fi
        echo 'Gravity Installer is not installed.' >&2
        exit 1
    fi
    installer_version=$(curl -fsSL --retry 3 --connect-timeout 30 "$VERSION_FLAG")
    case "$installer_version" in
        ''|*[!A-Za-z0-9._-]*) echo 'Invalid installer release version.' >&2; exit 1 ;;
    esac
    if [ "$installer_check" = 1 ]; then
        echo "Latest installer release: $installer_version"
        if [ -x "$installer_app/Contents/MacOS/gravity-installer" ]; then
            "$installer_app/Contents/MacOS/gravity-installer" --version
        else
            echo 'Gravity Installer is not installed.'
        fi
        exit 0
    fi
    installer_work=$(mktemp -d "${TMPDIR:-/tmp}/gravity-install.XXXXXX")
    trap 'rm -rf "$installer_work"' EXIT HUP INT TERM
    cd "$installer_work"
    echo "Downloading Gravity Installer release ${installer_version}..."
    installer_package="installer-$installer_version.tar.gz"
    curl -fsSL --retry 3 --connect-timeout 30 -o "$installer_package" "$INSTALLER_BASE/$installer_package"
    curl -fsSL --retry 3 --connect-timeout 30 -o "$installer_package.sha256" "$INSTALLER_BASE/$installer_package.sha256"
    read -r installer_expected installer_checksum_name < "$installer_package.sha256"
    case "$installer_expected" in
        *[!0-9a-fA-F]*|'') echo 'Invalid installer checksum.' >&2; exit 1 ;;
    esac
    if [ "${#installer_expected}" != 64 ] || [ "$installer_checksum_name" != "$installer_package" ]; then
        echo 'Invalid installer checksum manifest.' >&2
        exit 1
    fi
    installer_actual=$(/usr/bin/shasum -a 256 "$installer_package")
    installer_actual=${installer_actual%% *}
    if [ "$installer_actual" != "$installer_expected" ]; then
        echo 'Installer download checksum mismatch. Run the download command again.' >&2
        exit 1
    fi
    tar -xzf "$installer_package"
    installer_source="$installer_work/Gravity Installer.app/Contents/MacOS/gravity-installer"
    if [ ! -x "$installer_source" ]; then echo 'The release archive has no installer app.' >&2; exit 1; fi
    # The downloaded, verified native helper stages and atomically replaces the app.
    # All options are arguments, never shell code or administrator passwords.
    if [ "$installer_force" = 1 ]; then installer_deploy_flag=--force-deploy; else installer_deploy_flag=--gui; fi
    if [ "$(id -u)" = 0 ] || [ -w "$installer_applications" ]; then
        "$installer_source" --deploy-app "$installer_app" --expected-release "$installer_version" --update-channel "$installer_channel" \
            --installer-base "$INSTALLER_BASE" --latest-url "$VERSION_FLAG" --catalog "$INSTALLER_DATA" --repository "$REPO_BASE" \
            "$installer_deploy_flag" > deployment.json
    else
        sudo "$installer_source" --deploy-app "$installer_app" --expected-release "$installer_version" --update-channel "$installer_channel" \
            --installer-base "$INSTALLER_BASE" --latest-url "$VERSION_FLAG" --catalog "$INSTALLER_DATA" --repository "$REPO_BASE" \
            "$installer_deploy_flag" > deployment.json
    fi
    installer_status=$(/usr/bin/plutil -extract status raw -o - deployment.json)
    installer_display_version=$(/usr/bin/plutil -extract build.version raw -o - deployment.json)
    echo "Gravity Installer $installer_display_version: $installer_status at $installer_app"
    cd /
    rm -rf "$installer_work"
    trap - EXIT HUP INT TERM
    if [ "$installer_update_only" = 1 ]; then exit 0; fi
    # Future launches read the saved channel/endpoints from the installed app.
    unset INSTALLER_BASE VERSION_FLAG INSTALLER_DATA REPO_BASE
    exec caffeinate -dis "$installer_app/Contents/Resources/launch.sh" "$@"
fi
