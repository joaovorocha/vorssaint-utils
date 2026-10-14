#!/bin/zsh
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Vorssaint

# A plain fork-branded drag-to-Applications image. The official styled DMG stays unchanged.
set -euo pipefail
cd "$(dirname "$0")/.."
source Tools/fork-common.sh
fork_require_team
version="$(fork_version)"
app="build/stage/$FORK_APP_NAME.app"
fork_verify_app "$app"
app_version="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$app/Contents/Info.plist")"
[[ "$app_version" == "$version" ]] || { echo 'Built fork version does not match the release version.' >&2; exit 1; }
identity="$(security find-identity -v -p codesigning | awk -v team="($SHADOW_UPDATE_TEAM_ID)" '/Developer ID Application:/ && index($0, team) {print $2; exit}')"
[[ -n "$identity" ]] || { echo 'No Developer ID Application certificate matches the fork Team pin.' >&2; exit 1; }

staging="$(mktemp -d)"
trap 'rm -rf "$staging"' EXIT
ditto --noextattr --noqtn "$app" "$staging/$FORK_APP_NAME.app"
fork_verify_app "$staging/$FORK_APP_NAME.app"
ln -s /Applications "$staging/Applications"
mkdir -p dist
output="dist/ShadowUtilities-$version.dmg"
hdiutil create -volname "$FORK_APP_NAME" -srcfolder "$staging" -fs HFS+ -format UDZO -ov "$output"
codesign --force --timestamp --sign "$identity" "$output"
codesign --verify --strict \
    -R="anchor apple generic and certificate leaf[subject.OU] = \"$SHADOW_UPDATE_TEAM_ID\"" "$output"
echo "Fork DMG ready: $output"
