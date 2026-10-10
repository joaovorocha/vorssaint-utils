// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint
import Foundation

private final class FCCSuite {
    var checks = 0
    var failures: [String] = []
    func expect(_ condition: Bool, _ message: String) {
        checks += 1
        if !condition { failures.append(message) }
    }
    func failure(_ expected: FCCCoverageFailure, _ action: () async throws -> Void, _ message: String) async {
        do { try await action(); expect(false, message) }
        catch {
            expect((error as? FCCCoverageFailure) == expected, message)
            expect(!error.localizedDescription.contains("fixture-token") && !error.localizedDescription.contains("example.invalid"),
                   "errors never expose fixture credentials or raw provider error text")
        }
    }
}

@main private struct FCCCoverageClientTests {
    static let credentials = FCCCoverageCredentials(username: "fcc-fixture@example.invalid", token: "fixture-token")
    static func envelope(_ rows: [[String: Any]], status: Any = 200, count: Int? = nil) -> Data {
        try! JSONSerialization.data(withJSONObject: ["status_code": status, "status": "successful",
                                                      "result_count": count ?? rows.count, "data": rows])
    }
    static var dates: Data { envelope([
        ["data_type": "availability", "as_of_date": "2024-12-31"],
        ["data_type": "availability", "as_of_date": "2025-12-31"],
        ["data_type": "challenge", "as_of_date": "2026-07-31"]
    ]) }
    static func row(_ id: Any = "12345", state: String = "06", provider: Any = "130403", code: Any = "500",
                    tier: Any = "35/3", geometry: String = "Raw Coverage") -> [String: Any] {
        ["file_id": id, "category": "Provider", "subcategory": geometry, "technology_type": "Mobile Broadband",
         "technology_code": code, "technology_code_desc": "fixture", "speed_tier": tier,
         "state_fips": state, "state_name": "fixture", "provider_id": provider, "provider_name": "T-Mobile USA, Inc.",
         "file_type": "gis", "file_name": "bdc_fixture_\(id)", "record_count": "100"]
    }
    static var catalogueData: Data { envelope([
        row(), row("12346", code: 400, tier: NSNull()),
        row("12347", tier: "7/1", geometry: "Hexagon Coverage"),
        row("12348", state: "32"), row("12349", provider: "999999"), row("12350", code: "300", tier: NSNull())
    ]) }
    static func client(limiter: FCCCoverageRequestLimiter = .init(maximumRequests: 1000)) -> FCCCoverageClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FCCFixtureProtocol.self]
        configuration.httpAdditionalHeaders = ["Authorization": "fixture-inherited", "Cookie": "fixture-inherited",
                                                 "username": "fixture-old", "hash_value": "fixture-old"]
        return FCCCoverageClient(configuration: configuration, limiter: limiter)
    }
    static func main() async {
        let suite = FCCSuite()
        models(suite)
        await lifecycle(suite)
        await errors(suite)
        await downloads(suite)
        await cancellation(suite)
        await rateLimit(suite)
        if suite.failures.isEmpty {
            print("PASS: \(suite.checks) FCC client checks; every URL intercepted; no live FCC account, location, Keychain or coverage data used")
        } else { suite.failures.forEach { print("FAIL: \($0)") }; exit(1) }
    }
    static func models(_ suite: FCCSuite) {
        suite.expect(FCCCoverageState.all.count == 57 && Set(FCCCoverageState.all.map(\.fips)).count == 57,
                     "state catalogue includes all 50 states, DC and six US territory choices without duplicates")
        suite.expect(FCCCoverageState.california.fips == "06" && FCCCoverageState.california.abbreviation == "CA",
                     "California is the default and preserves leading-zero FIPS")
        suite.expect(credentials.isValid && String(describing: credentials) == "FCCCoverageCredentials(redacted)"
                     && String(reflecting: credentials) == "FCCCoverageCredentials(redacted)", "credential descriptions are redacted")
        suite.expect(!FCCCoverageCredentials(username: "x\r\nInjected: value@example.invalid", token: "ok").isValid
                     && !FCCCoverageCredentials(username: "fcc@example.invalid", token: "a\nb").isValid,
                     "header injection is rejected")
        suite.expect(FCCCoverageSupport.validDate("2024-02-29") && !FCCCoverageSupport.validDate("2025-02-29")
                     && !FCCCoverageSupport.validDate("2025-2-01") && !FCCCoverageSupport.validDate("../../2025"),
                     "date paths require exact valid Gregorian ISO dates")
        suite.expect((try? FCCCoverageSupport.latestAvailabilityDate(dates)) == "2025-12-31",
                     "latest date is selected only from availability entries")
        let catalogue = try? FCCCoverageSupport.catalogue(catalogueData, asOfDate: "2025-12-31", state: .california)
        suite.expect(catalogue?.files.count == 3 && catalogue?.files.allSatisfy { $0.stateFIPS == "06" && $0.providerID == "130403" } == true,
                     "catalogue filters state and T-Mobile, skips 3G, preserves raw and H3 choices")
        suite.expect(catalogue?.files.first?.technology == .lte && catalogue?.files.first?.speedTier == nil,
                     "LTE has no invented 5G speed tier")
        suite.expect((try? FCCCoverageSupport.catalogue(catalogueData, asOfDate: "2025-12-31",
                      state: FCCCoverageState.all.first { $0.fips == "78" }!))?.files.isEmpty == true,
                     "a state without matching files yields a successful empty catalogue")
        for bad in [envelope([row(true)]), envelope([row("12345", tier: "100/10")]), envelope([row(), row()]),
                    envelope([row()], count: 5), envelope([row()], status: true)] {
            suite.expect((try? FCCCoverageSupport.catalogue(bad, asOfDate: "2025-12-31", state: .california)) == nil,
                         "malformed identifiers, tiers, duplicates, counts and booleans are rejected")
        }
        var unsafe = row(); unsafe["file_name"] = "../../fixture.zip"
        suite.expect((try? FCCCoverageSupport.catalogue(envelope([unsafe]), asOfDate: "2025-12-31", state: .california)) == nil,
                     "untrusted filenames cannot become filesystem paths")
        var nested: Any = "fixture"
        for _ in 0..<33 { nested = ["ignored": nested] }
        let deep = try! JSONSerialization.data(withJSONObject: ["status_code": 200, "status": "successful",
                                                                "result_count": 0, "data": [], "ignored": nested])
        suite.expect((try? FCCCoverageSupport.catalogue(deep, asOfDate: "2025-12-31", state: .california)) == nil,
                     "excessively nested ignored JSON is rejected before object parsing")
    }
    static func lifecycle(_ suite: FCCSuite) async {
        FCCFixtureProtocol.reset([.http(200, dates), .http(200, catalogueData)])
        let instance = client()
        suite.expect(FCCFixtureProtocol.requests.isEmpty, "client construction does not access the network")
        do {
            let catalogue = try await instance.checkLatestMobileCoverage(credentials: credentials)
            suite.expect(catalogue.asOfDate == "2025-12-31" && catalogue.state == .california && catalogue.files.count == 3,
                         "one explicit check discovers latest vintage and filtered California files")
        } catch { suite.expect(false, "explicit check succeeds with documented fixtures") }
        let requests = FCCFixtureProtocol.requests
        suite.expect(requests.count == 2 && requests[0].url.path == "/api/public/map/listAsOfDates"
                     && requests[1].url.path == "/api/public/map/downloads/listAvailabilityData/2025-12-31",
                     "check performs exactly two documented GETs without polling, retries or invented routes")
        suite.expect(requests.allSatisfy { $0.httpMethod == "GET" && $0.url.scheme == "https" && $0.url.host == "broadbandmap.fcc.gov"
            && $0.username == "fcc-fixture@example.invalid" && $0.token == "fixture-token" && $0.authorization == nil
            && $0.cookie == nil && $0.body == nil && !$0.url.absoluteString.contains("fixture-token") },
                     "only canonical HTTPS request headers carry credentials; inherited auth and cookies are removed")
        let query = URLComponents(url: requests[1].url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        suite.expect(Set(query.map(\.name)) == ["category", "technology_type"]
                     && query.first(where: { $0.name == "technology_type" })?.value == "Mobile Broadband",
                     "server query contains only documented catalogue filters, with state/provider filtered locally")
        FCCFixtureProtocol.reset([])
        await suite.failure(.invalidInput, { _ = try await client().checkLatestMobileCoverage(stateFIPS: "99", credentials: credentials) },
                            "unknown state is rejected before network access")
        await suite.failure(.invalidInput, { _ = try await client().checkLatestMobileCoverage(credentials: .init(username: "", token: "")) },
                            "missing credentials are rejected before network access")
        suite.expect(FCCFixtureProtocol.requests.isEmpty, "invalid actions perform zero requests")
    }
    static func errors(_ suite: FCCSuite) async {
        let cases: [(FCCFixtureProtocol.Reply, FCCCoverageFailure)] = [
            (.http(401, Data("fixture-token".utf8)), .authentication),
            (.http(403, Data("fixture-token".utf8)), .forbidden),
            (.http(429, Data("fixture-token".utf8)), .rateLimited),
            (.http(500, Data()), .unavailable), (.http(302, Data()), .invalidResponse),
            (.failure(.timedOut), .network), (.http(200, Data("fixture-token".utf8)), .invalidResponse),
            (.http(200, envelope([], status: 401)), .authentication),
            (.http(200, dates, type: "text/html"), .invalidResponse),
            (.http(200, dates, declared: FCCCoverageSupport.maximumMetadataBytes + 1), .tooLarge),
            (.http(200, Data(repeating: 0x20, count: FCCCoverageSupport.maximumMetadataBytes + 1)), .tooLarge),
            (.http(200, dates, declared: dates.count + 1), .invalidResponse),
            (.wrongURL(dates), .invalidResponse), (.redirect, .invalidResponse)
        ]
        for (reply, expected) in cases {
            FCCFixtureProtocol.reset([reply])
            await suite.failure(expected, { _ = try await client().checkLatestMobileCoverage(credentials: credentials) },
                                "HTTP, network, type, size, length, body, URL and redirect failures have safe typed errors")
            suite.expect(FCCFixtureProtocol.requests.count == 1, "failed requests never retry or contact another host")
        }
        FCCFixtureProtocol.reset([.http(200, dates, declared: 1, encoding: "gzip"), .http(200, catalogueData)])
        do { _ = try await client().checkLatestMobileCoverage(credentials: credentials)
            suite.expect(true, "decompressed metadata is not compared with compressed wire Content-Length")
        } catch { suite.expect(false, "decompressed metadata is not compared with compressed wire Content-Length") }
    }
    static func downloads(_ suite: FCCSuite) async {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("fcc-fixture-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("selected.zip")
        let file = try! FCCCoverageSupport.catalogue(envelope([row()]), asOfDate: "2025-12-31", state: .california).files[0]
        let zip = Data([0x50, 0x4b, 0x03, 0x04, 0x10, 0x20])
        FCCFixtureProtocol.reset([.http(200, zip, type: "application/zip")])
        do {
            let saved = try await client().downloadGeoPackage(file: file, to: destination, credentials: credentials)
            suite.expect(saved == destination && (try? Data(contentsOf: saved)) == zip, "selected ZIP streams to the chosen destination")
        } catch { suite.expect(false, "selected ZIP streams to the chosen destination") }
        suite.expect(FCCFixtureProtocol.requests.first?.url.path == "/api/public/map/downloads/downloadFile/availability/12345/2",
                     "GeoPackage ZIP uses selected catalogue ID and documented format 2")
        await suite.failure(.destinationExists, { _ = try await client().downloadGeoPackage(file: file, to: destination, credentials: credentials) },
                            "existing destination is never silently overwritten")
        suite.expect((try? Data(contentsOf: destination)) == zip && FCCFixtureProtocol.requests.count == 1,
                     "existing-file rejection preserves bytes and performs no request")
        try! FileManager.default.removeItem(at: destination)
        FCCFixtureProtocol.reset([])
        let hexagons = try! FCCCoverageSupport.catalogue(envelope([row(geometry: "Hexagon Coverage")]),
                                                        asOfDate: "2025-12-31", state: .california).files[0]
        await suite.failure(.invalidInput, { _ = try await client().downloadGeoPackage(file: hexagons, to: destination, credentials: credentials) },
                            "current native importer accepts raw coverage only")
        suite.expect(FCCFixtureProtocol.requests.isEmpty, "unsupported geometry performs no request")
        let cases: [(FCCFixtureProtocol.Reply, FCCCoverageFailure)] = [
            (.http(200, Data("HTML".utf8), type: "application/zip"), .invalidResponse),
            (.http(200, zip, type: "text/html"), .invalidResponse),
            (.http(200, zip, type: "application/zip", declared: FCCCoverageSupport.maximumDownloadBytes + 1), .tooLarge),
            (.http(200, zip, type: "application/zip", declared: zip.count + 1), .invalidResponse),
            (.http(200, Data([0x50, 0x4b]), type: "application/zip"), .invalidResponse),
            (.failure(.networkConnectionLost), .network), (.redirect, .invalidResponse)
        ]
        for (reply, expected) in cases {
            FCCFixtureProtocol.reset([reply])
            await suite.failure(expected, { _ = try await client().downloadGeoPackage(file: file, to: destination, credentials: credentials) },
                                "invalid, oversized, truncated, disconnected or redirected ZIP downloads fail safely")
            suite.expect((try? FileManager.default.contentsOfDirectory(atPath: directory.path))?.isEmpty == true,
                         "failed downloads leave neither a destination file nor a partial file")
        }
    }
    static func cancellation(_ suite: FCCSuite) async {
        FCCFixtureProtocol.reset([.hold])
        let instance = client()
        let task = Task { try await instance.checkLatestMobileCoverage(credentials: credentials) }
        await wait { FCCFixtureProtocol.requests.count == 1 }
        task.cancel()
        await suite.failure(.cancelled, { _ = try await task.value }, "Task cancellation cancels a pending metadata request")
        suite.expect(FCCFixtureProtocol.requests.count == 1, "cancelled check cannot start the second catalogue request")
        FCCFixtureProtocol.reset([.http(200, dates), .http(200, catalogueData)])
        do { _ = try await instance.checkLatestMobileCoverage(credentials: credentials)
            suite.expect(true, "client supports a new explicit action after cancellation")
        } catch { suite.expect(false, "client supports a new explicit action after cancellation") }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("fcc-cancel-fixture-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = try! FCCCoverageSupport.catalogue(envelope([row()]), asOfDate: "2025-12-31", state: .california).files[0]
        FCCFixtureProtocol.reset([.holdZIP])
        let downloading = Task { try await instance.downloadGeoPackage(file: file, to: directory.appendingPathComponent("selected.zip"), credentials: credentials) }
        await wait {
            guard let partial = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey]))?.first else { return false }
            return ((try? partial.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0) >= 4
        }
        downloading.cancel()
        await suite.failure(.cancelled, { _ = try await downloading.value }, "Task cancellation cancels a pending ZIP download")
        suite.expect((try? FileManager.default.contentsOfDirectory(atPath: directory.path))?.isEmpty == true,
                     "cancelling a ZIP download removes its partial file")
    }
    static func rateLimit(_ suite: FCCSuite) async {
        let clock = FCCFixtureClock()
        let limiter = FCCCoverageRequestLimiter(now: { clock.time }, sleep: { clock.advance($0) })
        do {
            for _ in 0..<10 { try await limiter.acquire() }
            suite.expect(clock.waits.isEmpty, "first ten calls fit the documented sliding-minute allowance")
            try await limiter.acquire()
            suite.expect(clock.waits.count == 1 && (clock.waits.first ?? 0) >= 60,
                         "eleventh reservation waits until the oldest request leaves the minute window")
        } catch { suite.expect(false, "deterministic rate-limit reservations complete") }
        let sharedClock = FCCFixtureClock()
        let sharedLimiter = FCCCoverageRequestLimiter(now: { sharedClock.time }, sleep: { sharedClock.advance($0) })
        let firstClient = client(limiter: sharedLimiter)
        let secondClient = client(limiter: sharedLimiter)
        FCCFixtureProtocol.reset((0..<6).flatMap { _ in [FCCFixtureProtocol.Reply.http(200, dates), .http(200, catalogueData)] })
        do {
            for index in 0..<6 {
                _ = try await (index % 2 == 0 ? firstClient : secondClient).checkLatestMobileCoverage(credentials: credentials)
            }
            suite.expect(FCCFixtureProtocol.requests.count == 12 && sharedClock.waits.count == 1
                         && (sharedClock.waits.first ?? 0) >= 60,
                         "multiple clients share the same budget and both discovery requests consume one reservation")
        } catch { suite.expect(false, "multiple clients share the same budget") }
        let blocked = FCCCoverageRequestLimiter(maximumRequests: 1)
        try! await blocked.acquire()
        let pending = Task { try await blocked.acquire() }
        pending.cancel()
        do { try await pending.value; suite.expect(false, "rate-limit waiting is cancellable") }
        catch { suite.expect(error is CancellationError, "rate-limit waiting is cancellable") }
    }
    static func wait(_ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(3)
        while !condition(), Date() < deadline { try? await Task.sleep(nanoseconds: 2_000_000) }
    }
}

private final class FCCFixtureClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: TimeInterval = 1000
    private var delays: [TimeInterval] = []
    var time: TimeInterval { lock.withLock { value } }
    var waits: [TimeInterval] { lock.withLock { delays } }
    func advance(_ delay: TimeInterval) { lock.withLock { delays.append(delay); value += delay } }
}

/// Every URL is intercepted, including unexpected URLs. Only synthetic request
/// details are retained privately for assertions; credentials are never printed.
private final class FCCFixtureProtocol: URLProtocol {
    enum Reply {
        case http(Int, Data, type: String = "application/json", declared: Int? = nil, encoding: String? = nil)
        case failure(URLError.Code), wrongURL(Data), redirect, hold, holdZIP
    }
    struct Request {
        let url: URL; let httpMethod: String?; let username: String?; let token: String?
        let authorization: String?; let cookie: String?; let body: Data?
    }
    private static let lock = NSLock()
    private static var replies: [Reply] = []
    private static var captured: [Request] = []
    static var requests: [Request] { lock.withLock { captured } }
    static func reset(_ replies: [Reply]) { lock.withLock { self.replies = replies; captured = [] } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let reply = Self.lock.withLock { () -> Reply in
            Self.captured.append(.init(url: request.url!, httpMethod: request.httpMethod,
                                      username: request.value(forHTTPHeaderField: "username"), token: request.value(forHTTPHeaderField: "hash_value"),
                                      authorization: request.value(forHTTPHeaderField: "Authorization"), cookie: request.value(forHTTPHeaderField: "Cookie"),
                                      body: request.httpBody))
            return Self.replies.isEmpty ? .failure(.unsupportedURL) : Self.replies.removeFirst()
        }
        switch reply {
        case let .http(status, data, type, declared, encoding):
            var headers = ["Content-Type": type]
            if let declared { headers["Content-Length"] = String(declared) }
            if let encoding { headers["Content-Encoding"] = encoding }
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(data.prefix(3)))
            client?.urlProtocol(self, didLoad: Data(data.dropFirst(3)))
            client?.urlProtocolDidFinishLoading(self)
        case let .wrongURL(data):
            let response = HTTPURLResponse(url: URL(string: "https://example.invalid/fixture")!, statusCode: 200,
                                           httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
        case .redirect:
            let response = HTTPURLResponse(url: request.url!, statusCode: 302, httpVersion: nil,
                                           headerFields: ["Location": "https://example.invalid/fixture"] )!
            client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: URL(string: "https://example.invalid/fixture")!), redirectResponse: response)
            client?.urlProtocolDidFinishLoading(self)
        case let .failure(code): client?.urlProtocol(self, didFailWithError: URLError(code))
        case .hold: break
        case .holdZIP:
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                                           headerFields: ["Content-Type": "application/zip"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data([0x50, 0x4b, 0x03, 0x04, 0x20]))
        }
    }
    override func stopLoading() {}
}
