#!/bin/zsh
# SPDX-License-Identifier: GPL-3.0-or-later
set -euo pipefail
cd "$(dirname "$0")/.."
task_temp="$(mktemp -d /private/tmp/tmobile-coverage-tests.XXXXXX)"
trap 'rm -rf "$task_temp"' EXIT
task_sdk="$(xcrun --show-sdk-path)"
task_cache="${TMOBILE_COVERAGE_MODULE_CACHE:-$task_temp/module-cache}"
swiftc -Onone -target "$(uname -m)-apple-macosx14.0" -sdk "$task_sdk" -module-cache-path "$task_cache" \
    Sources/Vorssaint/Services/Metrics/TMobileGatewaySupport.swift \
    Sources/Vorssaint/Services/Metrics/TMobileGatewayConnectedRadioSupport.swift \
    Sources/Vorssaint/Services/Metrics/TMobileGatewayHistorySupport.swift \
    Sources/Vorssaint/Services/Metrics/TMobileTowerReferenceSupport.swift \
    Sources/Vorssaint/Services/Metrics/TMobileCoverageSupport.swift \
    Sources/Vorssaint/Services/Metrics/TMobileCoverageStore.swift \
    Tests/Fixtures/TMobileCoverageStoreHarness.swift -o "$task_temp/tests"
"$task_temp/tests"
