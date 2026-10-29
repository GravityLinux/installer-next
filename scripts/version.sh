#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
# Sourced by build scripts from the repository root. VERSION is authoritative.
installer_version=$(cat VERSION)
case "$installer_version" in
    ''|*[!0-9.]*) echo 'VERSION must contain a numeric major.minor.patch version.' >&2; exit 1 ;;
esac
if ! printf '%s\n' "$installer_version" | /usr/bin/awk -F. 'NF == 3 && $1 ~ /^[0-9]+$/ && $2 ~ /^[0-9]+$/ && $3 ~ /^[0-9]+$/ {ok=1} END {exit !ok}'; then
    echo 'VERSION must contain major.minor.patch.' >&2
    exit 1
fi
installer_release=${INSTALLER_RELEASE:-$(git describe --always --dirty --tags 2>/dev/null || cat version.tag)}
case "$installer_release" in
    ''|*[!A-Za-z0-9._-]*) echo 'Invalid installer release identifier.' >&2; exit 1 ;;
esac
installer_revision=$(git rev-parse HEAD 2>/dev/null || printf unknown)
installer_build_number=$(git rev-list --count HEAD 2>/dev/null || printf 1)
installer_tag=$(git describe --exact-match --tags 2>/dev/null || true)
case "$installer_tag" in
    v[0-9]*|[0-9]*)
        if [ "${installer_tag#v}" != "$installer_version" ]; then
            echo 'The release tag must match VERSION.' >&2
            exit 1
        fi ;;
esac
export INSTALLER_RELEASE="$installer_release"
