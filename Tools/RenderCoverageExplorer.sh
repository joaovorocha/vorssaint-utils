#!/bin/zsh
# SPDX-License-Identifier: GPL-3.0-or-later
set -euo pipefail
task_tool_root="$(cd "$(dirname "$0")/.." && pwd)"
task_source_root="${COVERAGE_SOURCE_ROOT:-$task_tool_root}"
if [[ "$#" -ne 1 ]]; then
    print -u2 'Usage: RenderCoverageExplorer.sh OUTPUT_DIRECTORY'
    exit 2
fi
task_temp="$(mktemp -d /private/tmp/shadow-explorer-render-build.XXXXXX)"
trap 'rm -rf "$task_temp"' EXIT
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
task_sdk="$(xcrun --sdk macosx --show-sdk-path)"
task_metrics="$task_source_root/Sources/Vorssaint/Services/Metrics"
task_views="$task_source_root/Sources/Vorssaint/UI/MenuPanel"
# Compile only pure models and the actual Explorer/map/inspector. No live-store,
# application lifecycle, preferences, credentials or network client is linked.
xcrun --sdk macosx swiftc -Onone -j 1 -disable-batch-mode \
    -target "$(uname -m)-apple-macosx14.0" -sdk "$task_sdk" \
    -module-cache-path "$task_temp/ModuleCache" \
    "$task_metrics/TMobileGatewaySupport.swift" \
    "$task_metrics/TMobileGatewayConnectedRadioSupport.swift" \
    "$task_metrics/TMobileGatewayHistorySupport.swift" \
    "$task_metrics/TMobileTowerReferenceSupport.swift" \
    "$task_metrics/TMobileGatewayDiagnostics.swift" \
    "$task_metrics/TMobileCoverageSupport.swift" \
    "$task_metrics/TMobileBandGuide.swift" \
    "$task_metrics/TMobileTowerMapPresentation.swift" \
    "$task_views/TMobileTowerMapInspector.swift" \
    "$task_views/TMobileCoverageMapView.swift" \
    "$task_views/TMobileCoverageExplorerView.swift" \
    "$task_tool_root/Tools/RenderCoverageExplorer.swift" \
    -o "$task_temp/render-explorer"
"$task_temp/render-explorer" "$1"
