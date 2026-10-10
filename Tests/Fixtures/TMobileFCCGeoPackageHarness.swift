// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import SQLite3

private typealias FCC = TMobileFCCGeoPackageSupport
private typealias Ring = [[Double]]

private final class Suite {
    var checks = 0
    var failures = 0
    func expect(_ condition: @autoclosure () -> Bool, _ label: String) {
        checks += 1
        if !condition() { failures += 1; print("FAIL: \(label)") }
    }
    func fails(_ expected: FCC.Failure? = nil, _ label: String, _ action: () throws -> Void) {
        do { try action(); expect(false, label) }
        catch { expect(expected == nil || error as? FCC.Failure == expected, "\(label): \(error.localizedDescription)") }
    }
}

private func u32(_ value: UInt32, little: Bool = true) -> [UInt8] {
    (0..<4).map { UInt8(truncatingIfNeeded: value >> UInt32((little ? $0 : 3 - $0) * 8)) }
}
private func f64(_ value: Double, little: Bool = true) -> [UInt8] {
    (0..<8).map { UInt8(truncatingIfNeeded: value.bitPattern >> UInt64((little ? $0 : 7 - $0) * 8)) }
}
private func polygon(_ rings: [Ring], little: Bool = true) -> [UInt8] {
    [little ? 1 : 0] + u32(3, little: little) + u32(UInt32(rings.count), little: little)
        + rings.flatMap { ring in u32(UInt32(ring.count), little: little) + ring.flatMap { f64($0[0], little: little) + f64($0[1], little: little) } }
}
private func geometry(_ polygons: [[Ring]], multi: Bool = false, headerLittle: Bool = true,
                      wkbLittle: Bool = true, envelope: FCC.Bounds? = nil) -> Data {
    var bytes: [UInt8] = [0x47, 0x50, 0, (headerLittle ? 1 : 0) + (envelope == nil ? 0 : 2)]
    bytes += u32(4326, little: headerLittle)
    if let envelope {
        for value in [envelope.west, envelope.east, envelope.south, envelope.north] { bytes += f64(value, little: headerLittle) }
    }
    if multi {
        bytes += [wkbLittle ? 1 : 0] + u32(6, little: wkbLittle) + u32(UInt32(polygons.count), little: wkbLittle)
        for (i, rings) in polygons.enumerated() { bytes += polygon(rings, little: i.isMultiple(of: 2) ? wkbLittle : !wkbLittle) }
    } else { bytes += polygon(polygons[0], little: wkbLittle) }
    return Data(bytes)
}

/// Only this type writes SQLite, always a fresh file under the harness's temporary directory.
private final class SyntheticDatabase {
    let url: URL
    private var db: OpaquePointer?
    let layer: String
    let hasSignalColumn: Bool
    init(folder: URL, layer: String = "fcc_raw", type: String = "POLYGON", index: Bool = true,
         signalColumn: Bool = true) throws {
        url = folder.appendingPathComponent(UUID().uuidString + ".gpkg")
        self.layer = layer
        hasSignalColumn = signalColumn
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK else { throw FCC.Failure.cannotRead }
        try execute("""
            PRAGMA application_id=1196444487;
            CREATE TABLE gpkg_contents(table_name TEXT PRIMARY KEY,data_type TEXT,srs_id INTEGER);
            CREATE TABLE gpkg_geometry_columns(table_name TEXT,column_name TEXT,geometry_type_name TEXT,srs_id INTEGER,z INTEGER,m INTEGER);
            CREATE TABLE "\(layer)"(fid INTEGER PRIMARY KEY,geom BLOB,frn TEXT,providerid INTEGER,brandname TEXT,
                technology INTEGER,mindown REAL,minup REAL,\(signalColumn ? "minsignal INTEGER," : "")environmnt INTEGER);
            INSERT INTO gpkg_contents VALUES('\(layer)','features',4326);
            INSERT INTO gpkg_geometry_columns VALUES('\(layer)','geom','\(type)',4326,0,0);
            """)
        if index { try execute("CREATE VIRTUAL TABLE \"rtree_\(layer)_geom\" USING rtree(id,minx,maxx,miny,maxy)") }
    }
    deinit { if let db { sqlite3_close(db) } }
    func execute(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw FCC.Failure.cannotRead }
    }
    func add(_ bytes: Data, id: Int = 1, bounds: FCC.Bounds = .init(west: 0, south: 0, east: 10, north: 10),
             environment: Int = 0, provider: Int = 130403, brand: String = "T-Mobile", technology: Int = 500,
             download: Double = 35, upload: Double = 3, index: Bool = true, signal: Double? = -110) throws {
        var statement: OpaquePointer?
        let query = "INSERT INTO \"\(layer)\"(fid,geom,frn,providerid,brandname,technology,mindown,minup,environmnt\(hasSignalColumn ? ",minsignal" : "")) VALUES(?1,?2,'synthetic-frn-marker',?3,?4,?5,?6,?7,?8\(hasSignalColumn ? ",?9" : ""))"
        guard sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK, let statement else { throw FCC.Failure.cannotRead }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, Int64(id))
        _ = bytes.withUnsafeBytes { sqlite3_bind_blob(statement, 2, $0.baseAddress, Int32(bytes.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
        sqlite3_bind_int(statement, 3, Int32(provider))
        sqlite3_bind_text(statement, 4, brand, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_bind_int(statement, 5, Int32(technology))
        sqlite3_bind_double(statement, 6, download); sqlite3_bind_double(statement, 7, upload)
        sqlite3_bind_int(statement, 8, Int32(environment))
        if hasSignalColumn {
            if let signal { sqlite3_bind_double(statement, 9, signal) }
            else { sqlite3_bind_null(statement, 9) }
        }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw FCC.Failure.cannotRead }
        if index { try execute("INSERT INTO \"rtree_\(layer)_geom\" VALUES(\(id),\(bounds.west),\(bounds.east),\(bounds.south),\(bounds.north))") }
    }
    func close() { if let db { sqlite3_close(db) }; db = nil }
}

private let square: Ring = [[0, 0], [10, 0], [10, 10], [0, 10], [0, 0]]
private let hole: Ring = [[4, 4], [4, 6], [6, 6], [6, 4], [4, 4]]
private let region = FCC.Bounds(west: 1, south: 1, east: 2, north: 2)
private func selection(_ environment: Int = 0, layer: String = "fcc_raw", technology: Int = 500,
                       download: Double = 35, upload: Double = 3) -> FCC.Selection {
    .init(layerName: layer, providerID: 130403, technology: technology, minimumDownloadMbps: download,
          minimumUploadMbps: upload, environment: environment)
}

@main private enum Harness {
    static func main() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("fcc-geopackage-fixtures-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let suite = Suite()
        try encoding(suite, folder)
        try modeledSignals(suite, folder)
        try spatial(suite, folder)
        try categories(suite, folder)
        try malformed(suite, folder)
        try schemas(suite, folder)
        try budgets(suite, folder)
        let cancelled = Task { () -> FCC.Failure? in
            try? await Task.sleep(nanoseconds: 100_000_000)
            do { _ = try FCC.inspect(url: folder.appendingPathComponent("missing.gpkg")); return nil }
            catch { return error as? FCC.Failure }
        }
        cancelled.cancel()
        // Cancellation is checked before opening a supplied file, even when the file is absent.
        let cancellationResult = await cancelled.value
        suite.expect(cancellationResult == .cancelled, "cancelled worker exits before file access")
        if let path = CommandLine.arguments.dropFirst().first {
            try publicFCC(suite, URL(fileURLWithPath: path))
        } else { print("SKIP: actual FCC public-file checks (pass its path to enable)") }
        print("\(suite.failures == 0 ? "PASS" : "FAIL"): \(suite.checks) FCC GeoPackage checks; \(suite.failures) failures")
        if suite.failures > 0 { exit(1) }
    }

    private static func encoding(_ suite: Suite, _ folder: URL) throws {
        for header in [false, true] { for wkb in [false, true] { for envelope in [false, true] {
            let fixture = try SyntheticDatabase(folder: folder)
            try fixture.add(geometry([[square, hole]], headerLittle: header, wkbLittle: wkb,
                envelope: envelope ? .init(west: 0, south: 0, east: 10, north: 10) : nil))
            fixture.close()
            let original = try Data(contentsOf: fixture.url)
            let inspection = try FCC.inspect(url: fixture.url)
            suite.expect(inspection.categories == [.init(selection: selection(), featureCount: 1)], "inspect raw category in all byte orders")
            let result = try FCC.extract(url: fixture.url, bounds: region, selection: selection())
            let parsed = try TMobileCoverageReferenceSupport.parse(result.geoJSON, publishedDate: "2026-01-01")
            suite.expect(parsed.polygons.count == 1 && parsed.polygons[0].count == 2, "actual GeoJSON parser accepts preserved hole")
            suite.expect(parsed.modeledSignalDBm == [-110], "modeled signal survives all geometry byte orders with holes")
            suite.expect(parsed.polygons[0][0].map { [$0.longitude, $0.latitude] } == square, "whole original outer ring retained without clipping")
            suite.expect(parsed.polygons[0][1].map { [$0.longitude, $0.latitude] } == hole, "hole vertex order and exact values retained")
            suite.expect(result.metadata == .init(selection: selection(), bounds: region, featureCount: 1, polygonCount: 1, coordinateCount: 10), "allowlisted extraction metadata")
            suite.expect(!String(decoding: result.geoJSON, as: UTF8.self).contains("synthetic-frn-marker"), "source properties excluded")
            let after = try Data(contentsOf: fixture.url)
            suite.expect(after == original, "inspection and extraction leave file bytes unchanged")
        } } }
        let multi = try SyntheticDatabase(folder: folder, type: "MULTIPOLYGON")
        let second: Ring = [[20, 20], [21, 20], [21, 21], [20, 20]]
        try multi.add(geometry([[square], [second]], multi: true), bounds: .init(west: 0, south: 0, east: 21, north: 21)); multi.close()
        let result = try FCC.extract(url: multi.url, bounds: region, selection: selection())
        let parsed = try TMobileCoverageReferenceSupport.parse(result.geoJSON, publishedDate: "2026-01-01")
        suite.expect(parsed.polygons.count == 1 && result.metadata.polygonCount == 1 && result.metadata.featureCount == 1,
            "MultiPolygon spatial filtering keeps only complete intersecting components")
        suite.expect(parsed.polygons[0][0].map { [$0.longitude, $0.latitude] } == square, "intersecting MultiPolygon component retains every original coordinate")
        suite.expect(parsed.modeledSignalDBm == [-110], "spatially filtered MultiPolygon signal remains aligned with retained components")
        let full = try FCC.extract(url: multi.url, bounds: .init(west: -1, south: -1, east: 22, north: 22), selection: selection())
        let fullParsed = try TMobileCoverageReferenceSupport.parse(full.geoJSON, publishedDate: "2026-01-01")
        suite.expect(fullParsed.polygons.count == 2 && fullParsed.modeledSignalDBm == [-110, -110],
                     "one raw feature signal is duplicated for each MultiPolygon component")
    }

    private static func modeledSignals(_ suite: Suite, _ folder: URL) throws {
        for signal: Double? in [-120, -85.5, -50, nil] {
            let fixture = try SyntheticDatabase(folder: folder)
            try fixture.add(geometry([[square, hole]]), signal: signal); fixture.close()
            let result = try FCC.extract(url: fixture.url, bounds: region, selection: selection())
            let parsed = try TMobileCoverageReferenceSupport.parse(result.geoJSON, publishedDate: "2026-01-01")
            suite.expect(parsed.modeledSignalDBm == [signal] && parsed.polygons[0].count == 2,
                         "numeric boundary, decimal and null signal preserve geometry with an aligned value")
            let object = try JSONSerialization.jsonObject(with: result.geoJSON) as! [String: Any]
            let feature = (object["features"] as! [[String: Any]])[0]
            suite.expect(Set((feature["properties"] as! [String: Any]).keys) == ["fccMinimumSignalDBm"],
                         "reader emits only the allowlisted modeled signal property")
        }
        let absent = try SyntheticDatabase(folder: folder, signalColumn: false)
        try absent.add(geometry([[square]])); absent.close()
        let unknown = try FCC.extract(url: absent.url, bounds: region, selection: selection())
        let parsedUnknown = try TMobileCoverageReferenceSupport.parse(unknown.geoJSON, publishedDate: "2026-01-01")
        suite.expect(parsedUnknown.modeledSignalDBm == nil && parsedUnknown.polygons.count == 1,
                     "raw schema without minsignal remains usable with an unknown signal layer")
        for value in ["-120.01", "-49.99", "1e999", "'-110 dBm'", "x'0102'", "1"] {
            let fixture = try SyntheticDatabase(folder: folder)
            try fixture.add(geometry([[square]])); try fixture.execute("UPDATE fcc_raw SET minsignal=\(value)"); fixture.close()
            suite.fails(.invalidModeledSignal, "invalid raw signal range, nonfinite value or storage type rejects extraction") {
                _ = try FCC.extract(url: fixture.url, bounds: region, selection: selection())
            }
        }
        let mixed = try SyntheticDatabase(folder: folder)
        try mixed.add(geometry([[square]]), id: 1, signal: -80)
        try mixed.add(geometry([[square]]), id: 2, environment: 1, signal: nil)
        try mixed.add(geometry([[square]]), id: 3, technology: 400, download: 5, upload: 1, signal: -100)
        mixed.close()
        let union = try TMobileCoverageReferenceSupport.parse(
            FCC.extract(url: mixed.url, bounds: region, selection: selection(2)).geoJSON, publishedDate: "2026-01-01")
        suite.expect(union.modeledSignalDBm?.count == 2 && union.modeledSignalDBm?.compactMap { $0 } == [-80],
                     "environment union retains known and unknown signals without adding another technology")
        let lte = try TMobileCoverageReferenceSupport.parse(FCC.extract(url: mixed.url, bounds: region,
            selection: selection(0, technology: 400, download: 5, upload: 1)).geoJSON, publishedDate: "2026-01-01")
        suite.expect(lte.modeledSignalDBm == [-100], "LTE modeled RSRP stays bound to its selected category")
    }

    private static func spatial(_ suite: Suite, _ folder: URL) throws {
        let fixture = try SyntheticDatabase(folder: folder)
        try fixture.add(geometry([[square, hole]])); fixture.close()
        for bounds in [region, .init(west: -1, south: 2, east: 1, north: 3),
                       .init(west: -1, south: -1, east: 11, north: 11), .init(west: 10, south: 4, east: 11, north: 5),
                       .init(west: 3.5, south: 4.5, east: 4, north: 5.5)] {
            suite.expect((try? FCC.extract(url: fixture.url, bounds: bounds, selection: selection()))?.metadata.featureCount == 1,
                         "polygon interior, edge, enclosing area, and hole boundary intersect")
        }
        for bounds in [FCC.Bounds(west: 4.5, south: 4.5, east: 5.5, north: 5.5),
                       .init(west: 11, south: 11, east: 12, north: 12)] {
            suite.fails(.noCoverage, "hole interior and disjoint area are not coverage") { _ = try FCC.extract(url: fixture.url, bounds: bounds, selection: selection()) }
        }
        let triangle: Ring = [[0, 0], [10, 0], [0, 10], [0, 0]]
        let triangleFile = try SyntheticDatabase(folder: folder); try triangleFile.add(geometry([[triangle]])); triangleFile.close()
        suite.fails(.noCoverage, "RTree bounding-box false positive is filtered by actual geometry") {
            _ = try FCC.extract(url: triangleFile.url, bounds: .init(west: 8, south: 8, east: 9, north: 9), selection: selection())
        }
        for bounds in [FCC.Bounds(west: .nan, south: 0, east: 1, north: 1), .init(west: 0, south: 0, east: .infinity, north: 1),
                       .init(west: 2, south: 0, east: 1, north: 1), .init(west: 0, south: 1, east: 1, north: 1),
                       .init(west: 170, south: 0, east: -170, north: 1), .init(west: -181, south: 0, east: 1, north: 1)] {
            suite.fails(.invalidBounds, "invalid and date-line-crossing map areas rejected") { _ = try FCC.extract(url: fixture.url, bounds: bounds, selection: selection()) }
        }
    }

    private static func categories(_ suite: Suite, _ folder: URL) throws {
        let fixture = try SyntheticDatabase(folder: folder)
        for i in 0..<2 { try fixture.add(geometry([[square]]), id: i + 1, environment: i) }
        try fixture.add(geometry([[square]]), id: 3, provider: 999999)
        try fixture.add(geometry([[square]]), id: 4, brand: "Other")
        try fixture.add(geometry([[square]]), id: 5, technology: 400, download: 5, upload: 1)
        fixture.close()
        let inspection = try FCC.inspect(url: fixture.url)
        suite.expect(inspection.categories.count == 3 && !inspection.categories.contains(where: { $0.selection.environment == 2 }), "inspect returns actual stored categories only")
        for environment in 0...2 {
            let result = try FCC.extract(url: fixture.url, bounds: region, selection: selection(environment))
            suite.expect(result.metadata.featureCount == (environment == 2 ? 2 : 1), "explicit env\(environment) selects exact rows; env2 unions 0+1")
        }
        let lte = try FCC.extract(url: fixture.url, bounds: region, selection: selection(0, technology: 400, download: 5, upload: 1))
        suite.expect(lte.metadata.featureCount == 1, "LTE technology and speed tier isolated from 5G")
        for invalid in [selection(3), selection(0, layer: "missing"), selection(0, technology: 500, download: 7, upload: 1),
                        FCC.Selection(layerName: "fcc_raw", providerID: 999999, technology: 500, minimumDownloadMbps: 35, minimumUploadMbps: 3, environment: 0)] {
            suite.fails(.invalidSelection, "unavailable category/provider fails before extracting") { _ = try FCC.extract(url: fixture.url, bounds: region, selection: invalid) }
        }
    }

    private static func malformed(_ suite: Suite, _ folder: URL) throws {
        let valid = geometry([[square]])
        var variants: [Data] = []
        for (offset, value) in [(0, UInt8(0)), (1, 0), (2, 1), (3, 0x11), (3, 0x21), (3, 0x41), (3, 0x05), (4, 0), (8, 2), (9, 1), (9, 0xeb)] {
            var bytes = valid; bytes[offset] = value; variants.append(bytes)
        }
        variants += [valid.dropLast(), Data(valid.prefix(10)), valid + Data([0]), geometry([[[[0, 0], [1, 0], [1, 1], [0, 1]]]]),
                     geometry([[[[0, 0], [0, 0], [0, 0], [0, 0]]]]),
                     geometry([[[[0, 0], [1, .nan], [1, 1], [0, 0]]]]),
                     geometry([[[[0, 0], [1, .infinity], [1, 1], [0, 0]]]]),
                     geometry([[[[0, 0], [181, 0], [1, 1], [0, 0]]]]),
                     geometry([[[[0, 0], [1, 91], [1, 1], [0, 0]]]]),
                     geometry([[square]], envelope: .init(west: 0, south: 0, east: 9, north: 10))]
        var empty = valid; empty.replaceSubrange(13..<17, with: u32(0)); variants.append(empty)
        var emptyPoints = valid; emptyPoints.replaceSubrange(17..<21, with: u32(0)); variants.append(emptyPoints)
        for bytes in variants {
            let fixture = try SyntheticDatabase(folder: folder); try fixture.add(bytes); fixture.close()
            suite.fails(.malformedGeometry, "malformed GP header/WKB/rings fail closed") { _ = try FCC.extract(url: fixture.url, bounds: region, selection: selection()) }
        }
        let mismatch = try SyntheticDatabase(folder: folder, type: "POLYGON")
        try mismatch.add(geometry([[square]], multi: true)); mismatch.close()
        suite.expect((try? FCC.extract(url: mismatch.url, bounds: region, selection: selection()))?.metadata.polygonCount == 1,
                     "official POLYGON metadata with standard MultiPolygon WKB is accepted")
    }

    private static func schemas(_ suite: Suite, _ folder: URL) throws {
        for sql in ["UPDATE gpkg_geometry_columns SET srs_id=3857", "UPDATE gpkg_contents SET srs_id=3857",
                    "UPDATE gpkg_geometry_columns SET z=1", "UPDATE gpkg_geometry_columns SET m=1",
                    "UPDATE gpkg_geometry_columns SET geometry_type_name='POINT'", "UPDATE gpkg_geometry_columns SET column_name='h3'",
                    "UPDATE gpkg_geometry_columns SET table_name='injected;SELECT 1'; UPDATE gpkg_contents SET table_name='injected;SELECT 1'",
                    "DROP TABLE gpkg_geometry_columns; CREATE VIEW gpkg_geometry_columns AS SELECT load_extension('forbidden') AS table_name",
                    "DROP TABLE fcc_raw; CREATE VIEW fcc_raw AS SELECT load_extension('forbidden') AS fid",
                    "DROP TABLE rtree_fcc_raw_geom; CREATE TABLE rtree_fcc_raw_geom(id,minx,maxx,miny,maxy)",
                    "DROP TABLE rtree_fcc_raw_geom; CREATE VIRTUAL TABLE rtree_fcc_raw_geom USING fts5(id,minx,maxx,miny,maxy)",
                    "DROP TABLE fcc_raw; CREATE TABLE fcc_raw(fid INTEGER PRIMARY KEY,geom AS (zeroblob(100)),frn,providerid,brandname,technology,mindown,minup,minsignal,environmnt)",
                    "UPDATE fcc_raw SET environmnt=2", "UPDATE fcc_raw SET technology=999", "UPDATE fcc_raw SET mindown=0",
                    "UPDATE fcc_raw SET providerid=999999", "UPDATE fcc_raw SET brandname='T-Mobile extra'"] {
            let fixture = try SyntheticDatabase(folder: folder); try fixture.add(geometry([[square]])); try fixture.execute(sql); fixture.close()
            suite.fails(nil, "unsupported, injected, virtual or generated schema/category rejected") { _ = try FCC.inspect(url: fixture.url) }
        }
        let missingIndex = try SyntheticDatabase(folder: folder); try missingIndex.add(geometry([[square]]), index: false); missingIndex.close()
        suite.fails(.invalidSpatialIndex, "missing index rows reject incomplete spatial queries") { _ = try FCC.inspect(url: missingIndex.url) }
        let wrongBox = try SyntheticDatabase(folder: folder)
        try wrongBox.add(geometry([[square]]), bounds: .init(west: 0, south: 0, east: 2, north: 2)); wrongBox.close()
        suite.fails(.invalidSpatialIndex, "candidate index bounds must contain complete geometry") { _ = try FCC.extract(url: wrongBox.url, bounds: region, selection: selection()) }
        let link = folder.appendingPathComponent("symlink.gpkg")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: wrongBox.url)
        suite.fails(.cannotRead, "symlink input is not a regular local GeoPackage") { _ = try FCC.inspect(url: link) }
        suite.fails(.cannotRead, "remote URL rejected") { _ = try FCC.inspect(url: URL(string: "https://example.invalid/data.gpkg")!) }
        let garbage = folder.appendingPathComponent("garbage.gpkg"); try Data("not SQLite".utf8).write(to: garbage)
        suite.fails(nil, "non-SQLite content rejected") { _ = try FCC.inspect(url: garbage) }
    }

    private static func budgets(_ suite: Suite, _ folder: URL) throws {
        let tooMany = try SyntheticDatabase(folder: folder)
        try tooMany.execute("BEGIN")
        for i in 1...1_001 { try tooMany.add(geometry([[square]]), id: i, environment: i.isMultiple(of: 2) ? 1 : 0) }
        try tooMany.execute("COMMIT"); tooMany.close()
        suite.fails(.areaTooLarge, "union feature budget rejects entire result instead of truncating") { _ = try FCC.extract(url: tooMany.url, bounds: region, selection: selection(2)) }
        for (offset, value) in [(13, 1_001), (17, 100_001)] {
            var bytes = geometry([[square]]); bytes.replaceSubrange(offset..<(offset + 4), with: u32(UInt32(value)))
            let fixture = try SyntheticDatabase(folder: folder); try fixture.add(bytes); fixture.close()
            suite.fails(.areaTooLarge, "oversized ring/coordinate declarations rejected before allocation") { _ = try FCC.extract(url: fixture.url, bounds: region, selection: selection()) }
        }
        let multi = try SyntheticDatabase(folder: folder, type: "MULTIPOLYGON")
        try multi.add(geometry(Array(repeating: [square], count: 1_000), multi: true))
        try multi.add(geometry([[square]], multi: true), id: 2); multi.close()
        suite.fails(.areaTooLarge, "polygon budget combines MultiPolygon components across features") { _ = try FCC.extract(url: multi.url, bounds: region, selection: selection()) }
        let coords = try SyntheticDatabase(folder: folder)
        var ring: Ring = (0..<50_000).map { i in
            let angle = Double(i) * 2 * Double.pi / 50_000
            return [5 + 5 * cos(angle), 5 + 5 * sin(angle)]
        }
        ring.append(ring[0])
        try coords.add(geometry([[ring]])); try coords.add(geometry([[ring]]), id: 2); coords.close()
        suite.fails(.areaTooLarge, "coordinate budget accumulates across valid complete features") { _ = try FCC.extract(url: coords.url, bounds: region, selection: selection()) }
        let bytes = try SyntheticDatabase(folder: folder)
        var longRing: Ring = [[-10, -10], [10, -10], [10, 10]]
        longRing += Array(repeating: [-1.2345678901234567e-100, -2.3456789012345678e-100], count: 99_995)
        longRing += [[-10, 10], [-10, -10]]
        try bytes.add(geometry([[longRing]]), bounds: .init(west: -10, south: -10, east: 10, north: 10)); bytes.close()
        suite.fails(.areaTooLarge, "serialized GeoJSON byte limit checked independently of coordinate count") {
            _ = try FCC.extract(url: bytes.url, bounds: .init(west: -10.1, south: -10.1, east: -9.9, north: -9.9), selection: selection())
        }
    }

    private static func publicFCC(_ suite: Suite, _ url: URL) throws {
        // This optional path is read only; no synthetic writer receives it.
        let before = try FileManager.default.attributesOfItem(atPath: url.path)
        let inspection = try FCC.inspect(url: url)
        suite.expect(inspection.categories.count == 2, "official California raw file exposes two environment categories")
        suite.expect(inspection.categories.map(\.featureCount).reduce(0, +) == 4_446, "official California row count verified")
        guard let category = inspection.categories.first else { throw FCC.Failure.unsupportedRawSchema }
        let selected = FCC.Selection(layerName: category.selection.layerName, providerID: 130403, technology: 500,
            minimumDownloadMbps: 35, minimumUploadMbps: 3, environment: 2)
        // Generic Sacramento city area, unrelated to user/device location.
        let area = FCC.Bounds(west: -121.52, south: 38.56, east: -121.47, north: 38.61)
        let result = try FCC.extract(url: url, bounds: area, selection: selected)
        let parsed = try TMobileCoverageReferenceSupport.parse(result.geoJSON, publishedDate: "2025-12-31")
        suite.expect(result.metadata.featureCount > 0 && parsed.polygons.count == result.metadata.polygonCount, "official regional extraction passes the actual existing GeoJSON importer")
        suite.expect(result.geoJSON.count <= 5_000_000 && result.metadata.polygonCount <= 1_000 && result.metadata.coordinateCount <= 100_000, "official extraction respects all bounded importer limits")
        suite.expect(result.metadata.selection.environment == 2 && result.metadata.bounds == area, "official extraction records explicit derived category and requested bounds")
        let after = try FileManager.default.attributesOfItem(atPath: url.path)
        suite.expect(before[.size] as? NSNumber == after[.size] as? NSNumber && before[.modificationDate] as? Date == after[.modificationDate] as? Date,
                     "official public input size and modification date unchanged")
        print("Public Sacramento fixture: \(result.metadata.featureCount) features, \(result.metadata.polygonCount) polygons, \(result.metadata.coordinateCount) coordinates, \(result.geoJSON.count) bytes")
    }
}
