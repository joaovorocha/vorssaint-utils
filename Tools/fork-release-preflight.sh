#!/bin/zsh
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Vorssaint

set -euo pipefail
cd "$(dirname "$0")/.."
source Tools/fork-common.sh
fork_require_repository
tag="${FORK_RELEASE_TAG:-}"
[[ "$tag" == v* ]] && fork_validate_version "${tag#v}" \
    || { echo 'Unsupported fork release tag.' >&2; exit 1; }
# This verifier first runs from the trusted dispatch commit on main. Resolve
# and inspect tag contents without executing any code from the selected tag.
commit_sha="$(git rev-parse "refs/tags/$tag^{commit}")"
remote_sha="$(gh api "repos/$FORK_REPOSITORY/commits/$tag" --jq '.sha')"
[[ "$commit_sha" == "$remote_sha" ]] || { echo 'Release tag moved after checkout.' >&2; exit 1; }
relation="$(gh api "repos/$FORK_REPOSITORY/compare/$commit_sha...main" --jq '.status + ":" + .merge_base_commit.sha')"
[[ "$relation" == "identical:$commit_sha" || "$relation" == "ahead:$commit_sha" ]] \
    || { echo 'Release tag must point to a commit already reviewed onto main.' >&2; exit 1; }
version="$(git show "$commit_sha:Resources/Fork/version.txt")"
fork_validate_version "$version" && [[ "$tag" == "v$version" ]] \
    || { echo 'Release tag must match its Resources/Fork/version.txt.' >&2; exit 1; }
if [[ -n "${FORK_RELEASE_COMMIT:-}" ]]; then
    [[ "$commit_sha" == "$FORK_RELEASE_COMMIT" && "$(git rev-parse 'HEAD^{commit}')" == "$commit_sha" ]] \
        || { echo 'Release commit changed after preflight.' >&2; exit 1; }
fi
if [[ -n "${GITHUB_OUTPUT:-}" ]]; then printf 'commit_sha=%s\n' "$commit_sha" >> "$GITHUB_OUTPUT"; fi
echo 'Fork release source verified.'
