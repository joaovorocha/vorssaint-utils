#!/bin/bash
set -euo pipefail
task_root="$(cd "$(dirname "$0")/.." && pwd)"
task_temp="$(mktemp -d "${TMPDIR:-/tmp}/tmobile-coverage-map-tests.XXXXXX")"
trap 'rm -rf "$task_temp"' EXIT
awk '/^enum TestHarnessTests/ { exit } { print }' "$task_root/Tests/TestSuite.swift" > "$task_temp/TestSuite.swift"
cat > "$task_temp/main.swift" <<'SWIFT'
import Foundation
@main struct CoverageMapChartTestMain {
    static func main() {
        let suite = TestSuite()
        suite.run("Coverage map and charts") { TMobileCoverageMapChartsTests.run(suite) }
        suite.finish()
    }
}
SWIFT
swiftc -parse-as-library -Onone -target "$(uname -m)-apple-macosx14.0" \
    -module-cache-path "${TMOBILE_COVERAGE_TEST_MODULE_CACHE:-$task_temp/module-cache}" \
    "$task_root/Sources/Vorssaint/Services/Metrics/TMobileGatewaySupport.swift" \
    "$task_root/Sources/Vorssaint/Services/Metrics/TMobileGatewayConnectedRadioSupport.swift" \
    "$task_root/Sources/Vorssaint/Services/Metrics/TMobileGatewayHistorySupport.swift" \
    "$task_root/Sources/Vorssaint/Services/Metrics/TMobileTowerReferenceSupport.swift" \
    "$task_root/Sources/Vorssaint/Services/Metrics/TMobileGatewayDiagnostics.swift" \
    "$task_root/Sources/Vorssaint/Services/Metrics/TMobileCoverageSupport.swift" \
    "$task_root/Sources/Vorssaint/UI/MenuPanel/TMobileCoverageMapView.swift" \
    "$task_root/Sources/Vorssaint/UI/MenuPanel/TMobileCoverageChartsView.swift" \
    "$task_temp/TestSuite.swift" "$task_root/Tests/TMobileCoverageMapChartsTests.swift" \
    "$task_temp/main.swift" -o "$task_temp/tests"
"$task_temp/tests"
