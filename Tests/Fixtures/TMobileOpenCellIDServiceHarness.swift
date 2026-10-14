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
        if suite.failures.isEmpty {
            print("PASS: \(suite.checks) OpenCellID checks; every URL intercepted; no live provider, key store or history accessed")
        } else { suite.failures.forEach { print("FAIL: \($0)") }; exit(1) }
    }
    private static var cell: OpenCellProtocol.Reply { .http(200, Data(TMobileOpenCellIDTests.fixture.utf8)) }
    @MainActor private static func service() -> TMobileOpenCellIDService {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OpenCellProtocol.self]
        configuration.httpAdditionalHeaders = ["Authorization": "fixture-must-remove", "Cookie": "fixture-must-remove"]
        return TMobileOpenCellIDService(configuration: configuration)
    }
    @MainActor private static func lookup(_ service: TMobileOpenCellIDService, confirmed: Bool = true) async {
        await service.lookup(identity: TMobileOpenCellIDTests.identity, token: "fixture+a&b=c", confirmedFullIdentity: confirmed)
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
