#!/bin/zsh
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Vorssaint
set -euo pipefail
cd "$(dirname "$0")/.."
task_temp="$(mktemp -d /private/tmp/tmobile-wifi-tests.XXXXXX)"
trap 'rm -rf "$task_temp"' EXIT
task_sdk="$(xcrun --show-sdk-path)"
swiftc -Onone -sdk "$task_sdk" -module-cache-path "$task_temp/module-cache" \
    Sources/Vorssaint/Services/Metrics/TMobileGatewaySupport.swift \
    Sources/Vorssaint/Services/Metrics/TMobileWiFiSupport.swift \
    Sources/Vorssaint/Services/Metrics/TMobileWiFiService.swift \
    Tests/TMobileWiFiTests.swift Tests/Fixtures/TMobileWiFiServiceHarness.swift \
    -o "$task_temp/tests"
"$task_temp/tests"
