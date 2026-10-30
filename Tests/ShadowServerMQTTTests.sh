#!/bin/zsh
# SPDX-License-Identifier: GPL-3.0-or-later
set -euo pipefail
cd "$(dirname "$0")/.."
task_temp="$(mktemp -d /private/tmp/shadow-server-mqtt-tests.XXXXXX)"
trap 'rm -rf "$task_temp"' EXIT
task_sdk="$(xcrun --sdk macosx --show-sdk-path)"
xcrun --sdk macosx swiftc -Onone -j 1 -sdk "$task_sdk" -module-cache-path "$task_temp/ModuleCache" \
    Sources/Vorssaint/Services/Metrics/ShadowServerMQTTSupport.swift \
    Tests/Fixtures/ShadowServerMQTTHarness.swift \
    -o "$task_temp/tests"
"$task_temp/tests"
