#!/bin/zsh
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Vorssaint
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
task_temp="$(mktemp -d /private/tmp/tmobile-tower-map-tests.XXXXXX)"
trap 'rm -rf "$task_temp"' EXIT

# Read real model declarations without compiling the archive, app, or gateway
# service. No fixture copy can silently drift from the production model.
python3 - "$task_temp/Models.swift" <<'PY'
from pathlib import Path
import importlib.util
import sys
spec = importlib.util.spec_from_file_location("generator", "Tests/generate_sources.py")
generator = importlib.util.module_from_spec(spec)
spec.loader.exec_module(generator)
source = "Sources/Vorssaint/Services/Metrics/TMobileGatewayHistorySupport.swift"
Path(sys.argv[1]).write_text("import Foundation\n" + generator.declaration(source, "struct TMobileMapCoordinate:")
                           + generator.declaration(source, "struct TMobileTowerPin:"))
PY

task_sdk="$(xcrun --sdk macosx --show-sdk-path)"
xcrun --sdk macosx swiftc -j1 -disable-batch-mode -parse-as-library -Onone -sdk "$task_sdk" \
    -target "$(uname -m)-apple-macosx14.0" -module-cache-path "$task_temp/ModuleCache" \
    "$task_temp/Models.swift" \
    Sources/Vorssaint/Services/Metrics/TMobileTowerReferenceSupport.swift \
    Sources/Vorssaint/Services/Metrics/TMobileBandGuide.swift \
    Sources/Vorssaint/Services/Metrics/TMobileTowerMapPresentation.swift \
    Sources/Vorssaint/UI/MenuPanel/TMobileTowerMapInspector.swift \
    Tests/Fixtures/TMobileTowerMapPresentationHarness.swift -o "$task_temp/tests"
"$task_temp/tests"
