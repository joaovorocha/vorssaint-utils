// SPDX-License-Identifier: GPL-3.0-or-later
import Combine
import Darwin
import Foundation
import MapKit
import SQLite3
import zlib

/// Only synthetic files in a fresh private temporary directory, mock credentials,
/// and an intercepting URLProtocol. No live Keychain/API, preferences or archives.
@main private enum AutomaticLoadHarness {
    static let email = "automatic-fixture@example.invalid"
    static let token = "synthetic-automatic-token"
    static let date = "2025-12-31"
    static let region = MKCoordinateRegion(center: .init(latitude: 5, longitude: 5),
                                           span: .init(latitudeDelta: 2, longitudeDelta: 2))
    static let baseline = Data(#"{"type":"FeatureCollection","features":[{"type":"Feature","geometry":{"type":"Polygon","coordinates":[[[-100,40],[-99,40],[-99,41],[-100,40]]]}}]}"#.utf8)

    @MainActor static func main() async throws {
        let folder = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("fcc-automatic-fixtures-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: folder) }
        let suite = Suite()
        let zip = try syntheticZIP(folder: folder)
        try await successfulFlow(suite, folder, zip)
        try await capturedRequest(suite, folder, zip)
        try await accessStates(suite, folder, zip)
        try await failures(suite, folder)
        try await malformedDownloadRecovery(suite, folder, zip)
        try await cancellationAndOwnership(suite, folder, zip)
        bounds(suite)
        print("\(suite.failures == 0 ? "PASS" : "FAIL"): \(suite.checks) FCC automatic-load checks; \(suite.failures) failures; all URLs intercepted; synthetic files and credential mocks only")
        if suite.failures > 0 { exit(1) }
    }

    @MainActor static func fixture(_ folder: URL, saved: Bool = true, previous: Bool = false) throws -> Fixture {
        let root = folder.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        let store = CredentialMock()
        if saved { store.value = savedJSON }
        let credentials = TMobileFCCCredentialForm(store: store, service: "fixture.fcc.automatic")
        let refsFolder = root.appendingPathComponent("references", isDirectory: true)
        let references = TMobileCoverageReferenceStore(folder: refsFolder)
        if previous, !references.importLayer(data: baseline, publishedDate: "2024-12-31") {
            throw FixtureFailure.setup
        }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FixtureProtocol.self]
        let client = FCCCoverageClient(configuration: config, limiter: .init(maximumRequests: 1000))
        let model = TMobileFCCCoverageModel(references: references, credentials: credentials, client: client,
            cache: TMobileFCCDownloadCache(directory: root.appendingPathComponent("cache", isDirectory: true)))
        return Fixture(root: root, store: store, references: references, credentials: credentials, model: model)
    }

    static var savedJSON: String {
        String(data: try! JSONSerialization.data(withJSONObject: ["username": email, "token": token]), encoding: .utf8)!
    }
    static func envelope(_ rows: [[String: Any]]) -> Data {
        try! JSONSerialization.data(withJSONObject: ["status_code": 200, "status": "successful", "result_count": rows.count, "data": rows])
    }
    static var dates: Data { envelope([["data_type": "availability", "as_of_date": date]]) }
    static var catalogue: Data { envelope([
        ["file_id": "12345", "category": "Provider", "subcategory": "Raw Coverage", "technology_type": "Mobile Broadband",
         "technology_code": "500", "technology_code_desc": "fixture", "speed_tier": "35/3", "state_fips": "06",
         "state_name": "California", "provider_id": "130403", "provider_name": "T-Mobile USA, Inc.",
         "file_type": "gis", "file_name": "synthetic_12345", "record_count": "2"]
    ]) }
    static func replies(_ zip: Data) -> [FixtureProtocol.Reply] {
        [.http(200, dates), .http(200, catalogue), .zip(zip)]
    }

    @MainActor static func successfulFlow(_ suite: Suite, _ folder: URL, _ zip: Data) async throws {
        let f = try fixture(folder)
        FixtureProtocol.reset(replies(zip))
        suite.expect(f.model.summary == "California · 5G NR · 35/3 Mbps · Outdoors", "default summary presents California and complete default category")
        suite.expect(!f.model.busy && f.store.reads.isEmpty && FixtureProtocol.requests.isEmpty,
                     "coordinator construction performs no credential read or request")
        f.model.prepare(); f.model.prepare()
        suite.expect(f.store.reads == [false] && f.credentials.savedAccessState == .available,
                     "opening workspace quietly reads exact saved access once")
        suite.expect(FixtureProtocol.requests.isEmpty, "quiet preparation never requests remote data")
        var loaded = 0
        f.model.loadCoverage(region: region) { loaded += 1 }
        f.model.loadCoverage(region: region) { loaded += 100 }
        suite.expect(f.model.busy, "one load action immediately publishes busy state")
        try await idle(f.model)
        suite.expect(loaded == 1 && f.model.loadedDate == date && !f.model.reusedDownload,
                     "one action completes local extraction before callback; repeated action while busy is ignored")
        let requests = FixtureProtocol.requests
        suite.expect(requests.map(\.url.path) == ["/api/public/map/listAsOfDates", "/api/public/map/downloads/listAvailabilityData/2025-12-31", "/api/public/map/downloads/downloadFile/availability/12345/2"],
                     "one action uses exactly documented metadata and selected GeoPackage download requests")
        suite.expect(requests.allSatisfy { $0.url.host == "broadbandmap.fcc.gov" && $0.url.scheme == "https"
            && $0.method == "GET" && $0.username == email && $0.token == token && $0.body == nil },
                     "all intercepted requests carry only scoped synthetic access to official HTTPS routes")
        suite.expect(f.references.layer?.polygons.count == 1 && f.references.layer?.modeledSignalDBm == [-95],
                     "ZIP contains real synthetic GPKG; only intersecting whole polygon and source signal persist")
        suite.expect(f.references.layer?.source?.origin == .officialAPI && f.references.layer?.source?.fileID == "12345"
            && f.references.layer?.source?.availabilityAsOf == date && f.references.layer?.source?.stateFIPS == "06",
                     "saved overlay retains official file identity, state and vintage")
        let reopened = TMobileCoverageReferenceStore(folder: f.root.appendingPathComponent("references"))
        suite.expect(reopened.layer == f.references.layer, "completed reference round-trips through actual persistent store")
        suite.expect(f.model.message == "Coverage loaded · FCC data as of \(date)." && f.store.saves == 0,
                     "saved access needs no rewrite and success copy reports actual vintage")
        FixtureProtocol.reset([.http(200, dates), .http(200, catalogue)])
        f.model.loadCoverage(region: region) { loaded += 1 }
        try await idle(f.model)
        suite.expect(loaded == 2 && f.model.reusedDownload && FixtureProtocol.requests.count == 2,
                     "second action rechecks latest vintage and reuses the verified ZIP without downloading")
        suite.expect(f.store.reads == [false] && f.store.saves == 0, "repeated loads do not prompt, reread or rewrite saved access")
        suite.expect(FixtureProtocol.unexpectedRequests == 0, "all expected requests were serviced without live-network fallback")
    }

    @MainActor static func capturedRequest(_ suite: Suite, _ folder: URL, _ zip: Data) async throws {
        let f = try fixture(folder)
        f.model.environment = 1
        var requestedRegion = region
        FixtureProtocol.reset(replies(zip))
        var loaded = 0
        f.model.loadCoverage(region: requestedRegion) { loaded += 1 }
        // This occurs before the coordinator task can execute on the main actor.
        requestedRegion.center = .init(latitude: 25, longitude: 25)
        f.model.stateFIPS = "32"; f.model.technology = .lte; f.model.speedTier = .sevenOne; f.model.environment = 2
        f.credentials.username = "changed-fixture@example.invalid"; f.credentials.token = "changed-synthetic-token"
        try await idle(f.model)
        suite.expect(loaded == 1 && f.references.layer?.source?.stateFIPS == "06"
            && f.references.layer?.source?.technology == 500 && f.references.layer?.source?.minimumDownloadMbps == 35
            && f.references.layer?.source?.environment == 1,
                     "in-flight request retains original state, radio, tier and environment despite subsequent edits")
        suite.expect(f.references.layer?.polygons.first?.first?.first == .init(latitude: 0, longitude: 0),
                     "in-flight extraction uses original visible map bounds rather than a later region")
        suite.expect(FixtureProtocol.requests.allSatisfy { $0.username == email && $0.token == token },
                     "in-flight request retains credential snapshot despite subsequent field edits")
    }

    @MainActor static func accessStates(_ suite: Suite, _ folder: URL, _ zip: Data) async throws {
        for locked in [false, true] {
            let f = try fixture(folder, saved: false)
            if locked { f.store.readError = .interactionRequired }
            FixtureProtocol.reset([])
            var loaded = 0
            f.model.loadCoverage(region: region) { loaded += 1 }
            suite.expect(!f.model.busy && f.model.needsAccess && loaded == 0 && FixtureProtocol.requests.isEmpty,
                         "\(locked ? "locked" : "missing") saved access requests recovery without remote request")
            suite.expect(f.store.reads == [false] && f.credentials.savedAccessState == (locked ? .locked : .missing),
                         "quiet credential probe distinguishes \(locked ? "locked" : "missing") and cannot trigger Keychain UI")
            suite.expect(f.model.message?.contains(locked ? "Unlock" : "Enter your FCC email") == true,
                         "\(locked ? "locked" : "missing") access explains the correct recovery")
        }
        let f = try fixture(folder, saved: false)
        f.credentials.username = email; f.credentials.token = token
        FixtureProtocol.reset(replies(zip))
        f.model.loadCoverage(region: region)
        try await idle(f.model)
        suite.expect(f.store.saves == 1 && !f.credentials.needsSave && f.references.layer != nil,
                     "first pasted access is saved once before the complete load")
        let savedFields = f.store.value?.data(using: .utf8).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: String] }
        suite.expect(f.store.reads.isEmpty && savedFields == ["username": email, "token": token],
                     "valid typed input is not replaced by a saved-access probe")
        FixtureProtocol.reset([.http(200, dates), .http(200, catalogue)])
        f.model.loadCoverage(region: region)
        try await idle(f.model)
        suite.expect(f.store.saves == 1 && f.model.reusedDownload, "unchanged first-run access is saved only once across loads")
        let blocked = try fixture(folder, saved: false)
        blocked.credentials.username = email; blocked.credentials.token = token; blocked.store.saveError = .unavailable
        FixtureProtocol.reset([])
        blocked.model.loadCoverage(region: region)
        suite.expect(blocked.model.needsAccess && !blocked.model.busy && FixtureProtocol.requests.isEmpty
            && blocked.store.saves == 1 && blocked.credentials.token == token,
                     "failed Keychain save retains typed access and blocks requests with recovery")
    }

    @MainActor static func failures(_ suite: Suite, _ folder: URL) async throws {
        let cases: [(String, [FixtureProtocol.Reply], Bool)] = [
            ("authentication", [.http(401, Data())], true),
            ("forbidden", [.http(403, Data())], true),
            ("server", [.http(500, Data())], false),
            ("no category", [.http(200, dates), .http(200, envelope([]))], false),
            ("invalid archive", [.http(200, dates), .http(200, catalogue), .zip(Data([0x50, 0x4b, 0x03, 0x04, 1]))], false)
        ]
        for (name, replies, rejected) in cases {
            let f = try fixture(folder, previous: true)
            let old = f.references.layer
            let file = f.root.appendingPathComponent("references/fcc-reference.json")
            let oldBytes = try Data(contentsOf: file)
            FixtureProtocol.reset(replies)
            var loaded = 0
            f.model.loadCoverage(region: region) { loaded += 1 }
            try await idle(f.model)
            suite.expect(loaded == 0 && f.references.layer == old && (try? Data(contentsOf: file)) == oldBytes,
                         "\(name) failure retains existing reference bytes and never invokes success")
            suite.expect(f.model.message != nil && f.model.loadedDate == nil && !f.model.busy,
                         "\(name) failure clears busy state with an actionable failure message")
            suite.expect(![f.model.message, f.credentials.message].compactMap { $0 }.joined().contains(token),
                         "\(name) failure message does not expose synthetic token")
            if rejected {
                suite.expect(f.credentials.token.isEmpty && f.credentials.savedAccessState == .invalid && f.model.needsAccess,
                             "\(name) rejection clears volatile token and requests account repair")
            } else {
                suite.expect(f.credentials.token == token && !f.model.needsAccess,
                             "\(name) failure does not discard valid access or ask for account repair")
            }
            suite.expect(f.store.deletes == 0 && f.store.saves == 0, "\(name) failure never silently deletes or rewrites saved access")
        }
    }

    @MainActor static func malformedDownloadRecovery(_ suite: Suite, _ folder: URL, _ zip: Data) async throws {
        let f = try fixture(folder, previous: true)
        let previous = f.references.layer
        let referenceFile = f.root.appendingPathComponent("references/fcc-reference.json")
        let previousBytes = try Data(contentsOf: referenceFile)
        var loaded = 0
        // The official client accepts the ZIP prefix, and the cache publishes
        // its hash. Actual archive extraction then detects structural corruption.
        FixtureProtocol.reset([.http(200, dates), .http(200, catalogue), .zip(Data([0x50, 0x4b, 0x03, 0x04, 1]))])
        f.model.loadCoverage(region: region) { loaded += 1 }
        try await idle(f.model)
        suite.expect(loaded == 0 && f.references.layer == previous && (try? Data(contentsOf: referenceFile)) == previousBytes,
                     "structurally malformed download leaves the previous reference bytes intact")
        let entriesAfterFailure = try FileManager.default.contentsOfDirectory(atPath: f.root.appendingPathComponent("cache").path)
        suite.expect(entriesAfterFailure.isEmpty, "malformed published ZIP is invalidated after extraction failure")

        FixtureProtocol.reset(replies(zip))
        f.model.loadCoverage(region: region) { loaded += 1 }
        try await idle(f.model)
        suite.expect(FixtureProtocol.requests.count == 3
            && FixtureProtocol.requests.last?.url.path == "/api/public/map/downloads/downloadFile/availability/12345/2",
                     "next explicit load downloads fresh bytes rather than reusing the malformed ZIP")
        suite.expect(loaded == 1 && !f.model.reusedDownload && f.model.loadedDate == date
            && f.references.layer?.modeledSignalDBm == [-95] && f.references.layer?.source?.origin == .officialAPI,
                     "explicit retry imports fresh valid GeoPackage and reports success exactly once")
        suite.expect(f.store.reads == [false] && f.store.saves == 0 && !f.model.needsAccess,
                     "archive recovery retains saved access without another prompt or credential rewrite")

        FixtureProtocol.reset([.http(200, dates), .http(200, catalogue)])
        f.model.loadCoverage(region: region) { loaded += 1 }
        try await idle(f.model)
        suite.expect(loaded == 2 && f.model.reusedDownload && FixtureProtocol.requests.count == 2,
                     "fresh valid replacement remains reusable on the following explicit load")
    }

    @MainActor static func cancellationAndOwnership(_ suite: Suite, _ folder: URL, _ zip: Data) async throws {
        for scenario in ["cancel metadata", "close workspace", "cancel download"] {
            let closing = scenario == "close workspace", downloading = scenario == "cancel download"
            let f = try fixture(folder, previous: true)
            let old = f.references.layer
            let file = f.root.appendingPathComponent("references/fcc-reference.json")
            let oldBytes = try Data(contentsOf: file)
            FixtureProtocol.reset(downloading ? [.http(200, dates), .http(200, catalogue), .holdZIP] : [.hold])
            var loaded = 0
            f.model.loadCoverage(region: region) { loaded += 1 }
            try await waitForRequests(downloading ? 3 : 1)
            if closing { f.model.close() } else { f.model.cancel() }
            try await idle(f.model)
            suite.expect(loaded == 0 && f.references.layer == old && (try? Data(contentsOf: file)) == oldBytes,
                         "\(scenario) preserves previous overlay with no success callback")
            suite.expect(f.model.message?.contains("cancelled") == true && FixtureProtocol.stopCount >= 1,
                         "\(scenario) cancels the underlying intercepted request")
            suite.expect(closing ? (f.credentials.username.isEmpty && f.credentials.token.isEmpty) : f.credentials.token == token,
                         "\(closing ? "closing workspace clears" : "cancel retains") volatile account fields")
            if downloading {
                let cacheFiles = try FileManager.default.contentsOfDirectory(atPath: f.root.appendingPathComponent("cache").path)
                suite.expect(cacheFiles.isEmpty, "cancelled download leaves no partial/cache publication")
            }
        }
        let f = try fixture(folder)
        FixtureProtocol.reset([.hold, .http(200, catalogue), .zip(zip)])
        var notifications = 0
        var viewObservation: AnyCancellable? = f.model.objectWillChange.sink { notifications += 1 }
        var loaded = 0
        f.model.loadCoverage(region: region) { loaded += 1 }
        try await waitForRequests(1)
        viewObservation?.cancel(); viewObservation = nil
        suite.expect(f.model.busy && FixtureProtocol.stopCount == 0,
                     "discarding view observation while workspace retains coordinator does not cancel loading")
        FixtureProtocol.releaseHeld(status: 200, data: dates)
        try await idle(f.model)
        suite.expect(loaded == 1 && f.references.layer != nil && FixtureProtocol.requests.count == 3,
                     "workspace-owned coordinator completes after the Data view observation is discarded")
        suite.expect(notifications > 0, "ownership test observed real coordinator state changes before view disposal")
    }

    @MainActor static func bounds(_ suite: Suite) {
        suite.expect(TMobileFCCCoverageModel.bounds(for: nil) == nil, "unknown map bounds cannot start extraction")
        suite.expect(TMobileFCCCoverageModel.bounds(for: .init(center: .init(latitude: 0, longitude: 179), span: .init(latitudeDelta: 2, longitudeDelta: 5))) == nil,
                     "date-line crossing bounds request a smaller map area")
        suite.expect(TMobileFCCCoverageModel.bounds(for: .init(center: .init(latitude: .nan, longitude: 0), span: .init(latitudeDelta: 2, longitudeDelta: 2))) == nil,
                     "nonfinite map bounds cannot start extraction")
        suite.expect(TMobileFCCCoverageModel.bounds(for: region) == .init(west: 4, south: 4, east: 6, north: 6),
                     "valid map bounds preserve visible area exactly")
    }

    @MainActor static func idle(_ model: TMobileFCCCoverageModel) async throws {
        for _ in 0..<1000 {
            if !model.busy { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        model.cancel(); throw FixtureFailure.timeout
    }
    static func waitForRequests(_ count: Int) async throws {
        for _ in 0..<1000 {
            if FixtureProtocol.requests.count >= count { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw FixtureFailure.timeout
    }

    static func syntheticZIP(folder: URL) throws -> Data {
        let file = folder.appendingPathComponent("synthetic.gpkg")
        var db: OpaquePointer?
        guard sqlite3_open_v2(file.path, &db, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE, nil) == SQLITE_OK,
              let db else { throw FixtureFailure.setup }
        defer { sqlite3_close(db) }
        func execute(_ sql: String) throws {
            guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw FixtureFailure.setup }
        }
        try execute("""
            PRAGMA application_id=1196444487;
            CREATE TABLE gpkg_contents(table_name TEXT PRIMARY KEY,data_type TEXT,srs_id INTEGER);
            CREATE TABLE gpkg_geometry_columns(table_name TEXT,column_name TEXT,geometry_type_name TEXT,srs_id INTEGER,z INTEGER,m INTEGER);
            CREATE TABLE fcc_raw(fid INTEGER PRIMARY KEY,geom BLOB,frn TEXT,providerid INTEGER,brandname TEXT,technology INTEGER,mindown REAL,minup REAL,minsignal INTEGER,environmnt INTEGER);
            INSERT INTO gpkg_contents VALUES('fcc_raw','features',4326);
            INSERT INTO gpkg_geometry_columns VALUES('fcc_raw','geom','POLYGON',4326,0,0);
            CREATE VIRTUAL TABLE rtree_fcc_raw_geom USING rtree(id,minx,maxx,miny,maxy);
            """)
        for (id, offset, signal) in [(1, 0.0, -95), (2, 20.0, -115)] {
            var geom = Data([0x47, 0x50, 0, 1]); geom.append32(4326)
            geom.append(1); geom.append32(3); geom.append32(1); geom.append32(5)
            for point in [[offset, offset], [offset + 10, offset], [offset + 10, offset + 10], [offset, offset + 10], [offset, offset]] {
                for value in point { geom.append64(value.bitPattern) }
            }
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, "INSERT INTO fcc_raw VALUES(?1,?2,'excluded-synthetic-frn',130403,'T-Mobile',500,35,3,?3,1)", -1, &stmt, nil) == SQLITE_OK,
                  let stmt else { throw FixtureFailure.setup }
            sqlite3_bind_int(stmt, 1, Int32(id)); sqlite3_bind_int(stmt, 3, Int32(signal))
            _ = geom.withUnsafeBytes { sqlite3_bind_blob(stmt, 2, $0.baseAddress, Int32(geom.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
            guard sqlite3_step(stmt) == SQLITE_DONE else { sqlite3_finalize(stmt); throw FixtureFailure.setup }
            sqlite3_finalize(stmt)
            try execute("INSERT INTO rtree_fcc_raw_geom VALUES(\(id),\(offset),\(offset + 10),\(offset),\(offset + 10))")
        }
        // SQLite has no outstanding statements or transaction; read committed file.
        let payload = try Data(contentsOf: file)
        let name = Data("synthetic.gpkg".utf8)
        let checksum = payload.withUnsafeBytes { UInt32(crc32(0, $0.bindMemory(to: Bytef.self).baseAddress, uInt(payload.count))) }
        var zip = Data()
        zip.append32(0x0403_4b50); zip.append16(20); zip.append16(0); zip.append16(0)
        zip.append16(0); zip.append16(0); zip.append32(checksum)
        zip.append32(UInt32(payload.count)); zip.append32(UInt32(payload.count)); zip.append16(UInt16(name.count)); zip.append16(0)
        zip.append(name); zip.append(payload)
        let offset = zip.count
        zip.append32(0x0201_4b50); zip.append16(0x0314); zip.append16(20); zip.append16(0); zip.append16(0)
        zip.append16(0); zip.append16(0); zip.append32(checksum); zip.append32(UInt32(payload.count)); zip.append32(UInt32(payload.count))
        zip.append16(UInt16(name.count)); zip.append16(0); zip.append16(0); zip.append16(0); zip.append16(0)
        zip.append32(0o100600 << 16); zip.append32(0); zip.append(name)
        let centralSize = zip.count - offset
        zip.append32(0x0605_4b50); zip.append16(0); zip.append16(0); zip.append16(1); zip.append16(1)
        zip.append32(UInt32(centralSize)); zip.append32(UInt32(offset)); zip.append16(0)
        return zip
    }
}

private enum FixtureFailure: Error { case setup, timeout }
private final class Suite {
    var checks = 0; var failures = 0
    func expect(_ condition: @autoclosure () -> Bool, _ label: String) {
        checks += 1
        if !condition() { failures += 1; print("FAIL: \(label)") }
    }
}
@MainActor private struct Fixture {
    let root: URL
    let store: CredentialMock
    let references: TMobileCoverageReferenceStore
    let credentials: TMobileFCCCredentialForm
    let model: TMobileFCCCoverageModel
}
private final class CredentialMock: ScopedCredentialStore {
    var value: String?; var readError: ScopedCredentialStoreError?; var saveError: ScopedCredentialStoreError?
    var reads: [Bool] = []; var saves = 0; var deletes = 0
    func read(scope: ScopedCredentialScope) throws -> String? { try read(scope: scope, allowingUserInteraction: true) }
    func read(scope: ScopedCredentialScope, allowingUserInteraction: Bool) throws -> String? {
        precondition(scope.service == "fixture.fcc.automatic" && scope.account == "https://broadbandmap.fcc.gov")
        reads.append(allowingUserInteraction)
        if let readError { throw readError }
        return value
    }
    func save(_ secret: String, scope: ScopedCredentialScope) throws {
        precondition(scope.service == "fixture.fcc.automatic" && scope.account == "https://broadbandmap.fcc.gov")
        saves += 1
        if let saveError { throw saveError }
        value = secret
    }
    func delete(scope: ScopedCredentialScope) throws { deletes += 1; value = nil }
}
private final class FixtureProtocol: URLProtocol {
    enum Reply { case http(Int, Data), zip(Data), hold, holdZIP }
    struct Request {
        let url: URL; let method: String?; let username: String?; let token: String?; let body: Data?
    }
    private static let lock = NSLock()
    private static var replies: [Reply] = []
    private static var captured: [Request] = []
    private static var held: FixtureProtocol?
    private static var stops = 0
    private static var unexpected = 0
    static var requests: [Request] { lock.withLock { captured } }
    static var stopCount: Int { lock.withLock { stops } }
    static var unexpectedRequests: Int { lock.withLock { unexpected } }
    static func reset(_ replies: [Reply]) {
        lock.withLock { self.replies = replies; captured = []; held = nil; stops = 0; unexpected = 0 }
    }
    static func releaseHeld(status: Int, data: Data) {
        let instance = lock.withLock { () -> FixtureProtocol? in defer { held = nil }; return held }
        instance?.respond(status: status, data: data, type: "application/json")
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let reply = Self.lock.withLock { () -> Reply? in
            Self.captured.append(.init(url: request.url!, method: request.httpMethod,
                username: request.value(forHTTPHeaderField: "username"), token: request.value(forHTTPHeaderField: "hash_value"), body: request.httpBody))
            guard !Self.replies.isEmpty else { Self.unexpected += 1; return nil }
            let value = Self.replies.removeFirst()
            if case .hold = value { Self.held = self }
            return value
        }
        guard let reply else { client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL)); return }
        switch reply {
        case let .http(status, data): respond(status: status, data: data, type: "application/json")
        case let .zip(data): respond(status: 200, data: data, type: "application/zip")
        case .hold: break
        case .holdZIP:
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                headerFields: ["Content-Type": "application/zip"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data([0x50, 0x4b, 0x03, 0x04, 0x20]))
        }
    }
    private func respond(status: Int, data: Data, type: String) {
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil,
            headerFields: ["Content-Type": type, "Content-Length": String(data.count)])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {
        Self.lock.withLock { Self.stops += 1; if Self.held === self { Self.held = nil } }
    }
}
private extension Data {
    mutating func append16(_ value: UInt16) { append(UInt8(truncatingIfNeeded: value)); append(UInt8(truncatingIfNeeded: value >> 8)) }
    mutating func append32(_ value: UInt32) { append16(UInt16(truncatingIfNeeded: value)); append16(UInt16(truncatingIfNeeded: value >> 16)) }
    mutating func append64(_ value: UInt64) { append32(UInt32(truncatingIfNeeded: value)); append32(UInt32(truncatingIfNeeded: value >> 32)) }
}
