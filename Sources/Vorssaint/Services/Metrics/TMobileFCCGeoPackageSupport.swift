// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import SQLite3
import Darwin

/// Offline reader for the FCC's raw, WGS84 mobile coverage GeoPackages.
/// Call on a worker task. No coordinates, files, or metadata leave this Mac.
enum TMobileFCCGeoPackageSupport {
    struct Bounds: Equatable, Sendable {
        let west: Double
        let south: Double
        let east: Double
        let north: Double

        fileprivate var isValid: Bool {
            [west, south, east, north].allSatisfy(\.isFinite)
                && west >= -180 && east <= 180 && south >= -90 && north <= 90
                && west < east && south < north
        }
    }

    struct Selection: Hashable, Sendable {
        let layerName: String
        let providerID: Int
        let technology: Int
        let minimumDownloadMbps: Double
        let minimumUploadMbps: Double
        /// FCC codes: 0 = outdoor stationary only, 1 = in-vehicle and outdoor stationary.
        /// 2 is an app-derived union of 0 and 1, never a stored FCC environment code.
        let environment: Int

        fileprivate func matches(_ other: Selection) -> Bool {
            layerName == other.layerName && providerID == other.providerID
                && technology == other.technology && minimumDownloadMbps == other.minimumDownloadMbps
                && minimumUploadMbps == other.minimumUploadMbps
                && (environment == other.environment || (environment == 2 && (0...1).contains(other.environment)))
        }
    }

    struct Category: Equatable, Sendable {
        let selection: Selection
        let featureCount: Int
    }
    struct Inspection: Equatable, Sendable { let categories: [Category] }
    struct Metadata: Equatable, Sendable {
        let selection: Selection
        /// Requested area. Shapes are complete model polygons intersecting this area, not clipped to it.
        let bounds: Bounds
        /// Number of original GeoPackage feature rows represented by the selected polygons.
        let featureCount: Int
        let polygonCount: Int
        let coordinateCount: Int
    }
    struct Extraction: Sendable {
        let geoJSON: Data
        let metadata: Metadata
    }

    enum Failure: LocalizedError, Equatable {
        case cannotRead, unsupportedRawSchema, invalidSelection, invalidBounds
        case malformedGeometry, invalidModeledSignal, invalidSpatialIndex, areaTooLarge, noCoverage, cancelled, timedOut
        var errorDescription: String? {
            switch self {
            case .cannotRead: return "The local GeoPackage could not be read. Choose an uncompressed FCC Raw Coverage GeoPackage."
            case .unsupportedRawSchema: return "Choose the FCC Raw Coverage GeoPackage for T-Mobile with WGS84 Polygon or MultiPolygon geometry. H3, projected, and 3D datasets are not supported."
            case .invalidSelection: return "Choose an available T-Mobile technology, speed tier, and environment from this GeoPackage."
            case .invalidBounds: return "Select a finite map area within WGS84 bounds that does not cross the date line."
            case .malformedGeometry: return "The selected coverage contains invalid or unsupported geometry. Choose a valid 2D WGS84 FCC Raw Coverage GeoPackage."
            case .invalidModeledSignal: return "The selected coverage contains an invalid modeled signal value. FCC minimum signal must be a number from −120 to −50 dBm, or unknown."
            case .invalidSpatialIndex: return "The GeoPackage spatial index is missing or inconsistent. Choose a complete FCC Raw Coverage GeoPackage."
            case .areaTooLarge: return "Zoom in and import a smaller map area. Complete intersecting polygons exceed the 5 MB, 1,000 polygon, or 100,000 coordinate limit."
            case .noCoverage: return "No model polygons for this category intersect the selected map area."
            case .cancelled: return "The GeoPackage import was cancelled."
            case .timedOut: return "The GeoPackage took too long to read. Select a smaller area or another FCC Raw Coverage GeoPackage."
            }
        }
    }

    private static let maximumBytes = 5_000_000
    private static let maximumPolygons = 1_000
    private static let maximumCoordinates = 100_000
    private static let providerID = 130403

    static func inspect(url: URL) throws -> Inspection {
        if Task<Never, Never>.isCancelled { throw Failure.cancelled }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let db = try Database(url: url)
        return try inspection(db)
    }

    static func extract(url: URL, bounds: Bounds, selection: Selection) throws -> Extraction {
        if Task<Never, Never>.isCancelled { throw Failure.cancelled }
        guard bounds.isValid else { throw Failure.invalidBounds }
        guard selection.providerID == providerID, (0...2).contains(selection.environment) else { throw Failure.invalidSelection }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let db = try Database(url: url)
        let available = try inspection(db)
        guard available.categories.contains(where: { selection.matches($0.selection) }) else { throw Failure.invalidSelection }
        let layer = try db.layer(named: selection.layerName)
        let table = try identifier(layer.name), index = try identifier(layer.index)
        let environment = selection.environment == 2 ? "f.environmnt IN (0,1)" : "f.environmnt = ?9"
        let signalColumn = layer.hasMinimumSignal ? "f.minsignal" : "NULL"
        let statement = try db.prepare("""
            SELECT f.geom,r.minx,r.maxx,r.miny,r.maxy,\(signalColumn) FROM \(table) AS f
            JOIN \(index) AS r ON f.fid=r.id
            WHERE r.minx<=?1 AND r.maxx>=?2 AND r.miny<=?3 AND r.maxy>=?4
              AND f.providerid=?5 AND f.brandname='T-Mobile' AND f.technology=?6
              AND f.mindown=?7 AND f.minup=?8 AND \(environment)
            """)
        defer { sqlite3_finalize(statement) }
        for (index, value) in [bounds.east, bounds.west, bounds.north, bounds.south,
                               Double(providerID), Double(selection.technology), selection.minimumDownloadMbps,
                               selection.minimumUploadMbps, Double(selection.environment)].enumerated() {
            if index < 8 || selection.environment != 2 { sqlite3_bind_double(statement, Int32(index + 1), value) }
        }
        var features: [[String: Any]] = [], polygonCount = 0, coordinateCount = 0
        while try db.step(statement) {
            try db.checkCancellation()
            guard sqlite3_column_type(statement, 0) == SQLITE_BLOB else { throw Failure.malformedGeometry }
            let size = Int(sqlite3_column_bytes(statement, 0))
            guard size <= 1_700_000 else { throw Failure.areaTooLarge }
            guard size >= 13, let bytes = sqlite3_column_blob(statement, 0) else { throw Failure.malformedGeometry }
            let geometry = try Geometry(data: Data(bytes: bytes, count: size))
            let indexed = Bounds(west: sqlite3_column_double(statement, 1), south: sqlite3_column_double(statement, 3),
                                 east: sqlite3_column_double(statement, 2), north: sqlite3_column_double(statement, 4))
            guard [indexed.west, indexed.south, indexed.east, indexed.north].allSatisfy(\.isFinite),
                  indexed.west <= geometry.bounds.west, indexed.east >= geometry.bounds.east,
                  indexed.south <= geometry.bounds.south, indexed.north >= geometry.bounds.north
            else { throw Failure.invalidSpatialIndex }
            let selected = geometry.intersecting(bounds)
            guard !selected.isEmpty else { continue }
            var properties: [String: Any] = [:]
            if layer.hasMinimumSignal {
                let signalType = sqlite3_column_type(statement, 5)
                if signalType == SQLITE_NULL {
                    properties["fccMinimumSignalDBm"] = NSNull()
                } else {
                    guard [SQLITE_INTEGER, SQLITE_FLOAT].contains(signalType) else { throw Failure.invalidModeledSignal }
                    let signal = sqlite3_column_double(statement, 5)
                    guard signal.isFinite, (-120 ... -50).contains(signal) else { throw Failure.invalidModeledSignal }
                    properties["fccMinimumSignalDBm"] = signal
                }
            }
            polygonCount += selected.count
            coordinateCount += selected.reduce(0) { $0 + $1.reduce(0) { $0 + $1.count } }
            guard features.count < maximumPolygons, polygonCount <= maximumPolygons,
                  coordinateCount <= maximumCoordinates else { throw Failure.areaTooLarge }
            features.append(["type": "Feature", "properties": properties, "geometry": geometry.json(polygons: selected)])
        }
        guard !features.isEmpty else { throw Failure.noCoverage }
        try db.checkCancellation()
        let data = try JSONSerialization.data(withJSONObject: ["type": "FeatureCollection", "features": features], options: [.sortedKeys])
        try db.checkCancellation()
        guard data.count <= maximumBytes else { throw Failure.areaTooLarge }
        return .init(geoJSON: data, metadata: .init(selection: selection, bounds: bounds, featureCount: features.count,
                                                   polygonCount: polygonCount, coordinateCount: coordinateCount))
    }

    private static func inspection(_ db: Database) throws -> Inspection {
        let layers = try db.layers()
        var categories: [Category] = []
        for layer in layers {
            let table = try identifier(layer.name)
            let statement = try db.prepare("""
                SELECT technology,mindown,minup,environmnt,count(*) FROM \(table)
                WHERE providerid=130403 AND brandname='T-Mobile'
                GROUP BY technology,mindown,minup,environmnt ORDER BY technology,mindown,minup,environmnt
                """)
            defer { sqlite3_finalize(statement) }
            while try db.step(statement) {
                guard categories.count < 64,
                      sqlite3_column_type(statement, 0) == SQLITE_INTEGER,
                      sqlite3_column_type(statement, 3) == SQLITE_INTEGER,
                      [SQLITE_INTEGER, SQLITE_FLOAT].contains(sqlite3_column_type(statement, 1)),
                      [SQLITE_INTEGER, SQLITE_FLOAT].contains(sqlite3_column_type(statement, 2)) else { throw Failure.unsupportedRawSchema }
                let technology = Int(sqlite3_column_int64(statement, 0))
                let download = sqlite3_column_double(statement, 1), upload = sqlite3_column_double(statement, 2)
                let environment = Int(sqlite3_column_int64(statement, 3)), count = Int(sqlite3_column_int64(statement, 4))
                guard [300, 400, 500].contains(technology), (0...1).contains(environment),
                      download.isFinite, upload.isFinite, download > 0, upload > 0,
                      download <= 1_000_000, upload <= 1_000_000, count > 0 else { throw Failure.unsupportedRawSchema }
                categories.append(.init(selection: .init(layerName: layer.name, providerID: providerID, technology: technology,
                    minimumDownloadMbps: download, minimumUploadMbps: upload, environment: environment), featureCount: count))
            }
        }
        guard !categories.isEmpty else { throw Failure.unsupportedRawSchema }
        return .init(categories: categories)
    }

    /// Strict identifiers avoid letting schema text become SQL. FCC-generated raw layer names fit this set.
    private static func identifier(_ value: String) throws -> String {
        guard !value.isEmpty, value.utf8.count <= 180,
              value.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 95 })
        else { throw Failure.unsupportedRawSchema }
        return "\"\(value)\""
    }

    private struct Layer {
        let name: String
        let hasMinimumSignal: Bool
        var index: String { "rtree_\(name)_geom" }
    }

    private final class Database {
        private var handle: OpaquePointer?
        private let context = Context()
        private var validatedLayers: [Layer]?

        private final class Context {
            var allowedTables: Set<String> = ["sqlite_master", "sqlite_schema", "gpkg_contents", "gpkg_geometry_columns"]
            var rtreeShadowTables: Set<String> = []
            let deadline = ProcessInfo.processInfo.systemUptime + 30
        }

        init(url: URL) throws {
            guard url.isFileURL,
                  let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
                  attrs[.type] as? FileAttributeType == .typeRegular,
                  (attrs[.size] as? NSNumber)?.int64Value ?? 0 > 0 else { throw Failure.cannotRead }
            let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX | SQLITE_OPEN_PRIVATECACHE | SQLITE_OPEN_NOFOLLOW
            // macOS commonly supplies /var URLs whose parent is a system symlink. Resolve
            // parents only; the selected file itself must remain regular and never be followed.
            guard let parent = realpath(url.deletingLastPathComponent().path, nil) else { throw Failure.cannotRead }
            let path = String(cString: parent) + "/" + url.lastPathComponent
            free(parent)
            guard sqlite3_open_v2(path, &handle, flags, nil) == SQLITE_OK, let handle else {
                if let handle { sqlite3_close(handle) }; self.handle = nil
                throw Failure.cannotRead
            }
            do {
                // Apple's SQLite omits the extension-loading API entirely. Fail closed if that
                // build guarantee changes; the authorizer also rejects all extension functions.
                guard sqlite3_db_readonly(handle, "main") == 1,
                      sqlite3_compileoption_used("OMIT_LOAD_EXTENSION") == 1 else { throw Failure.cannotRead }
                sqlite3_busy_timeout(handle, 1_000)
                sqlite3_limit(handle, SQLITE_LIMIT_LENGTH, 2_000_000)
                sqlite3_limit(handle, SQLITE_LIMIT_SQL_LENGTH, 32_768)
                sqlite3_limit(handle, SQLITE_LIMIT_COLUMN, 64)
                sqlite3_limit(handle, SQLITE_LIMIT_EXPR_DEPTH, 32)
                sqlite3_limit(handle, SQLITE_LIMIT_COMPOUND_SELECT, 4)
                sqlite3_limit(handle, SQLITE_LIMIT_ATTACHED, 0)
                sqlite3_limit(handle, SQLITE_LIMIT_TRIGGER_DEPTH, 0)
                sqlite3_limit(handle, SQLITE_LIMIT_VARIABLE_NUMBER, 16)
                try execute("PRAGMA query_only=ON")
                try execute("PRAGMA trusted_schema=OFF")
                try verifySetting("PRAGMA query_only", equals: 1)
                try verifySetting("PRAGMA trusted_schema", equals: 0)
                try execute("PRAGMA mmap_size=0")
                try execute("PRAGMA cache_size=-8192")
                let opaque = Unmanaged.passUnretained(context).toOpaque()
                sqlite3_progress_handler(handle, 1_000, { opaque in
                    guard let opaque else { return 1 }
                    let context = Unmanaged<Context>.fromOpaque(opaque).takeUnretainedValue()
                    return Task<Never, Never>.isCancelled || ProcessInfo.processInfo.systemUptime > context.deadline ? 1 : 0
                }, opaque)
                guard sqlite3_set_authorizer(handle, { opaque, action, first, second, database, source in
                    guard let opaque, source == nil else { return SQLITE_DENY }
                    let context = Unmanaged<Context>.fromOpaque(opaque).takeUnretainedValue()
                    let a = first.map { String(cString: $0) } ?? ""
                    let b = second.map { String(cString: $0) } ?? ""
                    switch action {
                    case SQLITE_SELECT: return SQLITE_OK
                    case SQLITE_READ:
                        // SQLite reports a table-only count(*) read with an empty column and
                        // no database name. There are no attached or temporary user databases.
                        let mainRead = database.map { String(cString: $0) } == "main" || (database == nil && b.isEmpty)
                        return mainRead && context.allowedTables.contains(a) ? SQLITE_OK : SQLITE_DENY
                    // The native RTree module reads node lengths while connecting.
                    case SQLITE_FUNCTION: return ["count", "length"].contains(b.lowercased()) ? SQLITE_OK : SQLITE_DENY
                    // RTree xConnect prepares cached shadow-table write statements even for a
                    // reader. Permit their preparation only for this verified built-in index.
                    // READONLY + query_only independently prevent any write from executing.
                    case SQLITE_INSERT, SQLITE_DELETE, SQLITE_UPDATE:
                        return database.map { String(cString: $0) } == "main" && context.rtreeShadowTables.contains(a) ? SQLITE_OK : SQLITE_DENY
                    case SQLITE_PRAGMA: return a.lowercased() == "table_xinfo" && context.allowedTables.contains(b) ? SQLITE_OK : SQLITE_DENY
                    case SQLITE_TRANSACTION: return ["BEGIN", "COMMIT", "ROLLBACK"].contains(a) ? SQLITE_OK : SQLITE_DENY
                    default: return SQLITE_DENY
                    }
                }, opaque) == SQLITE_OK else { throw Failure.cannotRead }
                try execute("BEGIN")
            } catch {
                sqlite3_close(handle); self.handle = nil
                throw error
            }
        }

        deinit {
            if let handle {
                sqlite3_set_authorizer(handle, nil, nil)
                sqlite3_progress_handler(handle, 0, nil, nil)
                sqlite3_close(handle)
            }
        }

        func checkCancellation() throws {
            if Task<Never, Never>.isCancelled { throw Failure.cancelled }
            if ProcessInfo.processInfo.systemUptime > context.deadline { throw Failure.timedOut }
        }

        func prepare(_ sql: String) throws -> OpaquePointer {
            try checkCancellation()
            var statement: OpaquePointer?
            let result = sqlite3_prepare_v2(handle, sql, -1, &statement, nil)
            guard result == SQLITE_OK, let statement else {
                if let statement { sqlite3_finalize(statement) }
                try checkCancellation()
                // Corrupt bytes must remain distinguishable from a valid unsupported schema.
                let primaryResult = result & 0xff
                if primaryResult == SQLITE_CORRUPT || primaryResult == SQLITE_NOTADB { throw Failure.cannotRead }
                throw Failure.unsupportedRawSchema
            }
            return statement
        }

        func step(_ statement: OpaquePointer) throws -> Bool {
            try checkCancellation()
            switch sqlite3_step(statement) {
            case SQLITE_ROW: return true
            case SQLITE_DONE: return false
            case SQLITE_TOOBIG: throw Failure.areaTooLarge
            default: try checkCancellation(); throw Failure.cannotRead
            }
        }

        private func execute(_ sql: String) throws {
            let statement = try prepare(sql)
            defer { sqlite3_finalize(statement) }
            while try step(statement) {}
        }

        private func verifySetting(_ sql: String, equals value: Int32) throws {
            let statement = try prepare(sql)
            defer { sqlite3_finalize(statement) }
            guard try step(statement), sqlite3_column_int(statement, 0) == value else { throw Failure.cannotRead }
        }

        private func text(_ statement: OpaquePointer, _ column: Int32) throws -> String {
            guard sqlite3_column_type(statement, column) == SQLITE_TEXT,
                  sqlite3_column_bytes(statement, column) <= 4_096, let value = sqlite3_column_text(statement, column)
            else { throw Failure.unsupportedRawSchema }
            return String(cString: value)
        }

        private func schema(_ name: String, virtual: Bool = false) throws -> String {
            _ = try identifier(name)
            let statement = try prepare("SELECT type,sql FROM sqlite_master WHERE name=?1")
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_text(statement, 1, name, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            guard try step(statement), try text(statement, 0) == "table" else { throw Failure.unsupportedRawSchema }
            let sql = try text(statement, 1)
            let upper = sql.uppercased()
            guard virtual ? upper.hasPrefix("CREATE VIRTUAL TABLE") : (!upper.hasPrefix("CREATE VIRTUAL TABLE") && upper.hasPrefix("CREATE TABLE"))
            else { throw Failure.unsupportedRawSchema }
            guard !(try step(statement)) else { throw Failure.unsupportedRawSchema }
            return sql
        }

        private func columns(_ name: String) throws -> [(name: String, type: String, primary: Int)] {
            let statement = try prepare("PRAGMA table_xinfo(\(try identifier(name)))")
            defer { sqlite3_finalize(statement) }
            var result: [(String, String, Int)] = []
            while try step(statement) {
                guard result.count < 32, sqlite3_column_int(statement, 6) == 0 else { throw Failure.unsupportedRawSchema }
                result.append((try text(statement, 1), try text(statement, 2).uppercased(), Int(sqlite3_column_int(statement, 5))))
            }
            return result
        }

        func layers() throws -> [Layer] {
            if let validatedLayers { return validatedLayers }
            _ = try schema("gpkg_contents"); _ = try schema("gpkg_geometry_columns")
            _ = try columns("gpkg_contents"); _ = try columns("gpkg_geometry_columns")
            let statement = try prepare("""
                SELECT c.table_name,c.srs_id,g.column_name,g.geometry_type_name,g.srs_id,g.z,g.m
                FROM gpkg_contents c JOIN gpkg_geometry_columns g ON c.table_name=g.table_name
                WHERE c.data_type='features' ORDER BY c.table_name
                """)
            defer { sqlite3_finalize(statement) }
            var result: [Layer] = []
            while try step(statement) {
                guard result.count < 32, sqlite3_column_int(statement, 1) == 4326,
                      sqlite3_column_int(statement, 4) == 4326,
                      sqlite3_column_int(statement, 5) == 0, sqlite3_column_int(statement, 6) == 0,
                      try text(statement, 2) == "geom" else { throw Failure.unsupportedRawSchema }
                let name = try text(statement, 0), type = try text(statement, 3)
                guard ["POLYGON", "MULTIPOLYGON"].contains(type), !result.contains(where: { $0.name == name }) else { throw Failure.unsupportedRawSchema }
                // Official raw files can declare POLYGON but store standard MultiPolygon WKB.
                // Every row is independently restricted to these two geometry types below.
                _ = try schema(name)
                context.allowedTables.insert(name)
                let fields = try columns(name)
                let required: Set<String> = ["fid", "geom", "frn", "providerid", "brandname", "technology", "mindown", "minup", "environmnt"]
                guard required.isSubset(of: Set(fields.map(\.name))),
                      fields.contains(where: { $0.name == "fid" && $0.type == "INTEGER" && $0.primary == 1 }) else { throw Failure.unsupportedRawSchema }
                let layer = Layer(name: name, hasMinimumSignal: fields.contains(where: { $0.name == "minsignal" }))
                let indexSQL = try schema(layer.index, virtual: true)
                // Accept only this exact built-in RTree module and column list.
                let normalized = indexSQL.lowercased().filter { !$0.isWhitespace && $0 != "\"" && $0 != "`" && $0 != "[" && $0 != "]" }
                guard normalized == "createvirtualtable\(layer.index.lowercased())usingrtree(id,minx,maxx,miny,maxy)" else { throw Failure.invalidSpatialIndex }
                for suffix in ["", "_node", "_rowid", "_parent"] { context.allowedTables.insert(layer.index + suffix) }
                for suffix in ["_node", "_rowid", "_parent"] { context.rtreeShadowTables.insert(layer.index + suffix) }
                guard try columns(layer.index).map(\.name) == ["id", "minx", "maxx", "miny", "maxy"] else { throw Failure.invalidSpatialIndex }
                let missing = try prepare("SELECT count(*) FROM \(try identifier(name)) f LEFT JOIN \(try identifier(layer.index)) r ON f.fid=r.id WHERE r.id IS NULL")
                defer { sqlite3_finalize(missing) }
                guard try step(missing), sqlite3_column_int64(missing, 0) == 0 else { throw Failure.invalidSpatialIndex }
                result.append(layer)
            }
            guard !result.isEmpty else { throw Failure.unsupportedRawSchema }
            validatedLayers = result
            return result
        }

        func layer(named name: String) throws -> Layer {
            guard let layer = try layers().first(where: { $0.name == name }) else { throw Failure.invalidSelection }
            return layer
        }
    }

    private struct Point: Hashable {
        let x: Double
        let y: Double
        var valid: Bool { x.isFinite && y.isFinite && (-180...180).contains(x) && (-90...90).contains(y) }
    }

    private struct Geometry {
        let type: String
        let polygons: [[[Point]]]
        let bounds: Bounds
        func json(polygons: [[[Point]]]) -> [String: Any] {
            let values = polygons.map { $0.map { $0.map { [$0.x, $0.y] } } }
            return ["type": type, "coordinates": type == "Polygon" ? values[0] as Any : values as Any]
        }

        init(data: Data) throws {
            var reader = Reader(bytes: Array(data))
            guard try reader.byte() == 0x47, try reader.byte() == 0x50, try reader.byte() == 0 else { throw Failure.malformedGeometry }
            let flags = try reader.byte(), envelope = (flags >> 1) & 7
            guard flags & 0xf0 == 0, envelope <= 1 else { throw Failure.malformedGeometry }
            let little = flags & 1 == 1
            guard try reader.uint32(little) == 4326 else { throw Failure.malformedGeometry }
            var declared: Bounds?
            if envelope == 1 {
                let west = try reader.double(little), east = try reader.double(little)
                let south = try reader.double(little), north = try reader.double(little)
                declared = Bounds(west: west, south: south, east: east, north: north)
                guard declared!.isValid else { throw Failure.malformedGeometry }
            }
            let header = try reader.wkbHeader()
            if header.type == 3 {
                type = "Polygon"; polygons = [try reader.polygon(little: header.little)]
            } else if header.type == 6 {
                type = "MultiPolygon"
                // Source MultiPolygons may contain distant components. Bound source decoding
                // by coordinate/byte limits; apply the import polygon limit after spatial filtering.
                let count = try reader.count(header.little, maximum: maximumCoordinates / 4)
                guard count <= (reader.bytes.count - reader.offset) / 77 else { throw Failure.malformedGeometry }
                var values: [[[Point]]] = []
                for _ in 0..<count {
                    let child = try reader.wkbHeader()
                    guard child.type == 3 else { throw Failure.malformedGeometry }
                    values.append(try reader.polygon(little: child.little))
                }
                polygons = values
            } else { throw Failure.malformedGeometry }
            guard reader.offset == reader.bytes.count else { throw Failure.malformedGeometry }
            var west = Double.infinity, east = -Double.infinity, south = Double.infinity, north = -Double.infinity
            for polygon in polygons { for ring in polygon { for point in ring {
                west = min(west, point.x); east = max(east, point.x); south = min(south, point.y); north = max(north, point.y)
            } } }
            bounds = .init(west: west, south: south, east: east, north: north)
            guard bounds.isValid else { throw Failure.malformedGeometry }
            if let declared {
                guard declared.west <= west, declared.east >= east, declared.south <= south, declared.north >= north
                else { throw Failure.malformedGeometry }
            }
        }

        func intersecting(_ area: Bounds) -> [[[Point]]] {
            guard bounds.west <= area.east, bounds.east >= area.west, bounds.south <= area.north, bounds.north >= area.south else { return [] }
            let corners = [Point(x: area.west, y: area.south), Point(x: area.east, y: area.south),
                           Point(x: area.east, y: area.north), Point(x: area.west, y: area.north)]
            return polygons.filter { polygon in
                for ring in polygon {
                    if ring.contains(where: { $0.x >= area.west && $0.x <= area.east && $0.y >= area.south && $0.y <= area.north }) { return true }
                    for index in 1..<ring.count {
                        if Self.segment(ring[index - 1], ring[index], intersects: area) { return true }
                    }
                }
                if corners.contains(where: { corner in
                    Self.contains(corner, ring: polygon[0])
                        && !polygon.dropFirst().contains(where: { Self.contains(corner, ring: $0) })
                }) { return true }
                return false
            }
        }

        private static func contains(_ point: Point, ring: [Point]) -> Bool {
            var inside = false
            for i in 1..<ring.count {
                let a = ring[i - 1], b = ring[i]
                if (a.y > point.y) != (b.y > point.y), point.x < (b.x - a.x) * (point.y - a.y) / (b.y - a.y) + a.x { inside.toggle() }
            }
            return inside
        }

        private static func segment(_ a: Point, _ b: Point, intersects box: Bounds) -> Bool {
            var lower = 0.0, upper = 1.0
            let dx = b.x - a.x, dy = b.y - a.y
            for (p, q) in [(-dx, a.x - box.west), (dx, box.east - a.x), (-dy, a.y - box.south), (dy, box.north - a.y)] {
                if p == 0 { if q < 0 { return false }; continue }
                let ratio = q / p
                if p < 0 { lower = max(lower, ratio) } else { upper = min(upper, ratio) }
                if lower > upper { return false }
            }
            return true
        }
    }

    private struct Reader {
        let bytes: [UInt8]
        var offset = 0
        var coordinateCount = 0
        mutating func byte() throws -> UInt8 {
            guard offset < bytes.count else { throw Failure.malformedGeometry }
            defer { offset += 1 }; return bytes[offset]
        }
        mutating func uint32(_ little: Bool) throws -> UInt32 {
            guard bytes.count - offset >= 4 else { throw Failure.malformedGeometry }
            var value: UInt32 = 0
            for i in 0..<4 { value |= UInt32(bytes[offset + i]) << UInt32((little ? i : 3 - i) * 8) }
            offset += 4; return value
        }
        mutating func double(_ little: Bool) throws -> Double {
            guard bytes.count - offset >= 8 else { throw Failure.malformedGeometry }
            var value: UInt64 = 0
            for i in 0..<8 { value |= UInt64(bytes[offset + i]) << UInt64((little ? i : 7 - i) * 8) }
            offset += 8; return Double(bitPattern: value)
        }
        mutating func count(_ little: Bool, maximum: Int) throws -> Int {
            let value = Int(try uint32(little))
            guard value > 0 else { throw Failure.malformedGeometry }
            guard value <= maximum else { throw Failure.areaTooLarge }
            return value
        }
        mutating func wkbHeader() throws -> (little: Bool, type: UInt32) {
            let endian = try byte()
            guard endian <= 1 else { throw Failure.malformedGeometry }
            return (endian == 1, try uint32(endian == 1))
        }
        mutating func polygon(little: Bool) throws -> [[Point]] {
            let rings = try count(little, maximum: 1_000)
            guard rings <= (bytes.count - offset) / 68 else { throw Failure.malformedGeometry }
            var values: [[Point]] = []
            for _ in 0..<rings {
                let count = try count(little, maximum: maximumCoordinates)
                coordinateCount += count
                guard coordinateCount <= maximumCoordinates else { throw Failure.areaTooLarge }
                guard count >= 4, count <= (bytes.count - offset) / 16 else { throw Failure.malformedGeometry }
                var points: [Point] = [], distinct: Set<Point> = []
                points.reserveCapacity(count)
                for _ in 0..<count {
                    let point = Point(x: try double(little), y: try double(little))
                    guard point.valid else { throw Failure.malformedGeometry }
                    points.append(point)
                    if distinct.count < 3 { distinct.insert(point) }
                }
                guard points.first == points.last, distinct.count >= 3 else { throw Failure.malformedGeometry }
                values.append(points)
            }
            return values
        }
    }
}
