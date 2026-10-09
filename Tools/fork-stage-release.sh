#!/bin/zsh
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Vorssaint

set -euo pipefail
cd "$(dirname "$0")/.."
source Tools/fork-common.sh
fork_require_repository
fork_require_team
version="$(fork_version)"
[[ "${FORK_RELEASE_TAG:-}" == "v$version" ]] || { echo 'Fork release version mismatch.' >&2; exit 1; }
dmg="dist/ShadowUtilities-$version.dmg"
codesign --verify --strict \
    -R="anchor apple generic and certificate leaf[subject.OU] = \"$SHADOW_UPDATE_TEAM_ID\"" "$dmg"
xcrun stapler validate "$dmg"
mount_directory="$(mktemp -d)"
cleanup() {
    hdiutil detach "$mount_directory" -quiet 2>/dev/null || true
    rmdir "$mount_directory" 2>/dev/null || true
}
trap cleanup EXIT
hdiutil attach -nobrowse -readonly -mountpoint "$mount_directory" "$dmg"
fork_verify_app "$mount_directory/$FORK_APP_NAME.app"
xcrun stapler validate "$mount_directory/$FORK_APP_NAME.app"
spctl --assess --type execute "$mount_directory/$FORK_APP_NAME.app"

bundle="${RUNNER_TEMP:?RUNNER_TEMP is required}/shadow-release-bundle"
mkdir -p "$bundle"
cp "$dmg" "$bundle/"
{
    printf '# Shadow Utilities %s\n\n' "$version"
    printf 'Personal fork of Vorssaint with T-Mobile gateway support. Requires macOS 14 or later on Apple silicon.\n\n'
    printf 'Source commit: `%s`. Bundle: `%s`.\n\n' "$(git rev-parse HEAD)" "$FORK_BUNDLE_ID"
    printf 'Signed with the fork owner’s Developer ID and notarized by Apple. Open the DMG and drag Shadow Utilities to Applications.\n\n'
    printf 'Review and complete these notes, install the DMG for a smoke test, and manually publish this draft when ready.\n'
} > "$bundle/release-notes.md"
(
    cd "$bundle"
    shasum -a 256 "ShadowUtilities-$version.dmg" release-notes.md > SHA256SUMS
)
