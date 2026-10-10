#!/bin/zsh
# SPDX-License-Identifier: GPL-3.0-or-later
set -euo pipefail
cd "$(dirname "$0")/.."
task_temp="$(mktemp -d /private/tmp/tmobile-fcc-workflow.XXXXXX)"
trap 'rm -rf "$task_temp"' EXIT
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
task_sdk="$(xcrun --sdk macosx --show-sdk-path)"
xcrun --sdk macosx swiftc -j 1 -disable-batch-mode -Onone -D SHADOW_UTILITIES \
    -sdk "$task_sdk" -module-cache-path "$task_temp/module-cache" \
    Sources/Vorssaint/Support/ScopedCredentialStore.swift \
    Sources/Vorssaint/Services/Metrics/FCCCoverageSupport.swift \
    Sources/Vorssaint/Services/Metrics/TMobileFCCCredentials.swift \
    Sources/Vorssaint/Services/Metrics/TMobileFCCReferenceSource.swift \
    Sources/Vorssaint/Services/Metrics/TMobileCoverageReferenceSupport.swift \
    Tests/Fixtures/TMobileFCCWorkflowHarness.swift -o "$task_temp/tests"
"$task_temp/tests"
