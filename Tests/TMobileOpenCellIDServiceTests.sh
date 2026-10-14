#!/bin/zsh
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Vorssaint
set -euo pipefail
cd "$(dirname "$0")/.."
task_temp="$(mktemp -d /private/tmp/tmobile-opencellid-tests.XXXXXX)"
trap 'rm -rf "$task_temp"' EXIT
task_sdk="$(xcrun --show-sdk-path)"
task_compat=()
if [[ -d /Library/Developer/CommandLineTools/SDKs/MacOSX26.sdk ]]; then
    task_sdk=/Library/Developer/CommandLineTools/SDKs/MacOSX26.sdk
    task_compat=(-Xfrontend -interface-compiler-version -Xfrontend 6.3.2)
fi
swiftc -Onone -sdk "$task_sdk" "${task_compat[@]}" \
    Sources/Vorssaint/Services/Metrics/TMobileOpenCellIDSupport.swift \
    Sources/Vorssaint/Services/Metrics/TMobileOpenCellIDService.swift \
    Tests/TMobileOpenCellIDTests.swift Tests/Fixtures/TMobileOpenCellIDServiceHarness.swift \
    -o "$task_temp/tests"
"$task_temp/tests"
