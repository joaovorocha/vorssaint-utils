// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Foundation

/// Shared by every production client. Monotonic time avoids wall-clock changes
/// allowing a request burst. Waiting consumes no FCC call and is cancellable.
actor FCCCoverageRequestLimiter {
    static let shared = FCCCoverageRequestLimiter()
    private var starts: [TimeInterval] = []
    private let now: @Sendable () -> TimeInterval
    private let sleep: @Sendable (TimeInterval) async throws -> Void
    private let maximumRequests: Int
    private let interval: TimeInterval
    init(maximumRequests: Int = 10, interval: TimeInterval = 60,
         now: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         sleep: @escaping @Sendable (TimeInterval) async throws -> Void = {
             try await Task.sleep(nanoseconds: UInt64(max(0.001, $0) * 1_000_000_000))
         }) {
        self.maximumRequests = max(1, maximumRequests); self.interval = max(0.001, interval)
        self.now = now; self.sleep = sleep
    }
    func acquire() async throws {
        while true {
            try Task.checkCancellation()
            let time = now()
            starts.removeAll { $0 <= time - interval }
            if starts.count < maximumRequests { starts.append(time); return }
            try await sleep(min(interval, max(0.001, (starts.first ?? time) + interval - time)))
        }
    }
}

/// Only explicit caller actions issue requests. No account password, credential
/// storage, location access, polling, retries, uploads or alternate API host.
actor FCCCoverageClient {
    private let configuration: URLSessionConfiguration
    private let limiter: FCCCoverageRequestLimiter
    init(configuration: URLSessionConfiguration = .ephemeral,
         limiter: FCCCoverageRequestLimiter = .shared) {
        self.configuration = configuration.copy() as! URLSessionConfiguration
        self.limiter = limiter
    }

    func checkLatestMobileCoverage(stateFIPS: String = FCCCoverageState.california.fips,
                                   credentials: FCCCoverageCredentials) async throws -> FCCCoverageCatalogue {
        do {
            guard credentials.isValid, let state = FCCCoverageState.all.first(where: { $0.fips == stateFIPS }) else {
                throw FCCCoverageFailure.invalidInput
            }
            let dateRequest = try FCCCoverageSupport.request(path: "/map/listAsOfDates", credentials: credentials)
            let dateData = try await fetch(dateRequest)
            let asOfDate = try FCCCoverageSupport.latestAvailabilityDate(dateData)
            let listRequest = try FCCCoverageSupport.request(path: "/map/downloads/listAvailabilityData/\(asOfDate)", query: [
                URLQueryItem(name: "category", value: "Provider"),
                URLQueryItem(name: "technology_type", value: "Mobile Broadband")
            ], credentials: credentials)
            let data = try await fetch(listRequest)
            try Task.checkCancellation()
            return try FCCCoverageSupport.catalogue(data, asOfDate: asOfDate, state: state)
        } catch { throw FCCCoverageFailure.safe(error) }
    }

    /// Saves a ZIP containing the selected GeoPackage. The caller chooses the
    /// destination with a save panel; no existing file is replaced implicitly.
    func downloadGeoPackage(file: FCCCoverageDataFile, to destination: URL,
                            credentials: FCCCoverageCredentials) async throws -> URL {
        let manager = FileManager.default
        var temporary: URL?
        defer { if let temporary { try? manager.removeItem(at: temporary) } }
        do {
            guard credentials.isValid, destination.isFileURL, destination.host == nil || destination.host == "" || destination.host == "localhost",
                  destination.pathExtension.lowercased() == "zip", destination.query == nil, destination.fragment == nil,
                  file.providerID == FCCCoverageSupport.tMobileProviderID,
                  file.geometry == .raw,
                  FCCCoverageState.all.contains(where: { $0.fips == file.stateFIPS }),
                  FCCCoverageSupport.validDate(file.asOfDate),
                  !file.id.isEmpty, file.id.count <= 18, file.id.utf8.allSatisfy({ (48...57).contains($0) }),
                  (Int(file.id) ?? 0) > 0 else {
                throw FCCCoverageFailure.invalidInput
            }
            guard !manager.fileExists(atPath: destination.path) else { throw FCCCoverageFailure.destinationExists }
            var isDirectory: ObjCBool = false
            guard manager.fileExists(atPath: destination.deletingLastPathComponent().path, isDirectory: &isDirectory), isDirectory.boolValue else {
                throw FCCCoverageFailure.fileSystem
            }
            let request = try FCCCoverageSupport.request(path: "/map/downloads/downloadFile/availability/\(file.id)/2",
                                                        credentials: credentials, acceptsZIP: true)
            try Task.checkCancellation()
            let partial = destination.deletingLastPathComponent().appendingPathComponent(".fcc-download-\(UUID().uuidString).partial")
            temporary = partial
            guard manager.createFile(atPath: partial.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                throw FCCCoverageFailure.fileSystem
            }
            _ = try await fetch(request, archive: partial)
            try Task.checkCancellation()
            // moveItem refuses an existing destination, including one created
            // while the download was in progress. Same-directory rename is atomic.
            guard !manager.fileExists(atPath: destination.path) else { throw FCCCoverageFailure.destinationExists }
            do { try manager.moveItem(at: partial, to: destination) }
            catch { throw FCCCoverageFailure.fileSystem }
            temporary = nil
            return destination
        } catch { throw FCCCoverageFailure.safe(error) }
    }

    private func fetch(_ request: URLRequest, archive: URL? = nil) async throws -> Data {
        try Task.checkCancellation()
        try await limiter.acquire()
        try Task.checkCancellation()
        let config = configuration.copy() as! URLSessionConfiguration
        config.urlCache = nil; config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.httpCookieStorage = nil; config.httpShouldSetCookies = false; config.urlCredentialStorage = nil
        config.httpAdditionalHeaders = nil; config.connectionProxyDictionary = [:]
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = archive == nil ? 60 : 600
        config.waitsForConnectivity = false
        let transport = try FCCCoverageTransport(archive: archive)
        let session = URLSession(configuration: config, delegate: transport, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        return try await transport.send(request, session: session)
    }
}

private final class FCCCoverageTaskReference: @unchecked Sendable {
    private let lock = NSLock()
    private var task: URLSessionTask?
    private var cancelled = false
    func set(_ task: URLSessionTask) { lock.withLock { self.task = task; if cancelled { task.cancel() } } }
    func cancel() { lock.withLock { cancelled = true; task?.cancel() } }
}

private final class FCCCoverageTransport: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private let archive: URL?
    private var output: FileHandle?
    private var data = Data()
    private var prefix = Data()
    private var bytes = 0
    private var response: HTTPURLResponse?
    private var failure: Error?
    private var requested: URL?
    private var complete: ((Result<Data, Error>) -> Void)?
    private var byteLimit: Int { archive == nil ? FCCCoverageSupport.maximumMetadataBytes : FCCCoverageSupport.maximumDownloadBytes }

    init(archive: URL?) throws {
        self.archive = archive
        if let archive {
            do { output = try FileHandle(forWritingTo: archive) }
            catch { throw FCCCoverageFailure.fileSystem }
        }
    }
    deinit { try? output?.close() }
    func send(_ request: URLRequest, session: URLSession) async throws -> Data {
        let reference = FCCCoverageTaskReference()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let task = session.dataTask(with: request)
                lock.withLock {
                    requested = request.url
                    complete = { continuation.resume(with: $0) }
                }
                reference.set(task); task.resume()
            }
        } onCancel: { reference.cancel() }
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        let valid = lock.withLock { () -> Bool in
            do {
                guard let http = response as? HTTPURLResponse, let requested else { throw FCCCoverageFailure.invalidResponse }
                try FCCCoverageSupport.checkHTTP(http, requested: requested)
                let mime = (http.mimeType ?? "").lowercased()
                if archive == nil {
                    guard mime == "application/json" || mime.hasSuffix("+json") else { throw FCCCoverageFailure.invalidResponse }
                } else {
                    guard ["application/zip", "application/x-zip-compressed", "application/octet-stream"].contains(mime) else {
                        throw FCCCoverageFailure.invalidResponse
                    }
                }
                guard response.expectedContentLength <= byteLimit else { throw FCCCoverageFailure.tooLarge }
                self.response = http
                return true
            } catch { failure = error; return false }
        }
        completionHandler(valid ? .allow : .cancel)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive chunk: Data) {
        let cancel = lock.withLock { () -> Bool in
            guard failure == nil, chunk.count <= byteLimit - bytes else {
                if failure == nil { failure = FCCCoverageFailure.tooLarge }
                return true
            }
            bytes += chunk.count
            if archive != nil {
                prefix.append(chunk.prefix(max(0, 4 - prefix.count)))
                if prefix.count == 4, prefix != Data([0x50, 0x4b, 0x03, 0x04]) {
                    failure = FCCCoverageFailure.invalidResponse; return true
                }
                do { try output?.write(contentsOf: chunk) }
                catch { failure = FCCCoverageFailure.fileSystem; return true }
            } else { data.append(chunk) }
            return false
        }
        if cancel { dataTask.cancel() }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let result = lock.withLock { () -> (((Result<Data, Error>) -> Void), Result<Data, Error>)? in
            guard let callback = complete else { return nil }
            complete = nil
            do { try output?.close(); output = nil }
            catch { if failure == nil { failure = FCCCoverageFailure.fileSystem } }
            if let failure = failure ?? error { return (callback, .failure(failure)) }
            guard let response else { return (callback, .failure(FCCCoverageFailure.invalidResponse)) }
            let encoding = response.value(forHTTPHeaderField: "Content-Encoding")?.lowercased()
            guard (encoding != nil && encoding != "identity")
                    || response.expectedContentLength < 0 || response.expectedContentLength == bytes else {
                return (callback, .failure(FCCCoverageFailure.invalidResponse))
            }
            guard archive == nil || prefix == Data([0x50, 0x4b, 0x03, 0x04]) else {
                return (callback, .failure(FCCCoverageFailure.invalidResponse))
            }
            return (callback, .success(data))
        }
        if let (callback, result) = result { callback(result) }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        lock.withLock { failure = FCCCoverageFailure.invalidResponse }
        completionHandler(nil)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        completionHandler(challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust
                          ? .performDefaultHandling : .cancelAuthenticationChallenge, nil)
    }
}
