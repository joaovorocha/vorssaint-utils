#!/bin/zsh
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Vorssaint

set -euo pipefail
cd "$(dirname "$0")/.."
source Tools/fork-common.sh
fork_require_repository
version="$(fork_version)"
tag="${FORK_RELEASE_TAG:-}"
[[ "$tag" == "v$version" ]] || { echo 'Fork release version mismatch.' >&2; exit 1; }
commit_sha="${FORK_RELEASE_COMMIT:-}"
[[ "$commit_sha" =~ '^[a-f0-9]{40}$' ]] || { echo 'Missing immutable release commit.' >&2; exit 1; }
remote_sha="$(gh api "repos/$FORK_REPOSITORY/commits/$tag" --jq '.sha')"
[[ "$remote_sha" == "$commit_sha" && "$(git rev-parse HEAD)" == "$commit_sha" ]] \
    || { echo 'Release source changed after signing.' >&2; exit 1; }
bundle="${RUNNER_TEMP:?RUNNER_TEMP is required}/shadow-release-bundle"
(
    cd "$bundle"
    shasum -a 256 -c SHA256SUMS
)
if gh release view "$tag" --repo "$FORK_REPOSITORY" >/dev/null 2>&1; then
    echo 'A release or draft already exists. It was preserved; review it manually.' >&2
    exit 1
fi
release_arguments=("$tag" "$bundle/ShadowUtilities-$version.dmg" "$bundle/SHA256SUMS"
                   --repo "$FORK_REPOSITORY" --verify-tag --draft
                   --title "$FORK_APP_NAME $version" --notes-file "$bundle/release-notes.md")
if [[ "$version" == *-* ]]; then release_arguments+=(--prerelease); fi
gh release create "${release_arguments[@]}"
[[ "$(gh release view "$tag" --repo "$FORK_REPOSITORY" --json isDraft --jq '.isDraft')" == 'true' ]] \
    || { echo 'Expected a draft release.' >&2; exit 1; }
echo 'Draft created. Publication requires the owner to review and publish it manually.'
