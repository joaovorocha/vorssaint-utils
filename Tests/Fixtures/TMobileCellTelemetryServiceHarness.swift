// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Foundation

final class TestSuite {
    var checks = 0
    var failures: [String] = []
    func expect(_ condition: Bool, _ message: @autoclosure () -> String) {
        checks += 1
        if !condition { failures.append(message()) }
    }
}

@main struct TMobileCellTelemetryServiceHarness {
    @MainActor static func main() async {
        let suite = TestSuite()
        TMobileCellTelemetryTests.run(suite)
        await lifecycle(suite)
        await errors(suite)
        await cancellation(suite)
        await bounds(suite)
        if suite.failures.isEmpty {
            print("PASS: \(suite.checks) serving-cell backend checks; every URL intercepted; no live router or preferences accessed")
        } else { suite.failures.forEach { print("FAIL: \($0)") }; exit(1) }
    }

    @MainActor private static func service(now: @escaping () -> Date = Date.init) -> TMobileCellTelemetryService {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CellProtocol.self]
        configuration.httpAdditionalHeaders = ["Authorization": "fixture-must-remove", "Cookie": "fixture-must-remove"]
        return TMobileCellTelemetryService(configuration: configuration, now: now)
    }
    private static var login: CellProtocol.Reply { .http(200, Data(#"{"auth":{"token":"fixture.token"}}"#.utf8)) }
    private static var cell: CellProtocol.Reply { .http(200, Data(TMobileCellTelemetryTests.fixture.utf8)) }
    @MainActor private static func connect(_ service: TMobileCellTelemetryService) async {
        await service.connect(baseURL: "http://192.168.12.1", username: "fixture-admin", password: "fixture-admin-key")
    }

    @MainActor private static func lifecycle(_ suite: TestSuite) async {
        CellProtocol.reset([])
        var clock = Date(timeIntervalSince1970: 1_000)
        let service = service(now: { clock })
        suite.expect(service.phase == .signedOut && service.report == nil && service.fetchedAt == nil
                     && !service.canRefresh && CellProtocol.requests.isEmpty,
                     "constructing the private telemetry session never starts a request")
        await service.refresh()
        suite.expect(CellProtocol.requests.isEmpty, "manual refresh without sign-in never requests telemetry")
        CellProtocol.append([login, cell])
        await connect(service)
        suite.expect(service.phase == .ready && service.report?.fiveG?.signal.bands == ["n41"]
                     && service.fetchedAt == clock && service.canRefresh,
                     "explicit sign-in publishes only the sanitized serving-cell report and fresh local time")
        let requests = CellProtocol.requests
        suite.expect(requests.count == 2 && requests[0].method == "POST" && requests[0].url.path == "/TMI/v1/auth/login"
                     && requests[0].url.query == nil && requests[1].method == "GET"
                     && requests[1].url.path == "/TMI/v1/network/telemetry" && requests[1].url.query == "get=cell",
                     "only administrator login POST and serving-cell GET are requested")
        suite.expect(requests[0].authorization == nil && requests[0].cookie == nil
                     && requests[1].authorization == "Bearer fixture.token" && requests[1].cookie == nil,
                     "inherited headers are removed and the in-memory bearer reaches only telemetry")
        suite.expect(requests[1].body.isEmpty && requests.allSatisfy { $0.timeout == 15 },
                     "read-only telemetry has no body and every request has a bounded timeout")
        let body = try? JSONSerialization.jsonObject(with: requests[0].body) as? [String: Any]
        suite.expect(Set(body?.keys.map { $0 } ?? []) == ["username", "password"],
                     "only the explicit human-entry fields form the transient login body")
        clock = clock.addingTimeInterval(30)
        CellProtocol.append([cell]); await service.refresh()
        suite.expect(CellProtocol.requests.count == 3 && service.phase == .ready && service.fetchedAt == clock,
                     "manual refresh reuses the session bearer for exactly one new GET")
        suite.expect(CellProtocol.requests.filter { $0.method != "GET" }.count == 1,
                     "refresh never writes configuration, restarts the router or silently logs in again")
        service.disconnect()
        suite.expect(service.phase == .signedOut && service.report == nil && service.fetchedAt == nil
                     && service.message == nil && !service.canRefresh,
                     "disconnect clears all published serving details, timestamps and session authority")
        await service.refresh()
        suite.expect(CellProtocol.requests.count == 3, "a cleared session cannot send its former bearer again")
    }

    @MainActor private static func errors(_ suite: TestSuite) async {
        for status in [401, 403] {
            CellProtocol.reset([login, cell, .http(status, Data("fixture-sensitive-error".utf8))])
            let service = service(); await connect(service); await service.refresh()
            suite.expect(service.phase == .failed && !service.canRefresh && service.report == nil && service.fetchedAt == nil,
                         "expired or denied bearer clears the authenticated session and old report")
            await service.refresh()
            suite.expect(CellProtocol.requests.count == 3 && service.message?.contains("Sign in again") == true
                         && service.message?.contains("fixture-sensitive-error") == false,
                         "expired authentication never replays login or retains raw server errors")
            service.disconnect()
        }
        for failure in [CellProtocol.Reply.http(408, Data()), .http(500, Data()), .failure(.timedOut)] {
            CellProtocol.reset([login, cell, failure, cell])
            let service = service(); await connect(service); await service.refresh()
            suite.expect(service.phase == .failed && service.canRefresh && service.report == nil && service.fetchedAt == nil
                         && CellProtocol.requests.count == 3,
                         "transient GET failure clears stale report but does not retry automatically")
            await service.refresh()
            suite.expect(service.phase == .ready && CellProtocol.requests.count == 4
                         && CellProtocol.requests.last?.method == "GET",
                         "a human-requested retry uses one GET with the still-current session")
            service.disconnect()
        }
        CellProtocol.reset([login, .http(200, Data(#"{"cell":{"gps":{"latitude":1}}}"#.utf8))])
        let unsupported = service(); await connect(unsupported)
        suite.expect(unsupported.phase == .failed && unsupported.report == nil && !unsupported.canRefresh
                     && unsupported.message?.contains("unsupported") == true,
                     "unsupported telemetry during sign-in clears the new session rather than publishing private fallback data")
        unsupported.disconnect()
    }

    @MainActor private static func cancellation(_ suite: TestSuite) async {
        CellProtocol.reset([.hold])
        let authenticating = service()
        let auth = Task { await connect(authenticating) }
        await wait { CellProtocol.requests.count == 1 }
        await connect(authenticating)
        suite.expect(CellProtocol.requests.count == 1 && authenticating.phase == .connecting,
                     "a second sign-in cannot create a parallel request while the first is pending")
        authenticating.disconnect(); await auth.value
        suite.expect(authenticating.phase == .signedOut && authenticating.report == nil && !authenticating.canRefresh,
                     "disconnect during login fences late completion and clears session state")

        CellProtocol.reset([login, .hold])
        let loading = service(); let load = Task { await connect(loading) }
        await wait { CellProtocol.requests.count == 2 }
        loading.disconnect(); await load.value
        suite.expect(loading.phase == .signedOut && loading.report == nil && loading.fetchedAt == nil,
                     "disconnect during telemetry cancels the old generation without publishing a late report")
        CellProtocol.append([login, cell]); await connect(loading)
        suite.expect(loading.phase == .ready && loading.report != nil && CellProtocol.requests.count == 4,
                     "a new explicit sign-in can start after a cancelled generation is retired")
        loading.disconnect()

        CellProtocol.reset([login, cell, .hold])
        let refreshing = service(); await connect(refreshing)
        let refresh = Task { await refreshing.refresh() }
        await wait { CellProtocol.requests.count == 3 }
        suite.expect(refreshing.phase == .loading && refreshing.report == nil && refreshing.fetchedAt == nil,
                     "an in-progress manual read cannot display an older report as newly fetched")
        refresh.cancel(); await refresh.value
        suite.expect(refreshing.phase == .failed && !refreshing.canRefresh && refreshing.report == nil,
                     "task cancellation closes bearer authority instead of silently retrying")
        refreshing.disconnect()
    }

    @MainActor private static func bounds(_ suite: TestSuite) async {
        for address in ["http://8.8.8.8", "http://192.168.12.1/TMI", "http://192.168.12.1@8.8.8.8"] {
            CellProtocol.reset([])
            let service = service()
            await service.connect(baseURL: address, username: "fixture", password: "fixture")
            suite.expect(service.phase == .failed && CellProtocol.requests.isEmpty,
                         "invalid or public origins reject before any administrator input can be sent")
        }
        for credentials in [("", "fixture"), ("fixture\nname", "fixture"), ("fixture", ""),
                            (String(repeating: "a", count: 129), "fixture"), ("fixture", String(repeating: "x", count: 1025))] {
            CellProtocol.reset([])
            let service = service()
            await service.connect(baseURL: "http://192.168.12.1", username: credentials.0, password: credentials.1)
            suite.expect(service.phase == .failed && CellProtocol.requests.isEmpty,
                         "empty, overlong or malformed administrator input rejects before a request")
        }
        CellProtocol.reset([.http(200, Data(#"{"auth":{"token":"not a header value"}}"#.utf8))])
        let badToken = service(); await connect(badToken)
        suite.expect(badToken.phase == .failed && !badToken.canRefresh && CellProtocol.requests.count == 1,
                     "malformed login token cannot send an authenticated request")
        badToken.disconnect()
        for reply in [CellProtocol.Reply.http(302, Data("{}".utf8)), .http(401, Data("fixture-sensitive-error".utf8)),
                      .http(200, Data(repeating: 65, count: TMobileCellTelemetrySupport.maximumResponseBytes + 1)),
                      .declared(TMobileCellTelemetrySupport.maximumResponseBytes + 1)] {
            CellProtocol.reset([reply])
            let service = service(); await connect(service)
            suite.expect(service.phase == .failed && CellProtocol.requests.count == 1
                         && service.report == nil && !service.canRefresh,
                         "redirects, auth rejection and oversized responses cannot create another request or publish data")
            suite.expect(service.message?.contains("fixture-sensitive-error") == false,
                         "raw authentication and transport response bodies never enter error text")
            service.disconnect()
        }
        CellProtocol.reset([login, cell])
        let origin = service()
        await origin.connect(baseURL: "https://10.0.0.1:8443", username: "fixture", password: "fixture")
        suite.expect(CellProtocol.requests.count == 2 && CellProtocol.requests.allSatisfy {
            $0.url.scheme == "https" && $0.url.host == "10.0.0.1" && $0.url.port == 8443
        }, "both allowed endpoints stay on the exact validated private origin")
        origin.disconnect()
    }

    @MainActor private static func wait(_ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(3)
        while !condition(), Date() < deadline { try? await Task.sleep(nanoseconds: 5_000_000) }
    }
}

/// Intercepts every URL, including unexpected URLs. Fixture bodies remain
/// private to assertions and are never printed; this harness cannot go live.
private final class CellProtocol: URLProtocol {
    enum Reply { case http(Int, Data), declared(Int), failure(URLError.Code), hold }
    struct Request {
        let method: String
        let url: URL
        let authorization: String?
        let cookie: String?
        let body: Data
        let timeout: TimeInterval
    }
    private static let lock = NSLock()
    private static var replies: [Reply] = []
    private static var captured: [Request] = []
    static var requests: [Request] { lock.withLock { captured } }
    static func reset(_ replies: [Reply]) { lock.withLock { self.replies = replies; captured = [] } }
    static func append(_ replies: [Reply]) { lock.withLock { self.replies += replies } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var body = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }; body.append(buffer, count: count)
            }
        }
        let reply = Self.lock.withLock { () -> Reply in
            Self.captured.append(.init(method: request.httpMethod ?? "", url: request.url!,
                                       authorization: request.value(forHTTPHeaderField: "Authorization"),
                                       cookie: request.value(forHTTPHeaderField: "Cookie"), body: body,
                                       timeout: request.timeoutInterval))
            return Self.replies.isEmpty ? .failure(.unsupportedURL) : Self.replies.removeFirst()
        }
        switch reply {
        case let .http(status, data):
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil,
                                           headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        case let .declared(count):
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                                           headerFields: ["Content-Length": String(count)])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
        case let .failure(code): client?.urlProtocol(self, didFailWithError: URLError(code))
        case .hold: break
        }
    }
    override func stopLoading() {}
}
