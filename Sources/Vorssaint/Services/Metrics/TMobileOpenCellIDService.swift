// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Combine
import Foundation

/// One human-requested provider lookup. No token store, polling, uploads,
/// fallback endpoint, public-reader integration or local-history side effect.
@MainActor
final class TMobileOpenCellIDService: ObservableObject {
    @Published private(set) var result: TMobileOpenCellIDResult?
    @Published private(set) var phase: TMobileOpenCellIDPhase = .idle
    @Published private(set) var message: String?
    private let configuration: URLSessionConfiguration
    private var session: URLSession?
    private var generation = 0

    init(configuration: URLSessionConfiguration = .ephemeral) {
        self.configuration = configuration.copy() as! URLSessionConfiguration
    }
    deinit { session?.invalidateAndCancel() }

    func lookup(identity: TMobileOpenCellIDIdentity, token: String, confirmedFullIdentity: Bool) async {
        guard phase != .loading else { return }
        clear()
        guard confirmedFullIdentity, TMobileOpenCellIDSupport.validToken(token) else {
            phase = .failed; message = TMobileOpenCellIDFailure.invalidInput.message; return
        }
        let current = generation
        phase = .loading
        do {
            try Task.checkCancellation()
            let url = try TMobileOpenCellIDSupport.requestURL(identity: identity, token: token)
            let config = configuration.copy() as! URLSessionConfiguration
            config.urlCache = nil; config.requestCachePolicy = .reloadIgnoringLocalCacheData
            config.httpCookieStorage = nil; config.httpShouldSetCookies = false; config.urlCredentialStorage = nil
            config.httpAdditionalHeaders = nil; config.connectionProxyDictionary = [:]
            config.timeoutIntervalForRequest = 15; config.timeoutIntervalForResource = 15; config.waitsForConnectivity = false
            let transport = TMobileOpenCellIDSessionDelegate()
            let session = URLSession(configuration: config, delegate: transport, delegateQueue: nil)
            self.session = session
            var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
            request.httpMethod = "GET"; request.httpShouldHandleCookies = false
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            let (data, response) = try await transport.send(request, session: session)
            try Task.checkCancellation()
            guard generation == current else { return }
            guard response.url == url else { throw TMobileOpenCellIDFailure.invalidResponse }
            if response.statusCode == 401 || response.statusCode == 403 { throw TMobileOpenCellIDFailure.authentication }
            if response.statusCode == 429 { throw TMobileOpenCellIDFailure.limit }
            guard (200...299).contains(response.statusCode) else { throw TMobileOpenCellIDFailure.unavailable }
            result = try TMobileOpenCellIDSupport.parse(data, requested: identity)
            phase = .ready; message = nil
            self.session?.invalidateAndCancel(); self.session = nil
        } catch {
            guard generation == current else { return }
            session?.invalidateAndCancel(); session = nil; result = nil
            phase = .failed
            if error is CancellationError || (error as? URLError)?.code == .cancelled {
                message = TMobileOpenCellIDFailure.cancelled.message
            } else { message = ((error as? TMobileOpenCellIDFailure) ?? .unavailable).message }
        }
    }

    func clear() {
        generation += 1
        session?.invalidateAndCancel(); session = nil
        result = nil; message = nil; phase = .idle
    }
}

private final class TMobileOpenCellIDTaskReference: @unchecked Sendable {
    private let lock = NSLock()
    private var task: URLSessionTask?
    private var cancelled = false
    func set(_ task: URLSessionTask) { lock.withLock { self.task = task; if cancelled { task.cancel() } } }
    func cancel() { lock.withLock { cancelled = true; task?.cancel() } }
}

private final class TMobileOpenCellIDSessionDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private struct Response {
        var data = Data()
        var response: HTTPURLResponse?
        var failure: Error?
        let complete: (Result<(Data, HTTPURLResponse), Error>) -> Void
    }
    private let lock = NSLock()
    private var responses: [Int: Response] = [:]

    func send(_ request: URLRequest, session: URLSession) async throws -> (Data, HTTPURLResponse) {
        let reference = TMobileOpenCellIDTaskReference()
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
        let valid = response is HTTPURLResponse && response.expectedContentLength <= TMobileOpenCellIDSupport.maximumResponseBytes
        lock.withLock {
            responses[dataTask.taskIdentifier]?.response = response as? HTTPURLResponse
            if !valid { responses[dataTask.taskIdentifier]?.failure = TMobileOpenCellIDFailure.invalidResponse }
        }
        completionHandler(valid ? .allow : .cancel)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let cancel = lock.withLock { () -> Bool in
            guard var response = responses[dataTask.taskIdentifier] else { return true }
            if response.data.count + data.count > TMobileOpenCellIDSupport.maximumResponseBytes {
                response.failure = TMobileOpenCellIDFailure.invalidResponse; responses[dataTask.taskIdentifier] = response; return true
            }
            response.data.append(data); responses[dataTask.taskIdentifier] = response; return false
        }
        if cancel { dataTask.cancel() }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let saved = lock.withLock({ responses.removeValue(forKey: task.taskIdentifier) }) else { return }
        if let failure = saved.failure ?? error { saved.complete(.failure(failure)) }
        else if let response = saved.response { saved.complete(.success((saved.data, response))) }
        else { saved.complete(.failure(TMobileOpenCellIDFailure.invalidResponse)) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }

    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        completionHandler(challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust
                          ? .performDefaultHandling : .cancelAuthenticationChallenge, nil)
    }
}
