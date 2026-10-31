#!/bin/zsh
# SPDX-License-Identifier: GPL-3.0-or-later
set -euo pipefail
cd "$(dirname "$0")/.."
task_source="${FCC_SOURCE_ROOT:-$PWD}"
task_temp="$(mktemp -d /private/tmp/tmobile-fcc-automatic-tests.XXXXXX)"
trap 'rm -rf "$task_temp"' EXIT
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
# Use the production coordinate declaration without unrelated radio/store code.
python3 - "$task_source" "$task_temp/Coordinate.swift" <<'PY'
import pathlib, sys
source = (pathlib.Path(sys.argv[1]) / 'Sources/Vorssaint/Services/Metrics/TMobileGatewayHistorySupport.swift').read_text()
start = source.index('struct TMobileMapCoordinate:')
end = source.index('\nstruct ', start + 1)
pathlib.Path(sys.argv[2]).write_text('import Foundation\n' + source[start:end] + '\n')
PY
task_metrics="$task_source/Sources/Vorssaint/Services/Metrics"
task_sdk="$(xcrun --sdk macosx --show-sdk-path)"
xcrun --sdk macosx swiftc -Onone -j 1 -disable-batch-mode -D SHADOW_UTILITIES \
    -sdk "$task_sdk" -module-cache-path "$task_temp/module-cache" \
    "$task_temp/Coordinate.swift" \
    "$task_source/Sources/Vorssaint/Support/ScopedCredentialStore.swift" \
    "$task_metrics/FCCCoverageSupport.swift" "$task_metrics/FCCCoverageClient.swift" \
    "$task_metrics/TMobileFCCCredentials.swift" "$task_metrics/TMobileFCCReferenceSource.swift" \
    "$task_metrics/TMobileCoverageReferenceSupport.swift" "$task_metrics/TMobileFCCArchiveSupport.swift" \
    "$task_metrics/TMobileFCCGeoPackageSupport.swift" "$task_metrics/TMobileFCCDownloadCache.swift" \
    "$task_metrics/TMobileFCCCoverageModel.swift" \
    Tests/Fixtures/TMobileFCCAutomaticLoadHarness.swift -lsqlite3 -lz -o "$task_temp/tests"
"$task_temp/tests"
