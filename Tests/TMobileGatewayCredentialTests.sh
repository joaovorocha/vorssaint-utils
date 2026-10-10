#!/bin/zsh
# SPDX-License-Identifier: GPL-3.0-or-later
set -euo pipefail
cd "$(dirname "$0")/.."
task_temp="$(mktemp -d /private/tmp/tmobile-credential-tests.XXXXXX)"
trap 'rm -rf "$task_temp"' EXIT
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
task_sdk="$(xcrun --show-sdk-path)"
xcrun swiftc -j 1 -disable-batch-mode -Onone -sdk "$task_sdk" -module-cache-path "$task_temp/module-cache" \
    Sources/Vorssaint/Support/ScopedCredentialStore.swift \
    Sources/Vorssaint/Services/Metrics/TMobileGatewaySupport.swift \
    Sources/Vorssaint/Services/Metrics/TMobileGatewayCredentials.swift \
    Tests/Fixtures/TMobileGatewayCredentialHarness.swift \
    -o "$task_temp/tests"
"$task_temp/tests"
