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

@main struct TMobileWiFiServiceHarness {
    @MainActor static func main() async {
        let suite = TestSuite()
        TMobileWiFiTests.run(suite)
        await lifecycle(suite)
        await conflicts(suite)
        await uncertain(suite)
        await cancellation(suite)
        await bounds(suite)
        if suite.failures.isEmpty { print("PASS: \(suite.checks) Wi-Fi backend checks; every request intercepted; no live router or preferences accessed") }
        else { suite.failures.forEach { print("FAIL: \($0)") }; exit(1) }
    }

    @MainActor private static func service() -> TMobileWiFiService {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [WiFiProtocol.self]
        configuration.httpAdditionalHeaders = ["Authorization": "fixture-must-remove", "Cookie": "fixture-must-remove"]
        return TMobileWiFiService(configuration: configuration)
    }
    private static var login: WiFiProtocol.Reply { .http(200, Data(#"{"auth":{"token":"fixture.token"}}"#.utf8)) }
    private static var config: WiFiProtocol.Reply { .http(200, Data(TMobileWiFiTests.fixture.utf8)) }
    private static func reply(_ text: String) -> WiFiProtocol.Reply { .http(200, Data(text.utf8)) }
    @MainActor private static func connect(_ service: TMobileWiFiService) async {
        await service.connect(baseURL: "http://192.168.12.1", username: "fixture-admin", password: "fixture-admin-key")
    }

    @MainActor private static func lifecycle(_ suite: TestSuite) async {
        WiFiProtocol.reset([login, config, config])
        let service = service()
        await connect(service)
        suite.expect(service.phase == .ready && service.configuration?.ssids.count == 2, "explicit sign-in loads sanitized configuration")
        let requests = WiFiProtocol.requests
        suite.expect(requests.count == 2 && requests[0].method == "POST" && requests[0].url.path == "/TMI/v1/auth/login"
                     && requests[1].method == "GET" && requests[1].url.query == "get=ap", "admin uses only verified login and AP GET endpoints")
        suite.expect(requests[0].authorization == nil && requests[0].cookie == nil
                     && requests[1].authorization == "Bearer fixture.token" && requests[1].cookie == nil,
                     "bearer is request-scoped and inherited credentials/cookies are discarded")
        await service.prepare([.init(ssidID: 0, name: "Changed fixture")])
        suite.expect(service.phase == .reviewing && service.review?.changes.count == 1 && WiFiProtocol.posts == 0,
                     "prepare refreshes and reviews without writing Wi-Fi settings")
        service.cancelReview()
        suite.expect(service.phase == .ready && service.review == nil, "cancel review clears the secret patch without network activity")
        WiFiProtocol.append([config, config, .http(200, Data("{}".utf8)), reply(TMobileWiFiTests.fixture.replacingOccurrences(of: "Fixture network", with: "Changed fixture"))])
        await service.prepare([.init(ssidID: 0, name: "Changed fixture")])
        let id = service.review!.id
        await service.apply(reviewID: UUID())
        suite.expect(WiFiProtocol.posts == 0, "an unconfirmed or stale review ID cannot write")
        await service.apply(reviewID: id)
        suite.expect(service.phase == .verified && service.canRestore && WiFiProtocol.posts == 1,
                     "one confirmed POST is verified by a fresh full configuration read")
        let body = WiFiProtocol.requests.first { $0.url.query == "set=ap" }!.body
        let raw = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
        suite.expect((raw?["ssids"] as? [[String: Any]])?[1]["wpaKey"] as? String == "fixture-key-456"
                     && raw?["future"] != nil, "network POST carries preserved complete configuration, not a partial visible-field object")
        let changed = TMobileWiFiTests.fixture.replacingOccurrences(of: "Fixture network", with: "Changed fixture")
        WiFiProtocol.append([reply(changed)])
        await service.prepareRestore()
        suite.expect(service.review?.isRestore == true && WiFiProtocol.posts == 1, "restore requires its own review and confirmation")
        service.cancelReview()
        suite.expect(service.canRestore, "cancelling restore review retains the verified session baseline")
        WiFiProtocol.append([reply(changed), reply(changed), .http(200, Data("{}".utf8)), config])
        await service.prepareRestore()
        await service.apply(reviewID: service.review!.id)
        suite.expect(service.phase == .verified && !service.canRestore && WiFiProtocol.posts == 2,
                     "separately confirmed touched-field restore is readback-verified once")
        service.disconnect()
        suite.expect(service.phase == .signedOut && service.configuration == nil && service.review == nil && !service.canRestore,
                     "disconnect discards configuration, reviews and rollback baseline")
    }

    @MainActor private static func conflicts(_ suite: TestSuite) async {
        let changed = TMobileWiFiTests.fixture.replacingOccurrences(of: "futureSSIDField\":17", with: "futureSSIDField\":18")
        WiFiProtocol.reset([login, config, reply(changed)])
        let service = service(); await connect(service)
        await service.prepare([.init(ssidID: 0, guest: true)])
        suite.expect(service.phase == .conflict && service.review == nil && WiFiProtocol.posts == 0,
                     "even an unknown-field change causes a complete read-before-write conflict")
        service.disconnect()
        WiFiProtocol.reset([login, config, config, reply(changed)])
        let second = self.service(); await connect(second)
        await second.prepare([.init(ssidID: 0, guest: true)])
        await second.apply(reviewID: second.review!.id)
        suite.expect(second.phase == .conflict && WiFiProtocol.posts == 0,
                     "final preflight detects changes made while a review was open")
        second.disconnect()
        var clock = Date()
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [WiFiProtocol.self]
        let expiry = TMobileWiFiService(configuration: configuration, now: { clock })
        WiFiProtocol.reset([login, config, config]); await connect(expiry)
        await expiry.prepare([.init(ssidID: 0, guest: true)])
        clock = clock.addingTimeInterval(61)
        await expiry.apply(reviewID: expiry.review!.id)
        suite.expect(expiry.phase == .ready && expiry.review == nil && WiFiProtocol.posts == 0,
                     "expired review tokens cannot apply an old secret payload")
        expiry.disconnect()

        let desired = TMobileWiFiTests.fixture.replacingOccurrences(of: "\"guest\":false", with: "\"guest\":true")
        WiFiProtocol.reset([login, config, config, config, .http(200, Data("{}".utf8)), reply(desired), reply(changed)])
        let restoring = self.service(); await connect(restoring)
        await restoring.prepare([.init(ssidID: 0, guest: true)])
        await restoring.apply(reviewID: restoring.review!.id)
        await restoring.prepareRestore()
        suite.expect(restoring.phase == .conflict && restoring.review == nil && !restoring.canRestore && WiFiProtocol.posts == 1,
                     "restore rejects a fresh configuration conflict without sending a second POST")
        restoring.disconnect()

        let masked = TMobileWiFiTests.fixture.replacingOccurrences(of: "fixture-key-123", with: "********")
        let replaced = TMobileWiFiTests.fixture.replacingOccurrences(of: "fixture-key-123", with: "explicit-new-key")
        WiFiProtocol.reset([login, reply(masked), reply(masked), reply(masked), .http(200, Data("{}".utf8)), reply(replaced)])
        let replacement = self.service(); await connect(replacement)
        await replacement.prepare([.init(ssidID: 0, password: "explicit-new-key")])
        await replacement.apply(reviewID: replacement.review!.id)
        suite.expect(replacement.phase == .verified && !replacement.canRestore && WiFiProtocol.posts == 1,
                     "a verified replacement cannot advertise restoring an unavailable masked original password")
        replacement.disconnect()
    }

    @MainActor private static func uncertain(_ suite: TestSuite) async {
        for failure in [WiFiProtocol.Reply.failure(.timedOut), .http(408, Data("{}".utf8)), .http(401, Data("{}".utf8))] {
            WiFiProtocol.reset([login, config, config, config, failure])
            let service = service(); await connect(service)
            await service.prepare([.init(ssidID: 0, guest: true)])
            await service.apply(reviewID: service.review!.id)
            suite.expect(service.phase == .outcomeUnknown && WiFiProtocol.posts == 1 && !service.canRestore,
                         "timeout, 408 and expired-auth outcomes never retry an uncertain write or auto-restore")
            let desired = TMobileWiFiTests.fixture.replacingOccurrences(of: "\"guest\":false", with: "\"guest\":true")
            WiFiProtocol.append([reply(desired)])
            await service.verifyPending()
            suite.expect(service.phase == .verified && WiFiProtocol.posts == 1 && service.canRestore,
                         "pending outcomes resolve using GET alone after reconnection")
            service.disconnect()
        }
        WiFiProtocol.reset([login, config, config, config, .http(200, Data("{}".utf8)), config])
        let mismatch = service(); await connect(mismatch)
        await mismatch.prepare([.init(ssidID: 0, guest: true)])
        await mismatch.apply(reviewID: mismatch.review!.id)
        suite.expect(mismatch.phase == .outcomeUnknown && WiFiProtocol.posts == 1, "2xx with mismatched readback remains unverified without automatic rollback")
        mismatch.disconnect()
    }

    @MainActor private static func cancellation(_ suite: TestSuite) async {
        WiFiProtocol.reset([login, .hold])
        let loading = service()
        let load = Task { await connect(loading) }
        await wait { WiFiProtocol.requests.count == 2 }
        loading.disconnect(); await load.value
        suite.expect(loading.phase == .signedOut && loading.configuration == nil && WiFiProtocol.posts == 0,
                     "logout cancels a read and prevents late credential-bearing publication")
        WiFiProtocol.reset([login, config, config, config, .hold])
        let applying = service(); await connect(applying)
        await applying.prepare([.init(ssidID: 0, guest: true)])
        let id = applying.review!.id
        let write = Task { await applying.apply(reviewID: id) }
        await wait { WiFiProtocol.posts == 1 }
        write.cancel(); await write.value
        suite.expect(applying.phase == .outcomeUnknown && WiFiProtocol.posts == 1,
                     "cancellation after POST send retains an uncertain outcome instead of retrying")
        applying.disconnect()

        WiFiProtocol.reset([login, config, config, login, config, config, .hold])
        let first = service(), second = service()
        await connect(first); await first.prepare([.init(ssidID: 0, guest: true)])
        await connect(second); await second.prepare([.init(ssidID: 0, guest: true)])
        let firstID = first.review!.id, secondID = second.review!.id
        let firstWrite = Task { await first.apply(reviewID: firstID) }
        await wait { WiFiProtocol.requests.count == 7 }
        suite.expect(first.phase == .verifying && WiFiProtocol.posts == 0,
                     "final preflight publishes a transaction phase before POST so close and address guards remain active")
        await second.apply(reviewID: secondID)
        suite.expect(second.phase == .reviewing && WiFiProtocol.requests.count == 7 && WiFiProtocol.posts == 0,
                     "process-wide lease prevents another window entering preflight during a write transaction")
        first.disconnect(); await firstWrite.value
        WiFiProtocol.append([config, .http(200, Data("{}".utf8)), reply(TMobileWiFiTests.fixture.replacingOccurrences(of: "\"guest\":false", with: "\"guest\":true"))])
        await second.apply(reviewID: secondID)
        suite.expect(second.phase == .verified && WiFiProtocol.posts == 1, "write lease releases after cancelled transport retires, allowing the other reviewed transaction")
        second.disconnect()
    }

    @MainActor private static func bounds(_ suite: TestSuite) async {
        WiFiProtocol.reset([])
        let invalid = service()
        await invalid.connect(baseURL: "http://8.8.8.8", username: "fixture", password: "fixture")
        suite.expect(invalid.phase == .failed && WiFiProtocol.requests.isEmpty, "public origins are rejected before administrator credentials can be sent")
        for reply in [WiFiProtocol.Reply.http(302, Data("{}".utf8)), .http(401, Data("fixture-sensitive-error".utf8)),
                      .http(200, Data(repeating: 65, count: TMobileWiFiSupport.maximumResponseBytes + 1))] {
            WiFiProtocol.reset([reply])
            let invalid = service(); await connect(invalid)
            suite.expect(invalid.phase == .failed && WiFiProtocol.requests.count == 1 && invalid.configuration == nil,
                         "redirects, rejected authentication and oversized responses cannot start another request or publish data")
            suite.expect(invalid.message?.contains("fixture-sensitive-error") == false,
                         "raw authentication and transport response bodies never enter user-facing errors")
            invalid.disconnect()
        }
    }

    @MainActor private static func wait(_ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(3)
        while !condition(), Date() < deadline { try? await Task.sleep(nanoseconds: 5_000_000) }
    }
}

/// Intercepts every URL, including unexpected ones, so the harness cannot reach
/// a real router. Captured fixture request bodies are never printed.
private final class WiFiProtocol: URLProtocol {
    enum Reply { case http(Int, Data), failure(URLError.Code), hold }
    struct Request {
        let method: String
        let url: URL
        let authorization: String?
        let cookie: String?
        let body: Data
    }
    private static let lock = NSLock()
    private static var replies: [Reply] = []
    private static var captured: [Request] = []
    static var requests: [Request] { lock.withLock { captured } }
    static var posts: Int { requests.filter { $0.url.query == "set=ap" && $0.method == "POST" }.count }
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
        let response = Self.lock.withLock { () -> Reply in
            Self.captured.append(.init(method: request.httpMethod ?? "", url: request.url!,
                                       authorization: request.value(forHTTPHeaderField: "Authorization"),
                                       cookie: request.value(forHTTPHeaderField: "Cookie"), body: body))
            return Self.replies.isEmpty ? .failure(.unsupportedURL) : Self.replies.removeFirst()
        }
        switch response {
        case let .http(status, data):
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil,
                                           headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        case let .failure(code): client?.urlProtocol(self, didFailWithError: URLError(code))
        case .hold: break
        }
    }
    override func stopLoading() {}
}
