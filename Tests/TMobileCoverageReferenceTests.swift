// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

enum TMobileCoverageReferenceTests {
    static func run(_ suite: TestSuite) {
        let fixture = #"{"type":"FeatureCollection","features":[{"type":"Feature","properties":{"unused":"excluded-marker"},"geometry":{"type":"Polygon","coordinates":[[[-100,40],[-99,40],[-99,41],[-100,40]]]}}]}"#
        let parsed = try? TMobileCoverageReferenceSupport.parse(Data(fixture.utf8), publishedDate: "2026-10-01")
        suite.expect(parsed?.polygons.count == 1 && parsed?.polygons.first?.first?.count == 4,
                     "bounded Polygon GeoJSON imports as a dated separate reference")
        suite.expect(parsed?.polygons.first?.first?.first == TMobileMapCoordinate(latitude: 40, longitude: -100),
                     "GeoJSON longitude/latitude order converts without swapping coordinates")
        let encoded = parsed.flatMap { try? JSONEncoder().encode($0) }.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        suite.expect(!encoded.contains("excluded-marker") && !encoded.contains("properties"),
                     "reference archive retains geometry and provenance without arbitrary source properties")
        for date in ["", "2026-2-01", "2026-02-30", "2025-02-29", "2026-13-01", "2026-10-01 "] {
            suite.expect(!TMobileCoverageReferenceSupport.validDate(date), "invalid publication dates are rejected")
        }
        suite.expect(TMobileCoverageReferenceSupport.validDate("2024-02-29"), "real leap-day publication dates are accepted")
        for invalid in ["{}", #"{"type":"FeatureCollection","features":[]}"#,
                        fixture.replacingOccurrences(of: "Polygon", with: "LineString"),
                        fixture.replacingOccurrences(of: "[-100,40]", with: "[-100,91]"),
                        fixture.replacingOccurrences(of: "[-100,40]", with: "[false,40]"),
                        fixture.replacingOccurrences(of: "[-100,40]]]", with: "[-98,40]]]"),
                        fixture.replacingOccurrences(of: "[-99,40],[-99,41]", with: "[-100,40],[-100,40]")] {
            suite.expect((try? TMobileCoverageReferenceSupport.parse(Data(invalid.utf8), publishedDate: "2026-10-01")) == nil,
                         "malformed, non-polygon, boolean, out-of-range and unclosed/degenerate geometry fails closed")
        }
        suite.expect((try? TMobileCoverageReferenceSupport.parse(Data(repeating: 32, count: 5_000_001), publishedDate: "2026-10-01")) == nil,
                     "oversized reference files are rejected before JSON decoding")
        let multi = #"{"type":"FeatureCollection","features":[{"type":"Feature","geometry":{"type":"MultiPolygon","coordinates":[[[[-100,40],[-99,40],[-99,41],[-100,40]]],[[[-98,40],[-97,40],[-97,41],[-98,40]]]]}}]}"#
        suite.expect((try? TMobileCoverageReferenceSupport.parse(Data(multi.utf8), publishedDate: "2026-10-01"))?.polygons.count == 2,
                     "MultiPolygon imports keep distinct polygon components")
    }
}
