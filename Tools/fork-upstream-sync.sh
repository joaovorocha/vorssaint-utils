#!/bin/zsh
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Vorssaint

# Propose source changes on a new branch. Never updates main or merges a PR.
set -euo pipefail
cd "$(dirname "$0")/.."
source Tools/fork-common.sh
fork_require_repository
[[ "${GITHUB_ACTIONS:-}" == 'true' ]] || { echo 'Run this from the upstream-sync workflow.' >&2; exit 1; }
[[ -z "$(git status --porcelain)" ]] || { echo 'A clean checkout is required.' >&2; exit 1; }
origin_url="$(git remote get-url origin)"
[[ "$origin_url" == "https://github.com/$FORK_REPOSITORY" || "$origin_url" == "https://github.com/$FORK_REPOSITORY.git" ]] \
    || { echo 'Unexpected origin repository.' >&2; exit 1; }

git fetch --no-tags origin main
git fetch --no-tags https://github.com/vorssaint/vorssaint-utils.git main
upstream_sha="$(git rev-parse 'FETCH_HEAD^{commit}')"
if git merge-base --is-ancestor "$upstream_sha" origin/main; then
    echo 'The fork already contains the latest upstream main.'
    exit 0
fi
proposal_branch="codex/upstream-sync-${upstream_sha[1,12]}"
existing_pr="$(gh pr list --repo "$FORK_REPOSITORY" --state open --base main --head "$proposal_branch" --json url --jq '.[0].url // empty')"
if [[ -n "$existing_pr" ]]; then
    echo "Existing review PR: $existing_pr"
    exit 0
fi

body_file="$(mktemp)"
trap 'rm -f "$body_file"' EXIT
attention() {
    local reason="$1" existing_issue
    existing_issue="$(gh issue list --repo "$FORK_REPOSITORY" --state open --search "${upstream_sha[1,12]} in:title" --json number --jq '.[0].number // empty')"
    if [[ -z "$existing_issue" ]]; then
        {
            printf 'Upstream source update `%s` requires human review.\n\n' "$upstream_sha"
            printf '%s\n\n' "$reason"
            printf 'Resolve on a separate branch, run Fork CI, and open a review PR. Main was not updated.\n'
            printf '\nWorkflow: https://github.com/%s/actions/runs/%s\n' "$FORK_REPOSITORY" "$GITHUB_RUN_ID"
        } > "$body_file"
        gh issue create --repo "$FORK_REPOSITORY" --title "Upstream sync requires review (${upstream_sha[1,12]})" --body-file "$body_file"
    else
        echo "Existing attention issue: #$existing_issue"
    fi
}

if [[ -n "$(git ls-remote --heads origin "refs/heads/$proposal_branch")" ]]; then
    attention 'A proposal branch already exists without an open PR. It was preserved; no force push was attempted.'
    exit 1
fi
git switch --create "$proposal_branch" origin/main
git config user.name 'github-actions[bot]'
git config user.email '41898282+github-actions[bot]@users.noreply.github.com'
if ! git -c commit.gpgsign=false merge --no-ff --no-edit "$upstream_sha"; then
    conflicted_files="$(git diff --name-only --diff-filter=U)"
    git merge --abort
    attention "The upstream merge conflicted in these paths:

$conflicted_files"
    exit 1
fi
gh auth setup-git
if ! git push origin "HEAD:refs/heads/$proposal_branch"; then
    attention 'GitHub refused publishing the proposal branch. Check repository policy and workflow-file token restrictions; the owner can push the reviewed branch manually. No permissions were widened.'
    exit 1
fi
{
    printf 'Merge upstream main `%s` into the personal fork.\n\n' "$upstream_sha"
    printf 'Review the entire diff, including workflow and signing changes. Approve the waiting CI workflows in this PR; if needed, manually run Fork CI on this branch before merging.\n\n'
    printf 'Preserve the T-Mobile gateway feature, Shadow Utilities identity, independent fork version, and fork update trust pins.\n\n'
    printf 'This proposes source changes only. It does not build, sign, publish, or install an app update.\n'
} > "$body_file"
gh pr create --repo "$FORK_REPOSITORY" --base main --head "$proposal_branch" \
    --title "Review upstream update ${upstream_sha[1,12]}" --body-file "$body_file"
