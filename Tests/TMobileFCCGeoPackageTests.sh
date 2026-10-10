#!/bin/zsh
# SPDX-License-Identifier: GPL-3.0-or-later
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
task_temp="$(mktemp -d /private/tmp/tmobile-fcc-geopackage-tests.XXXXXX)"
trap 'rm -rf "$task_temp"' EXIT
# Compile the actual existing importer/model declarations, excluding the store and Combine.
# This verifies compatibility without touching app preferences or archived references.
python3 - "$task_temp/ReferenceParser.swift" <<'PY'
import pathlib, sys
metrics = pathlib.Path('Sources/Vorssaint/Services/Metrics')
coordinate = (metrics / 'TMobileGatewayHistorySupport.swift').read_text()
coordinate = coordinate[coordinate.index('struct TMobileMapCoordinate:'):coordinate.index('\nstruct ', coordinate.index('struct TMobileMapCoordinate:') + 1)]
reference = (metrics / 'TMobileCoverageReferenceSupport.swift').read_text()
reference = reference[reference.index('struct TMobileCoverageFCCLayer:'):reference.index('@MainActor final class TMobileCoverageReferenceStore')]
provenance = ''
if 'TMobileFCCReferenceSource' in reference:
    states = (metrics / 'FCCCoverageSupport.swift').read_text()
    start = states.index('struct FCCCoverageState:')
    provenance = states[start:states.index('\n}', start) + 2] + '\n' + (metrics / 'TMobileFCCReferenceSource.swift').read_text()
pathlib.Path(sys.argv[1]).write_text('import Foundation\nimport CoreFoundation\nimport Darwin\n' + coordinate + '\n' + provenance + '\n' + reference)
PY
task_sdk="$(xcrun --sdk macosx --show-sdk-path)"
xcrun --sdk macosx swiftc -Onone -j 1 -disable-batch-mode -sdk "$task_sdk" -module-cache-path "$task_temp/ModuleCache" \
    Sources/Vorssaint/Services/Metrics/TMobileFCCGeoPackageSupport.swift \
    "$task_temp/ReferenceParser.swift" Tests/Fixtures/TMobileFCCGeoPackageHarness.swift \
    -lsqlite3 -o "$task_temp/tests"
"$task_temp/tests" "$@"
