// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Combine
import Foundation

/// Explicit, window-owned read-only administration. A session authorizes only
/// serving-cell telemetry; nothing polls, persists or joins the public reader.
@MainActor
final class TMobileCellTelemetryService: ObservableObject {
    @Published private(set) var report: TMobileCellTelemetryReport?
    @Published private(set) var phase: TMobileCellTelemetryPhase = .signedOut
    @Published private(set) var message: String?
    @Published private(set) var fetchedAt: Date?

    private let sessionConfiguration: URLSessionConfiguration
    private let now: () -> Date
    private var session: URLSession?
    private var transport: TMobileCellTelemetrySessionDelegate?
    private var baseURL: URL?
    private var token: String?
    private var generation = 0
    private var busy: Bool { phase == .connecting || phase == .loading }
    var canRefresh: Bool { token != nil && !busy }

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
        let delegate = TMobileCellTelemetrySessionDelegate()
        transport = delegate
        session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        let current = generation
        phase = .connecting
        do {
            let body = try JSONSerialization.data(withJSONObject: ["username": username, "password": password])
            let data = try await request(.login, body: body)
            guard generation == current else { return }
            token = try TMobileCellTelemetrySupport.token(from: data)
            phase = .loading
            let fetched = try await fetch()
            guard generation == current else { return }
            report = fetched; fetchedAt = now(); phase = .ready; message = nil
        } catch {
            guard generation == current else { return }
            clearSession()
            phase = .failed; message = safeMessage(error)
        }
    }

    func refresh() async {
        guard canRefresh else { return }
        let current = generation
        phase = .loading; report = nil; fetchedAt = nil; message = nil
        do {
            let fetched = try await fetch()
            guard generation == current else { return }
            report = fetched; fetchedAt = now(); phase = .ready
        } catch {
            guard generation == current else { return }
            report = nil; fetchedAt = nil
            if error is CancellationError || (error as? URLError)?.code == .cancelled
                || (error as? TMobileCellTelemetryFailure) == .authenticationRequired {
                clearSession()
            }
            phase = .failed; message = safeMessage(error)
        }
    }

    func disconnect() {
        generation += 1
        clearSession()
        phase = .signedOut; message = nil
    }

    private func clearSession() {
        session?.invalidateAndCancel()
        session = nil; transport = nil; baseURL = nil; token = nil
        report = nil; fetchedAt = nil
    }

    private func fetch() async throws -> TMobileCellTelemetryReport {
        try await TMobileCellTelemetrySupport.parse(request(.servingCell))
    }

    private enum Endpoint { case login, servingCell }

    /// Endpoint choice is closed: the only POST authenticates; telemetry is
    /// GET-only. Callers cannot supply a path, method, query or write payload.
    private func request(_ endpoint: Endpoint, body: Data? = nil) async throws -> Data {
        try Task.checkCancellation()
        guard let session, let transport, let baseURL else { throw TMobileCellTelemetryFailure.cancelled }
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        components.path = endpoint == .login ? "/TMI/v1/auth/login" : "/TMI/v1/network/telemetry"
        components.query = endpoint == .login ? nil : "get=cell"
        var request = URLRequest(url: components.url!, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.httpMethod = endpoint == .login ? "POST" : "GET"
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if endpoint == .login {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        } else {
            guard let token else { throw TMobileCellTelemetryFailure.authenticationRequired }
            request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await transport.send(request, session: session)
        try Task.checkCancellation()
        if response.statusCode == 401 || response.statusCode == 403 { throw TMobileCellTelemetryFailure.authenticationRequired }
        guard (200...299).contains(response.statusCode) else { throw TMobileCellTelemetryFailure.unavailable }
        return data
    }

    private func safeMessage(_ error: Error) -> String {
        if error is CancellationError || (error as? URLError)?.code == .cancelled {
            return "The serving-cell request was cancelled. Sign in again to retry."
        }
        switch error as? TMobileCellTelemetryFailure {
        case .authenticationRequired: return "Administrator authentication was rejected or expired. Sign in again."
        case .invalidResponse: return "The gateway returned unsupported or incomplete serving-cell telemetry."
        case .cancelled: return "The serving-cell session was closed. Sign in again to retry."
        default: return "Serving-cell telemetry could not be read. Check the local connection and try again."
        }
    }
}

private final class TMobileCellTelemetryTaskReference: @unchecked Sendable {
    private let lock = NSLock()
    private var task: URLSessionTask?
    private var cancelled = false
    func set(_ task: URLSessionTask) { lock.withLock { self.task = task; if cancelled { task.cancel() } } }
    func cancel() { lock.withLock { cancelled = true; task?.cancel() } }
}

private final class TMobileCellTelemetrySessionDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private struct Response {
        var data = Data()
        var response: HTTPURLResponse?
        var failure: Error?
        let complete: (Result<(Data, HTTPURLResponse), Error>) -> Void
    }
    private let lock = NSLock()
    private var responses: [Int: Response] = [:]

    func send(_ request: URLRequest, session: URLSession) async throws -> (Data, HTTPURLResponse) {
        let reference = TMobileCellTelemetryTaskReference()
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
        let valid = response is HTTPURLResponse && response.expectedContentLength <= TMobileCellTelemetrySupport.maximumResponseBytes
        lock.withLock {
            responses[dataTask.taskIdentifier]?.response = response as? HTTPURLResponse
            if !valid { responses[dataTask.taskIdentifier]?.failure = TMobileCellTelemetryFailure.invalidResponse }
        }
        completionHandler(valid ? .allow : .cancel)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let cancel = lock.withLock { () -> Bool in
            guard var response = responses[dataTask.taskIdentifier] else { return true }
            if response.data.count + data.count > TMobileCellTelemetrySupport.maximumResponseBytes {
                response.failure = TMobileCellTelemetryFailure.invalidResponse; responses[dataTask.taskIdentifier] = response; return true
            }
            response.data.append(data); responses[dataTask.taskIdentifier] = response; return false
        }
        if cancel { dataTask.cancel() }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let saved = lock.withLock({ responses.removeValue(forKey: task.taskIdentifier) }) else { return }
        if let failure = saved.failure ?? error { saved.complete(.failure(failure)) }
        else if let response = saved.response { saved.complete(.success((saved.data, response))) }
        else { saved.complete(.failure(TMobileCellTelemetryFailure.invalidResponse)) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }

    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        completionHandler(challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust
                          ? .performDefaultHandling : .cancelAuthenticationChallenge, nil)
    }
}
