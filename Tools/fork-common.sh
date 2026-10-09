#!/bin/zsh
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Vorssaint

# Shared identity checks for the personal fork; the upstream identity is untouched.
FORK_REPOSITORY='joaovorocha/vorssaint-utils'
FORK_APP_NAME='Shadow Utilities'
FORK_BUNDLE_ID='io.github.joaovorocha.shadowutils'

fork_require_repository() {
    if [[ "${GITHUB_REPOSITORY:-}" != "$FORK_REPOSITORY" ]]; then
        echo 'This operation is limited to the personal fork repository.' >&2
        return 1
    fi
}

fork_require_team() {
    if [[ ! "${SHADOW_UPDATE_TEAM_ID:-}" =~ '^[A-Z0-9]{10}$' || "${SHADOW_UPDATE_TEAM_ID:-}" == '3D485NHW29' ]]; then
        echo 'Set SHADOW_UPDATE_TEAM_ID to your own 10-character Apple Team ID.' >&2
        return 1
    fi
}

fork_validate_version() {
    [[ "$1" =~ '^[0-9]+\.[0-9]+\.[0-9]+(-(alpha|beta|rc)\.[0-9]+)?$' ]]
}

fork_version() {
    local version
    version="$(cat Resources/Fork/version.txt)"
    if ! fork_validate_version "$version"; then
        echo 'Resources/Fork/version.txt has an unsupported version.' >&2
        return 1
    fi
    printf '%s\n' "$version"
}

fork_verify_app() {
    local app="$1" bundle_id embedded_team
    fork_require_team || return
    bundle_id="$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$app/Contents/Info.plist")"
    embedded_team="$(/usr/libexec/PlistBuddy -c 'Print ShadowUpdateTeamID' "$app/Contents/Info.plist")"
    if [[ "$bundle_id" != "$FORK_BUNDLE_ID" || "$embedded_team" != "$SHADOW_UPDATE_TEAM_ID" ]]; then
        echo 'Fork bundle identifier or embedded update Team pin does not match.' >&2
        return 1
    fi
    codesign --verify --deep --strict \
        -R="identifier \"$FORK_BUNDLE_ID\" and anchor apple generic and certificate leaf[subject.OU] = \"$SHADOW_UPDATE_TEAM_ID\"" "$app"
}
