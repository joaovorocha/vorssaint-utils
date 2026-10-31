#!/bin/zsh
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Vorssaint
set -euo pipefail
cd "$(dirname "$0")/.."
task_temp="$(mktemp -d /private/tmp/tmobile-opencellid-tests.XXXXXX)"
trap 'rm -rf "$task_temp"' EXIT
task_sdk="$(xcrun --sdk macosx --show-sdk-path)"
xcrun --sdk macosx swiftc -Onone -j 1 -disable-batch-mode -sdk "$task_sdk" -module-cache-path "$task_temp/ModuleCache" \
    Sources/Vorssaint/Services/Metrics/TMobileOpenCellIDSupport.swift \
    Sources/Vorssaint/Services/Metrics/TMobileOpenCellIDAreaSupport.swift \
    Sources/Vorssaint/Services/Metrics/TMobileOpenCellIDService.swift \
    Tests/TMobileOpenCellIDTests.swift Tests/Fixtures/TMobileOpenCellIDServiceHarness.swift \
    -o "$task_temp/tests"
"$task_temp/tests"
