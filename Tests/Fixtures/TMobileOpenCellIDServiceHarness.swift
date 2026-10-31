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

@main struct TMobileOpenCellIDServiceHarness {
    @MainActor static func main() async {
        let suite = TestSuite()
        TMobileOpenCellIDTests.run(suite)
        await lifecycle(suite)
        await errors(suite)
        await cancellation(suite)
        await areaLifecycle(suite)
        await areaErrors(suite)
        await areaCancellation(suite)
        if suite.failures.isEmpty {
            print("PASS: \(suite.checks) OpenCellID checks; every URL intercepted; no live provider, key store or history accessed")
        } else { suite.failures.forEach { print("FAIL: \($0)") }; exit(1) }
    }
    private static var cell: OpenCellProtocol.Reply { .http(200, Data(TMobileOpenCellIDTests.fixture.utf8)) }
    private static var areaCells: OpenCellProtocol.Reply { .http(200, Data(TMobileOpenCellIDTests.areaFixture.utf8)) }
    @MainActor private static func service() -> TMobileOpenCellIDService {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OpenCellProtocol.self]
        configuration.httpAdditionalHeaders = ["Authorization": "fixture-must-remove", "Cookie": "fixture-must-remove"]
        return TMobileOpenCellIDService(configuration: configuration)
    }
    @MainActor private static func lookup(_ service: TMobileOpenCellIDService, confirmed: Bool = true) async {
        await service.lookup(identity: TMobileOpenCellIDTests.identity, token: "fixture+a&b=c", confirmedFullIdentity: confirmed)
    }
    @MainActor private static func search(_ service: TMobileOpenCellIDService, approved: Bool = true,
                                          radio: TMobileOpenCellIDRadio = .lte, token: String = "fixture+a&b=c") async {
        await service.search(area: TMobileOpenCellIDTests.area, radio: radio, token: token, approvedAreaSharing: approved)
    }
    @MainActor private static func lifecycle(_ suite: TestSuite) async {
        OpenCellProtocol.reset([cell])
        let service = service()
        suite.expect(service.phase == .idle && service.result == nil && OpenCellProtocol.requests.isEmpty,
                     "constructing a lookup view service performs no request")
        await lookup(service, confirmed: false)
        suite.expect(service.phase == .failed && OpenCellProtocol.requests.isEmpty,
                     "provider disclosure confirmation is required before any request")
        await lookup(service)
        let requests = OpenCellProtocol.requests
        suite.expect(service.phase == .ready && service.result?.identity == TMobileOpenCellIDTests.identity && requests.count == 1,
                     "one explicit confirmed lookup publishes one matched community position")
        suite.expect(requests.allSatisfy { $0.method == "GET" && $0.url.scheme == "https" && $0.url.host == "opencellid.org"
            && $0.url.path == "/cell/get" && $0.timeout == 15 && $0.body.isEmpty && $0.authorization == nil && $0.cookie == nil },
                     "only the fixed HTTPS read endpoint receives one bounded GET without inherited credentials or body")
        let query = URLComponents(url: requests[0].url, resolvingAgainstBaseURL: false)!.queryItems!
        suite.expect(Set(query.map(\.name)) == ["key", "mcc", "mnc", "lac", "cellid", "radio", "format"]
                     && query.first(where: { $0.name == "key" })?.value == "fixture+a&b=c"
                     && query.first(where: { $0.name == "radio" })?.value == "LTE",
                     "only the selected manual cell identity, format and transient provider key enter the query")
        service.clear()
        suite.expect(service.phase == .idle && service.result == nil && service.message == nil && OpenCellProtocol.requests.count == 1,
                     "clearing removes the result without another lookup, upload or history write")
        await service.lookup(identity: TMobileOpenCellIDTests.identity, token: "", confirmedFullIdentity: true)
        suite.expect(OpenCellProtocol.requests.count == 1 && service.phase == .failed,
                     "an empty key fails before a request")
    }
    @MainActor private static func errors(_ suite: TestSuite) async {
        for reply in [OpenCellProtocol.Reply.http(200, Data(#"{"error":"fixture-sensitive-key","code":1}"#.utf8)),
                      .http(200, Data(#"{"error":"fixture-sensitive-key","code":2}"#.utf8)),
                      .http(401, Data("fixture-sensitive-key".utf8)), .http(429, Data()), .http(500, Data()),
                      .http(302, Data()), .failure(.timedOut),
                      .http(200, Data(repeating: 65, count: TMobileOpenCellIDSupport.maximumResponseBytes + 1)),
                      .declared(TMobileOpenCellIDSupport.maximumResponseBytes + 1)] {
            OpenCellProtocol.reset([reply])
            let service = service(); await lookup(service)
            suite.expect(service.phase == .failed && service.result == nil && OpenCellProtocol.requests.count == 1,
                         "provider, redirect, transport and size failures never publish a result or retry")
            suite.expect(service.message != nil && service.message?.contains("fixture-sensitive-key") == false
                         && service.message?.contains("https://") == false && service.message?.contains("key=") == false,
                         "safe errors expose no response text, provider key or request URL")
            service.clear()
        }
        OpenCellProtocol.reset([.http(200, Data(TMobileOpenCellIDTests.fixture.replacingOccurrences(of: "12345678", with: "12345679").utf8))])
        let mismatch = service(); await lookup(mismatch)
        suite.expect(mismatch.phase == .failed && mismatch.result == nil && mismatch.message == TMobileOpenCellIDFailure.identityMismatch.message,
                     "an echoed cell mismatch rejects otherwise valid coordinates")
    }
    @MainActor private static func cancellation(_ suite: TestSuite) async {
        OpenCellProtocol.reset([.hold])
        let service = service(); let task = Task { await lookup(service) }
        await wait { OpenCellProtocol.requests.count == 1 }
        await lookup(service)
        suite.expect(OpenCellProtocol.requests.count == 1, "an in-flight request cannot start a parallel lookup")
        service.clear(); await task.value
        suite.expect(service.phase == .idle && service.result == nil && service.message == nil,
                     "clearing during a lookup fences cancelled completion and clears the result")
        OpenCellProtocol.append([cell]); await lookup(service)
        suite.expect(service.phase == .ready && OpenCellProtocol.requests.count == 2,
                     "a new explicit lookup can run after cancellation without reusing a stored key")
        OpenCellProtocol.reset([.hold])
        let cancelling = self.service(); let cancelled = Task { await lookup(cancelling) }
        await wait { OpenCellProtocol.requests.count == 1 }
        cancelled.cancel(); await cancelled.value
        suite.expect(cancelling.phase == .failed && cancelling.result == nil
                     && cancelling.message == TMobileOpenCellIDFailure.cancelled.message,
                     "Task cancellation discards the lookup without publishing stale results")
        cancelling.clear()
    }

    @MainActor private static func areaLifecycle(_ suite: TestSuite) async {
        OpenCellProtocol.reset([areaCells, cell, .http(200, Data(#"{"count":0,"cells":[]}"#.utf8)),
                                .http(200, Data(TMobileOpenCellIDTests.areaFixture.replacingOccurrences(of: "LTE", with: "NR").utf8))])
        let service = service()
        suite.expect(service.phase == .idle && service.areaResults.isEmpty && service.result == nil && OpenCellProtocol.requests.isEmpty,
                     "constructing an area lookup service never searches the map automatically")
        await search(service, approved: false)
        suite.expect(service.phase == .failed && service.areaResults.isEmpty && OpenCellProtocol.requests.isEmpty,
                     "sharing the map area requires an explicit approved search")
        await search(service, token: "")
        suite.expect(service.phase == .failed && OpenCellProtocol.requests.isEmpty,
                     "an empty area-search key is rejected before a request")
        await search(service)
        let requests = OpenCellProtocol.requests
        suite.expect(service.phase == .ready && service.areaResults.count == 1 && service.result == nil && requests.count == 1,
                     "one approved area search publishes community cells without publishing an exact-cell result")
        suite.expect(requests.allSatisfy { $0.method == "GET" && $0.url.scheme == "https" && $0.url.host == "opencellid.org"
            && $0.url.path == "/cell/getInArea" && $0.timeout == 15 && $0.body.isEmpty && $0.authorization == nil && $0.cookie == nil },
                     "area searches send one bounded HTTPS GET without inherited credentials or a request body")
        if let request = requests.first,
           let query = URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems {
            suite.expect(query.count == 6 && Set(query.map(\.name)) == ["key", "BBOX", "radio", "format", "limit", "offset"]
                         && query.first(where: { $0.name == "key" })?.value == "fixture+a&b=c"
                         && query.first(where: { $0.name == "BBOX" })?.value == TMobileOpenCellIDTests.area.queryValue
                         && query.first(where: { $0.name == "radio" })?.value == "LTE"
                         && query.first(where: { $0.name == "limit" })?.value == "50"
                         && query.first(where: { $0.name == "offset" })?.value == "0",
                         "only the explicit map BBOX, selected radio, first-page limit, format and key enter the area query")
        } else { suite.expect(false, "the area request contains its bounded query") }
        await lookup(service)
        suite.expect(service.phase == .ready && service.result?.identity == TMobileOpenCellIDTests.identity
                     && service.areaResults.isEmpty && OpenCellProtocol.requests.count == 2,
                     "an explicit exact-cell lookup replaces temporary area results rather than mixing result modes")
        await search(service)
        suite.expect(service.phase == .ready && service.areaResults.isEmpty && service.result == nil
                     && service.message?.contains("Missing community records") == true && OpenCellProtocol.requests.count == 3,
                     "an empty area response clears a prior exact result and explains that missing records do not establish missing service")
        await search(service, radio: .nr)
        let last = OpenCellProtocol.requests.last
        suite.expect(service.phase == .ready && service.areaResults.first?.identity.radio == .nr
                     && last.flatMap { URLComponents(url: $0.url, resolvingAgainstBaseURL: false) }?.queryItems?.first(where: { $0.name == "radio" })?.value == "NR"
                     && OpenCellProtocol.requests.count == 4,
                     "NR area searches pass the chosen radio and accept only matching returned cells")
        service.clear()
        suite.expect(service.phase == .idle && service.areaResults.isEmpty && service.result == nil && service.message == nil
                     && OpenCellProtocol.requests.count == 4,
                     "clearing an area search removes both result modes without another request or archive write")
    }

    @MainActor private static func areaErrors(_ suite: TestSuite) async {
        let replies: [OpenCellProtocol.Reply] = [
            .http(200, Data(#"{"error":"fixture-sensitive-key","code":1}"#.utf8)),
            .http(200, Data(#"{"error":"fixture-sensitive-key","code":2}"#.utf8)),
            .http(200, Data(#"{"error":"fixture-sensitive-key","code":3}"#.utf8)),
            .http(200, Data(#"{"error":"fixture-sensitive-key","code":7}"#.utf8)),
            .http(400, Data("fixture-sensitive-key".utf8)), .http(401, Data()), .http(403, Data()), .http(429, Data()),
            .http(500, Data()), .http(302, Data()), .failure(.timedOut),
            .http(200, Data(#"{"count":1,"cells":[]}"#.utf8).dropLast()),
            .http(200, Data(TMobileOpenCellIDTests.areaFixture.replacingOccurrences(of: "LTE", with: "NR").utf8)),
            .http(200, Data(repeating: 65, count: TMobileOpenCellIDSupport.maximumResponseBytes + 1)),
            .declared(TMobileOpenCellIDSupport.maximumResponseBytes + 1)
        ]
        for reply in replies {
            OpenCellProtocol.reset([reply])
            let service = service(); await search(service)
            suite.expect(service.phase == .failed && service.areaResults.isEmpty && service.result == nil
                         && OpenCellProtocol.requests.count == 1,
                         "area provider, HTTP, redirect, transport, radio and size failures never publish cells or retry")
            suite.expect(service.message != nil && service.message?.contains("fixture-sensitive-key") == false
                         && service.message?.contains("https://") == false && service.message?.contains("key=") == false,
                         "area errors expose neither provider text nor an API key or request URL")
            service.clear()
        }
        for (status, expected) in [(401, TMobileOpenCellIDFailure.authentication), (403, .authentication),
                                   (429, .limit), (500, .unavailable), (302, .unavailable)] {
            OpenCellProtocol.reset([.http(status, Data())])
            let service = service(); await search(service)
            suite.expect(service.message == expected.message && service.areaResults.isEmpty,
                         "area HTTP \(status) uses its safe failure category")
        }
        // A provider total may exceed the returned first page, but no second
        // request is made automatically and no extra cells are manufactured.
        OpenCellProtocol.reset([.http(200, Data(TMobileOpenCellIDTests.areaFixture.replacingOccurrences(of: "\"count\":1", with: "\"count\":1000").utf8))])
        let page = service(); await search(page)
        suite.expect(page.phase == .ready && page.areaResults.count == 1 && OpenCellProtocol.requests.count == 1,
                     "a larger reported total never triggers automatic pagination or quota-consuming retries")
    }

    @MainActor private static func areaCancellation(_ suite: TestSuite) async {
        OpenCellProtocol.reset([.hold])
        let service = service(); let task = Task { await search(service) }
        await wait { OpenCellProtocol.requests.count == 1 }
        suite.expect(service.phase == .loading && OpenCellProtocol.requests.count == 1,
                     "an area request can be cancelled while the intercepted transport is pending")
        await search(service); await lookup(service)
        suite.expect(OpenCellProtocol.requests.count == 1,
                     "an in-flight area search blocks parallel area and exact-cell requests")
        service.clear(); await task.value
        suite.expect(service.phase == .idle && service.areaResults.isEmpty && service.result == nil && service.message == nil,
                     "clearing a pending area search fences its cancelled completion and leaves no stale map results")
        OpenCellProtocol.append([areaCells]); await search(service)
        suite.expect(service.phase == .ready && service.areaResults.count == 1 && OpenCellProtocol.requests.count == 2,
                     "a fresh explicit area search works after cancellation")
        OpenCellProtocol.reset([.hold])
        let cancelling = self.service(); let cancelled = Task { await search(cancelling) }
        await wait { OpenCellProtocol.requests.count == 1 }
        cancelled.cancel(); await cancelled.value
        suite.expect(cancelling.phase == .failed && cancelling.areaResults.isEmpty && cancelling.result == nil
                     && cancelling.message == TMobileOpenCellIDFailure.cancelled.message,
                     "Task cancellation of an area search discards all cells and reports a safe cancellation")
        cancelling.clear()
        OpenCellProtocol.reset([.hold])
        let exact = self.service(); let exactTask = Task { await lookup(exact) }
        await wait { OpenCellProtocol.requests.count == 1 }
        await search(exact)
        suite.expect(OpenCellProtocol.requests.count == 1 && exact.areaResults.isEmpty,
                     "an in-flight exact lookup also blocks an area search")
        exact.clear(); await exactTask.value
    }
    @MainActor private static func wait(_ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(3)
        while !condition(), Date() < deadline { try? await Task.sleep(nanoseconds: 5_000_000) }
    }
}

/// Intercepts every URL, including unexpected URLs. Fixture bodies remain
/// private to assertions and are never printed; this harness cannot go live.
private final class OpenCellProtocol: URLProtocol {
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
