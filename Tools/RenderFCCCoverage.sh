#!/bin/zsh
# SPDX-License-Identifier: GPL-3.0-or-later
set -euo pipefail
cd "$(dirname "$0")/.."
task_temp="$(mktemp -d /private/tmp/shadow-fcc-render-build.XXXXXX)"
trap 'rm -rf "$task_temp"' EXIT
# Take the real coordinate declaration without pulling in the history recorder.
python3 - "$task_temp/Coordinate.swift" <<'PY'
from pathlib import Path
import sys
text = Path('Sources/Vorssaint/Services/Metrics/TMobileGatewayHistorySupport.swift').read_text()
start = text.index('struct TMobileMapCoordinate:')
end = text.index('\nstruct ', start + 1)
Path(sys.argv[1]).write_text('import Foundation\n' + text[start:end])
PY
/usr/bin/xcrun --sdk macosx swiftc -j 1 -disable-batch-mode -D SHADOW_UTILITIES \
    -target arm64-apple-macosx14.0 -module-cache-path "$task_temp/ModuleCache" \
    "$task_temp/Coordinate.swift" Sources/Vorssaint/Support/ScopedCredentialStore.swift \
    Sources/Vorssaint/Services/Metrics/{FCCCoverageSupport,FCCCoverageClient,TMobileFCCDownloadCache,TMobileFCCCoverageModel,TMobileFCCArchiveSupport,TMobileFCCGeoPackageSupport,TMobileFCCCredentials,TMobileFCCReferenceSource,TMobileCoverageReferenceSupport}.swift \
    Sources/Vorssaint/UI/MenuPanel/TMobileFCCCoverageView.swift Tools/RenderFCCCoverage.swift \
    -lz -lsqlite3 -o "$task_temp/render-fcc"
"$task_temp/render-fcc" "$@"
