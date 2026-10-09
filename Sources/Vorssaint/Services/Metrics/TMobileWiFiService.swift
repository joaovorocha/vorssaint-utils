// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Combine
import Foundation

/// A window-owned admin session. Nothing in this type is persisted or shared
/// with the credential-free monitor, its notifications or its history store.
@MainActor
final class TMobileWiFiService: ObservableObject {
    @Published private(set) var configuration: TMobileWiFiConfiguration?
    @Published private(set) var phase: TMobileWiFiPhase = .signedOut
    @Published private(set) var message: String?
    @Published private(set) var review: TMobileWiFiReview?
    @Published private(set) var canRestore = false

    private struct Plan {
        let review: TMobileWiFiReview
        let before: TMobileWiFiPayload
        let desired: TMobileWiFiPayload
        let edits: [TMobileWiFiEdit]
        let created: Date
    }
    private struct Restore {
        let before: TMobileWiFiPayload
        let after: TMobileWiFiPayload
        let edits: [TMobileWiFiEdit]
    }
    private static var writeLease: UUID?
    private let sessionConfiguration: URLSessionConfiguration
    private let now: () -> Date
    private var session: URLSession?
    private var transport: TMobileWiFiSessionDelegate?
    private var baseURL: URL?
    private var token: String?
    private var payload: TMobileWiFiPayload?
    private var plan: Plan?
    private var pending: Plan?
    private var restore: Restore?
    private var generation = 0
    private var busy: Bool { [.connecting, .loading, .applying, .verifying].contains(phase) }

    init(configuration: URLSessionConfiguration = .ephemeral, now: @escaping () -> Date = Date.init) {
        sessionConfiguration = configuration.copy() as! URLSessionConfiguration
        self.now = now
    }

    deinit { session?.invalidateAndCancel() }

    func connect(baseURL input: String, username: String, password: String) async {
        guard !busy else { return }
        disconnect()
        guard let base = TMobileGatewaySupport.privateLANBaseURL(input), !username.isEmpty,
              username.utf8.count <= 128, !password.isEmpty, password.utf8.count <= 1024,
              !username.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            phase = .failed; message = "Enter a private LAN gateway address and administrator credentials."; return
        }
        baseURL = base
        let config = sessionConfiguration.copy() as! URLSessionConfiguration
        config.urlCache = nil; config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.httpCookieStorage = nil; config.httpShouldSetCookies = false; config.urlCredentialStorage = nil
        config.httpAdditionalHeaders = nil; config.connectionProxyDictionary = [:]
        config.timeoutIntervalForRequest = 15; config.timeoutIntervalForResource = 15; config.waitsForConnectivity = false
        let delegate = TMobileWiFiSessionDelegate()
        transport = delegate
        session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        let current = generation
        phase = .connecting
        do {
            let body = try JSONSerialization.data(withJSONObject: ["username": username, "password": password])
            let data = try await request(path: "/TMI/v1/auth/login", query: nil, method: "POST", body: body, authenticated: false)
            guard generation == current else { return }
            token = try TMobileWiFiSupport.token(from: data)
            phase = .loading
            let fetched = try await fetch()
            guard generation == current else { return }
            setPayload(fetched); phase = .ready; message = nil
        } catch {
            guard generation == current else { return }
            token = nil; payload = nil; configuration = nil
            phase = .failed; message = safeMessage(error)
        }
    }

    func disconnect() {
        generation += 1
        session?.invalidateAndCancel()
        session = nil; transport = nil; baseURL = nil; token = nil; payload = nil
        plan = nil; pending = nil; restore = nil; configuration = nil; review = nil; canRestore = false
        phase = .signedOut; message = nil
        // Do not release the process-wide write lease here. An in-flight
        // apply owns it until transport reports completion/cancellation.
    }

    func refresh() async {
        guard !busy, pending == nil, token != nil else { return }
        cancelReview()
        let current = generation
        phase = .loading
        do {
            let fetched = try await fetch()
            guard generation == current else { return }
            if let restore, !fetched.sameConfiguration(as: restore.after) { self.restore = nil; canRestore = false }
            setPayload(fetched); phase = .ready; message = nil
        } catch {
            guard generation == current else { return }
            phase = .failed; message = safeMessage(error)
        }
    }

    func prepare(_ edits: [TMobileWiFiEdit]) async {
        guard !busy, pending == nil, let baseline = payload, [.ready, .verified, .reviewing].contains(phase) else { return }
        plan = nil; review = nil
        let current = generation
        phase = .loading
        do {
            let fetched = try await fetch()
            guard generation == current else { return }
            guard fetched.sameConfiguration(as: baseline) else { conflict(fetched); return }
            let changed = try fetched.applying(edits)
            guard !changed.changes.isEmpty else { phase = .ready; message = "No settings changed."; return }
            let summary = TMobileWiFiReview(id: UUID(), origin: baseURL!.absoluteString, changes: changed.changes, isRestore: false)
            plan = Plan(review: summary, before: fetched, desired: changed.payload, edits: edits, created: now())
            review = summary; phase = .reviewing; message = nil
        } catch {
            guard generation == current else { return }
            phase = .ready; message = safeMessage(error)
        }
    }

    func cancelReview() {
        guard !busy, pending == nil else { return }
        plan = nil; review = nil
        if payload != nil { phase = .ready; message = nil }
    }

    func prepareRestore() async {
        guard !busy, pending == nil, let restore, canRestore, [.ready, .verified].contains(phase) else { return }
        let current = generation
        phase = .loading; plan = nil; review = nil
        do {
            let fetched = try await fetch()
            guard generation == current else { return }
            guard fetched.sameConfiguration(as: restore.after) else { conflict(fetched); return }
            let inverse = try restore.before.inverse(of: restore.edits)
            let changed = try fetched.applying(inverse)
            guard !changed.changes.isEmpty else { self.restore = nil; canRestore = false; phase = .ready; return }
            let summary = TMobileWiFiReview(id: UUID(), origin: baseURL!.absoluteString,
                                          changes: changed.changes, isRestore: true)
            plan = Plan(review: summary, before: fetched, desired: changed.payload, edits: inverse, created: now())
            review = summary; phase = .reviewing; message = nil
        } catch {
            guard generation == current else { return }
            phase = .ready; message = safeMessage(error)
        }
    }

    /// The UI calls this only after its explicit Apply/Restore confirmation.
    /// Both paths send one POST; no auth, status or transport failure retries it.
    func apply(reviewID: UUID) async {
        guard !busy, phase == .reviewing, let plan, plan.review.id == reviewID,
              pending == nil else { return }
        guard now().timeIntervalSince(plan.created) >= 0, now().timeIntervalSince(plan.created) <= 60 else {
            cancelReview(); message = "This review expired. Review the settings again before applying."; return
        }
        guard Self.writeLease == nil else { message = "Another Wi-Fi change is still finishing. Try again after it completes."; return }
        let lease = UUID(); Self.writeLease = lease
        defer { if Self.writeLease == lease { Self.writeLease = nil } }
        let current = generation
        // Treat the final preflight as part of the confirmed transaction, so
        // window close and gateway-address guards cover it before the POST.
        phase = .verifying
        do {
            let fresh = try await fetch()
            guard generation == current else { return }
            guard fresh.sameConfiguration(as: plan.before) else { conflict(fresh); return }
            pending = plan; self.plan = nil; review = nil; restore = nil; canRestore = false
            phase = .applying
            _ = try await request(path: "/TMI/v1/network/configuration/v2", query: "set=ap", method: "POST",
                                  body: plan.desired.encoded(), authenticated: true)
            guard generation == current else { return }
            try await verify(plan, generation: current)
        } catch {
            guard generation == current else { return }
            if pending != nil { phase = .outcomeUnknown; message = "The change could not be verified. No write was retried. Reconnect to the gateway's network if needed, then verify pending settings." }
            else { phase = .reviewing; message = safeMessage(error) }
        }
    }

    func verifyPending() async {
        guard !busy, let pending, phase == .outcomeUnknown else { return }
        guard Self.writeLease == nil else { message = "Another Wi-Fi change is still finishing. Try verification afterward."; return }
        let lease = UUID(); Self.writeLease = lease
        defer { if Self.writeLease == lease { Self.writeLease = nil } }
        let current = generation
        do { try await verify(pending, generation: current) }
        catch {
            guard generation == current else { return }
            phase = .outcomeUnknown; message = "Pending settings are still unverified. No write was retried." }
    }

    private func verify(_ plan: Plan, generation current: Int) async throws {
        phase = .verifying
        let fetched = try await fetch()
        guard generation == current else { return }
        setPayload(fetched)
        guard fetched.sameConfiguration(as: plan.desired) else {
            phase = .outcomeUnknown; message = "The router returned different settings. No write was retried. Verify again after the connection settles."; return
        }
        pending = nil
        if plan.review.isRestore { restore = nil; canRestore = false }
        else if (try? plan.before.inverse(of: plan.edits)) != nil {
            restore = Restore(before: plan.before, after: fetched, edits: plan.edits); canRestore = true
        }
        else { restore = nil; canRestore = false }
        phase = .verified; message = "Settings verified by a fresh read."
    }

    private func conflict(_ fetched: TMobileWiFiPayload) {
        setPayload(fetched); plan = nil; review = nil; restore = nil; canRestore = false
        phase = .conflict; message = "Router settings changed since they were loaded. Reload and review your edits again."
    }

    private func setPayload(_ payload: TMobileWiFiPayload) { self.payload = payload; configuration = payload.configuration }

    private func fetch() async throws -> TMobileWiFiPayload {
        try await TMobileWiFiPayload(data: request(path: "/TMI/v1/network/configuration/v2", query: "get=ap",
                                                method: "GET", body: nil, authenticated: true))
    }

    private func request(path: String, query: String?, method: String, body: Data?, authenticated: Bool) async throws -> Data {
        try Task.checkCancellation()
        guard let session, let transport, let baseURL else { throw TMobileWiFiFailure.cancelled }
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        components.path = path; components.query = query
        var request = URLRequest(url: components.url!, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.httpMethod = method; request.httpBody = body; request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        if authenticated {
            guard let token else { throw TMobileWiFiFailure.authenticationRequired }
            request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await transport.send(request, session: session)
        try Task.checkCancellation()
        if response.statusCode == 401 || response.statusCode == 403 { throw TMobileWiFiFailure.authenticationRequired }
        guard (200...299).contains(response.statusCode) else { throw TMobileWiFiFailure.unavailable }
        return data
    }

    private func safeMessage(_ error: Error) -> String {
        switch error as? TMobileWiFiFailure {
        case .authenticationRequired: return "Administrator authentication was rejected or expired. Sign in again."
        case .invalidResponse: return "The gateway returned unsupported or incomplete Wi-Fi settings."
        case .invalidEdit: return "Enter a valid supported setting. Names allow 1–32 UTF-8 bytes; passwords require 8–63 printable ASCII characters."
        case .incompleteCredentials: return "The gateway omitted or masked a Wi-Fi password. Complete credentials are required before writing the full configuration."
        case .cancelled: return "The request was cancelled."
        default: return "The gateway could not be reached. Check the local connection and try again."
        }
    }
}

private final class TMobileWiFiTaskReference: @unchecked Sendable {
    private let lock = NSLock()
    private var task: URLSessionTask?
    private var cancelled = false
    func set(_ task: URLSessionTask) { lock.withLock { self.task = task; if cancelled { task.cancel() } } }
    func cancel() { lock.withLock { cancelled = true; task?.cancel() } }
}

/// Accumulates bounded data rather than allowing an unbounded async data task
/// to buffer a gateway response. Only one continuation consumes each result.
private final class TMobileWiFiSessionDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private struct Response {
        var data = Data()
        var response: HTTPURLResponse?
        var failure: Error?
        let complete: (Result<(Data, HTTPURLResponse), Error>) -> Void
    }
    private let lock = NSLock()
    private var responses: [Int: Response] = [:]

    func send(_ request: URLRequest, session: URLSession) async throws -> (Data, HTTPURLResponse) {
        let reference = TMobileWiFiTaskReference()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let task = session.dataTask(with: request)
                lock.withLock { responses[task.taskIdentifier] = Response(complete: { continuation.resume(with: $0) }) }
                reference.set(task); task.resume()
            }
        } onCancel: { reference.cancel() }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        let valid = response is HTTPURLResponse && response.expectedContentLength <= TMobileWiFiSupport.maximumResponseBytes
        lock.withLock {
            responses[dataTask.taskIdentifier]?.response = response as? HTTPURLResponse
            if !valid { responses[dataTask.taskIdentifier]?.failure = TMobileWiFiFailure.invalidResponse }
        }
        completionHandler(valid ? .allow : .cancel)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let cancel = lock.withLock { () -> Bool in
            guard var response = responses[dataTask.taskIdentifier] else { return true }
            if response.data.count + data.count > TMobileWiFiSupport.maximumResponseBytes {
                response.failure = TMobileWiFiFailure.invalidResponse; responses[dataTask.taskIdentifier] = response; return true
            }
            response.data.append(data); responses[dataTask.taskIdentifier] = response; return false
        }
        if cancel { dataTask.cancel() }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let saved = lock.withLock({ responses.removeValue(forKey: task.taskIdentifier) }) else { return }
        if let failure = saved.failure ?? error { saved.complete(.failure(failure)) }
        else if let response = saved.response { saved.complete(.success((saved.data, response))) }
        else { saved.complete(.failure(TMobileWiFiFailure.invalidResponse)) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }

    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        completionHandler(challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust
                          ? .performDefaultHandling : .cancelAuthenticationChallenge, nil)
    }
}
