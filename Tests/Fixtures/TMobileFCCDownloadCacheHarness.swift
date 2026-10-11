// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Darwin
import Foundation

@main
struct FCCDownloadCacheHarness {
    static let manager = FileManager.default
    static let credentials = FCCCoverageCredentials(username: "cache-fixture@example.invalid", token: "synthetic-cache-token")
    static let zip = Data([0x50, 0x4b, 0x03, 0x04] + Array(repeating: 0x36, count: 190_000))
    static func source(id: String = "12345", provider: String = "130403", providerName: String = "T-Mobile fixture",
                       state: String = "06", date: String = "2025-12-31", technology: FCCCoverageTechnology = .nr,
                       tier: FCCCoverageSpeedTier? = .thirtyFiveThree, geometry: FCCCoverageGeometry = .raw,
                       name: String = "fixture.gpkg", count: Int? = 42) -> FCCCoverageDataFile {
        .init(id: id, providerID: provider, providerName: providerName, stateFIPS: state, technology: technology,
              speedTier: tier, geometry: geometry, fileName: name, recordCount: count, asOfDate: date)
    }
    static func root() throws -> URL {
        let url = URL(fileURLWithPath: "/private/tmp/fcc-download-cache-\(UUID().uuidString)", isDirectory: true)
        try manager.createDirectory(at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        return url
    }
    static func client() -> FCCCoverageClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CacheURLProtocol.self]
        return .init(configuration: configuration, limiter: FCCCoverageRequestLimiter(maximumRequests: 10_000))
    }
    static func cache(_ root: URL, counter: Counter = Counter()) -> TMobileFCCDownloadCache {
        .init(directory: root, downloader: { _, url, _, _ in
            await counter.increment(); try zip.write(to: url); return url
        })
    }
    static func names(_ root: URL) -> [String] { (try? manager.contentsOfDirectory(atPath: root.path)) ?? [] }
    static func main() async throws {
        let suite = Suite()
        try await lifecycle(suite)
        try await identity(suite)
        try await invalidation(suite)
        try await integrity(suite)
        try await symlinks(suite)
        try await failures(suite)
        try await cancellation(suite)
        try await concurrency(suite)
        print("\(suite.passed) PASS; \(suite.failed) FAIL — FCC automatic download cache (synthetic data only)")
        if suite.failed != 0 { exit(1) }
    }
    static func lifecycle(_ suite: Suite) async throws {
        let parent = try root(); defer { try? manager.removeItem(at: parent) }
        let location = parent.appendingPathComponent("private/cache")
        let service = TMobileFCCDownloadCache(directory: location)
        suite.expect(!manager.fileExists(atPath: location.path), "constructing the cache creates no files")
        CacheURLProtocol.reset()
        let result = try await service.obtain(file: source(), credentials: credentials, client: client())
        suite.expect(!result.reused && (try? Data(contentsOf: result.url)) == zip, "first explicit load downloads the complete ZIP into app cache")
        suite.expect(CacheURLProtocol.requests == 1 && CacheURLProtocol.canonicalRequest, "production client uses only the canonical FCC HTTPS download request")
        suite.expect(result.url.path.hasPrefix(location.path + "/") && result.url.lastPathComponent == "coverage.zip",
                     "result is app-managed and uses no provider filename as a path")
        suite.expect(names(location).count == 1 && names(location).allSatisfy { !$0.hasPrefix(".") }, "successful load leaves one committed entry and no staging files")
        let manifest = result.url.deletingLastPathComponent().appendingPathComponent("source.json")
        let text = try String(contentsOf: manifest, encoding: .utf8)
        suite.expect(!text.contains("synthetic-cache-token") && !text.contains("cache-fixture@example.invalid"), "cache metadata contains no account email or token")
        for key in ["fileID", "providerID", "providerName", "stateFIPS", "asOfDate", "technology", "speedTier", "geometry", "fileName", "recordCount", "sha256", "bytes"] {
            suite.expect(text.contains("\"\(key)\""), "manifest retains exact public source identity and local integrity fields: \(key)")
        }
        let freshInstance = TMobileFCCDownloadCache(directory: location)
        let hit = try await freshInstance.obtain(file: source(), credentials: .init(username: "", token: ""), client: client())
        suite.expect(hit.reused && hit.url == result.url && CacheURLProtocol.requests == 1, "persisted verified cache reuse makes no request, including offline credential-free reuse")
        var info = stat()
        _ = stat(location.path, &info)
        suite.expect(info.st_mode & 0o077 == 0, "new cache directories are private to the current Mac account")
    }
    static func identity(_ suite: Suite) async throws {
        let location = try root(); defer { try? manager.removeItem(at: location) }
        let counter = Counter(); let service = cache(location, counter: counter)
        let variants = [source(), source(id: "12346"), source(providerName: "Different public name"), source(state: "32"),
                        source(date: "2025-06-30"), source(technology: .lte, tier: nil), source(tier: .sevenOne),
                        source(name: "other.gpkg"), source(count: nil), source(count: 43)]
        var paths = Set<String>()
        for variant in variants {
            let result = try await service.obtain(file: variant, credentials: credentials, client: client())
            suite.expect(!result.reused, "changed source identity is downloaded separately")
            paths.insert(result.url.path)
        }
        suite.expect(paths.count == variants.count && names(location).count == variants.count,
                     "file ID, provider name, state, date, technology, tier, name and count each affect cache identity")
        for variant in variants {
            let hit = try await service.obtain(file: variant, credentials: credentials, client: client())
            suite.expect(hit.reused, "each exact source identity reuses its own verified entry")
        }
        suite.expect(await counter.value == variants.count, "cache reuse does not re-download any exact identity")
        let invalid = [source(id: "../1"), source(provider: "999999"), source(state: "99"), source(date: "2025-02-29"),
                       source(technology: .lte), source(tier: nil), source(geometry: .hexagons), source(name: "../../other.zip"),
                       source(count: -1)]
        for variant in invalid {
            await suite.failure(FCCCoverageFailure.invalidInput, {
                _ = try await service.obtain(file: variant, credentials: credentials, client: client())
            }, "invalid or unsupported source identity is rejected")
        }
        suite.expect(await counter.value == variants.count, "invalid identity never triggers a download")
    }
    static func invalidation(_ suite: Suite) async throws {
        let location = try root(); defer { try? manager.removeItem(at: location) }
        let counter = Counter(); let service = cache(location, counter: counter)
        let rejected = try await service.obtain(file: source(), credentials: credentials, client: client())
        let other = try await service.obtain(file: source(id: "98765"), credentials: credentials, client: client())
        let otherBytes = try Data(contentsOf: other.url)
        // This fixture has a ZIP prefix but no central directory: it passes the
        // transport byte gate and represents a later structural import failure.
        try await service.invalidate(file: source())
        suite.expect(!manager.fileExists(atPath: rejected.url.path) && names(location).count == 1,
                     "structural failure invalidates only the exact source entry")
        suite.expect((try? Data(contentsOf: other.url)) == otherBytes,
                     "invalidating a source preserves a different valid cache entry")
        let retried = try await service.obtain(file: source(), credentials: credentials, client: client())
        let downloads = await counter.value
        suite.expect(!retried.reused && downloads == 3 && (try? Data(contentsOf: retried.url)) == zip,
                     "the next explicit load downloads again instead of reusing a structurally rejected ZIP")
        let otherHit = try await service.obtain(file: source(id: "98765"), credentials: credentials, client: client())
        suite.expect(otherHit.reused && otherHit.url == other.url, "unrelated valid entry remains reusable after recovery")
        try await service.invalidate(file: source(id: "11111"))
        suite.expect(names(location).count == 2, "invalidating an absent exact source leaves all other entries intact")
        let unopened = location.appendingPathComponent("does-not-exist/cache")
        try await cache(unopened).invalidate(file: source())
        suite.expect(!manager.fileExists(atPath: location.appendingPathComponent("does-not-exist").path),
                     "invalidation never creates a missing cache or its ancestors")
        await suite.failure(FCCCoverageFailure.invalidInput, {
            try await service.invalidate(file: source(id: "../../user-file"))
        }, "invalidation rejects a source that could become a user path")

        let manifest = retried.url.deletingLastPathComponent().appendingPathComponent("source.json")
        let originalManifest = try Data(contentsOf: manifest)
        var value = try JSONSerialization.jsonObject(with: originalManifest) as! [String: Any]
        var identity = value["source"] as! [String: Any]; identity["fileID"] = "98765"; value["source"] = identity
        try JSONSerialization.data(withJSONObject: value).write(to: manifest)
        try await service.invalidate(file: source())
        suite.expect(manager.fileExists(atPath: retried.url.path), "invalidation does not delete an entry with mismatched source metadata")
        try originalManifest.write(to: manifest)
        try await service.invalidate(file: source())
        suite.expect(names(location).count == 1, "exact matching metadata enables safe removal after a mismatch")

        for substitution in ["root", "entry", "manifest", "archive"] {
            let cacheRoot = try root(); let outside = try root()
            defer { try? manager.removeItem(at: cacheRoot); try? manager.removeItem(at: outside) }
            let protected = outside.appendingPathComponent("outside.dat"); try zip.write(to: protected)
            let instance = cache(cacheRoot)
            let result = try await instance.obtain(file: source(), credentials: credentials, client: client())
            switch substitution {
            case "root":
                let linkedRoot = cacheRoot.appendingPathComponent("linked-cache")
                try manager.createSymbolicLink(at: linkedRoot, withDestinationURL: outside)
                await suite.failure(TMobileFCCDownloadCache.Failure.unsafeDirectory, {
                    try await cache(linkedRoot).invalidate(file: source())
                }, "invalidation rejects a symlinked cache root")
            case "entry":
                let target = result.url.deletingLastPathComponent()
                try manager.removeItem(at: target); try manager.createSymbolicLink(at: target, withDestinationURL: outside)
                try await instance.invalidate(file: source())
                let attributes = try manager.attributesOfItem(atPath: target.path)
                suite.expect(attributes[.type] as? FileAttributeType == .typeSymbolicLink,
                             "invalidation leaves an unverified entry symlink intact")
            case "manifest":
                let target = result.url.deletingLastPathComponent().appendingPathComponent("source.json")
                try manager.removeItem(at: target); try manager.createSymbolicLink(at: target, withDestinationURL: protected)
                try await instance.invalidate(file: source())
                suite.expect(manager.fileExists(atPath: result.url.path), "invalidation does not follow a manifest symlink")
            default:
                try manager.removeItem(at: result.url); try manager.createSymbolicLink(at: result.url, withDestinationURL: protected)
                try await instance.invalidate(file: source())
                suite.expect(names(cacheRoot).isEmpty, "exact source invalidation removes a substituted archive link safely")
            }
            suite.expect((try? Data(contentsOf: protected)) == zip && names(outside) == ["outside.dat"],
                         "invalidation never changes an outside symlink target")
        }
    }

    static func integrity(_ suite: Suite) async throws {
        for damage in 0..<8 {
            let location = try root(); defer { try? manager.removeItem(at: location) }
            let counter = Counter(); let service = cache(location, counter: counter)
            let original = try await service.obtain(file: source(), credentials: credentials, client: client())
            let manifest = original.url.deletingLastPathComponent().appendingPathComponent("source.json")
            switch damage {
            case 0:
                var altered = zip; altered[10] = 0x99; try altered.write(to: original.url)
            case 1: try Data("not JSON".utf8).write(to: manifest)
            case 2: try manager.removeItem(at: manifest)
            case 3:
                var value = try JSONSerialization.jsonObject(with: Data(contentsOf: manifest)) as! [String: Any]
                var source = value["source"] as! [String: Any]; source["stateFIPS"] = "32"; value["source"] = source
                try JSONSerialization.data(withJSONObject: value).write(to: manifest)
            case 4:
                let output = try FileHandle(forWritingTo: original.url)
                try output.truncate(atOffset: UInt64(FCCCoverageSupport.maximumDownloadBytes) + 1); try output.close()
            case 5: try Data(repeating: 0x20, count: 16 * 1_024 + 1).write(to: manifest)
            case 6: try Data([0x50, 0x4b, 0x03]).write(to: original.url)
            default: try manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: original.url.deletingLastPathComponent().path)
            }
            let repaired = try await service.obtain(file: source(), credentials: credentials, client: client())
            let downloads = await counter.value
            suite.expect(!repaired.reused && (try? Data(contentsOf: repaired.url)) == zip && downloads == 2,
                         "tampered, mismatched, missing, oversized and truncated cache files are replaced after verification")
            suite.expect(names(location).count == 1, "replacement commits atomically and cleans its own staging directory")
        }
    }
    static func symlinks(_ suite: Suite) async throws {
        for targetName in ["coverage.zip", "source.json", "entry", "hardlink"] {
            let location = try root(); let outside = try root()
            defer { try? manager.removeItem(at: location); try? manager.removeItem(at: outside) }
            let protected = outside.appendingPathComponent("outside.dat"); try zip.write(to: protected)
            let counter = Counter(); let service = cache(location, counter: counter)
            let result = try await service.obtain(file: source(), credentials: credentials, client: client())
            let target = targetName == "entry" ? result.url.deletingLastPathComponent() :
                result.url.deletingLastPathComponent().appendingPathComponent(targetName == "hardlink" ? "coverage.zip" : targetName)
            try manager.removeItem(at: target)
            if targetName == "hardlink" { try manager.linkItem(at: protected, to: target) }
            else { try manager.createSymbolicLink(at: target, withDestinationURL: targetName == "entry" ? outside : protected) }
            let repaired = try await service.obtain(file: source(), credentials: credentials, client: client())
            let downloads = await counter.value
            suite.expect(!repaired.reused && downloads == 2, "symlinked entries/files and hardlinked archives are never reused")
            suite.expect((try? Data(contentsOf: protected)) == zip && names(outside) == ["outside.dat"],
                         "repair removes only cache links and leaves outside targets unchanged")
        }
        for nested in [false, true] {
            let parent = try root(); let outside = try root()
            defer { try? manager.removeItem(at: parent); try? manager.removeItem(at: outside) }
            let link = parent.appendingPathComponent("link")
            try manager.createSymbolicLink(at: link, withDestinationURL: outside)
            let counter = Counter(); let service = cache(nested ? link.appendingPathComponent("child") : link, counter: counter)
            await suite.failure(TMobileFCCDownloadCache.Failure.unsafeDirectory, {
                _ = try await service.obtain(file: source(), credentials: credentials, client: client())
            }, "symlinked cache root or ancestor is rejected")
            suite.expect(await counter.value == 0 && names(outside).isEmpty, "unsafe cache roots cannot trigger network or outside writes")
        }
    }
    static func failures(_ suite: Suite) async throws {
        for variant in 0..<4 {
            let location = try root(); defer { try? manager.removeItem(at: location) }
            let service = TMobileFCCDownloadCache(directory: location, downloader: { _, url, _, _ in
                switch variant {
                case 0: try Data("<html>failed download</html>".utf8).write(to: url)
                case 1: try Data([0x50, 0x4b]).write(to: url)
                case 2:
                    try zip.write(to: url)
                    throw FCCCoverageFailure.network
                default:
                    try zip.write(to: url)
                    return url.deletingLastPathComponent().appendingPathComponent("not-the-destination.zip")
                }
                return url
            })
            do { _ = try await service.obtain(file: source(), credentials: credentials, client: client())
                suite.expect(false, "failed download is rejected")
            } catch { suite.expect(true, "malformed, incomplete, interrupted and wrong-destination downloads are rejected") }
            suite.expect(names(location).isEmpty, "failed operation cleans its own complete and partial files")
        }
        let location = try root(); let outside = try root()
        defer { try? manager.removeItem(at: location); try? manager.removeItem(at: outside) }
        let protected = outside.appendingPathComponent("untouched.dat"); try zip.write(to: protected)
        let service = TMobileFCCDownloadCache(directory: location, downloader: { _, url, _, _ in
            try manager.createSymbolicLink(at: url, withDestinationURL: protected); return url
        })
        await suite.failure(TMobileFCCDownloadCache.Failure.invalidArchive, {
            _ = try await service.obtain(file: source(), credentials: credentials, client: client())
        }, "symlink substituted for downloaded archive is rejected")
        suite.expect(names(location).isEmpty && (try? Data(contentsOf: protected)) == zip, "download substitution cleanup does not follow outside symlinks")
    }
    static func cancellation(_ suite: Suite) async throws {
        let location = try root(); defer { try? manager.removeItem(at: location) }
        let first = try await cache(location).obtain(file: source(), credentials: credentials, client: client())
        let oldBytes = try Data(contentsOf: first.url)
        let gate = Counter()
        let service = TMobileFCCDownloadCache(directory: location, downloader: { _, url, _, _ in
            try Data(zip.prefix(8)).write(to: url); await gate.increment()
            try await Task.sleep(nanoseconds: 10_000_000_000); return url
        })
        let task = Task { try await service.obtain(file: source(id: "54321"), credentials: credentials, client: client()) }
        while await gate.value == 0 { try await Task.sleep(nanoseconds: 1_000_000) }
        task.cancel()
        await suite.failure(FCCCoverageFailure.cancelled, { _ = try await task.value }, "cancellation stops an in-progress download")
        suite.expect(names(location).count == 1 && (try? Data(contentsOf: first.url)) == oldBytes,
                     "cancellation removes only this operation’s staging files and preserves old valid entries")
        let hit = try await service.obtain(file: source(), credentials: credentials, client: client())
        suite.expect(hit.reused && hit.url == first.url, "a preserved cache entry remains reusable after cancellation")
        let unopened = location.appendingPathComponent("never-created")
        let cancelled = Task {
            try await Task.sleep(nanoseconds: 1_000_000_000)
            return try await cache(unopened).obtain(file: source(), credentials: credentials, client: client())
        }
        cancelled.cancel()
        _ = try? await cancelled.value
        suite.expect(!manager.fileExists(atPath: unopened.path), "cancellation before obtain creates no cache folder")
    }
    static func concurrency(_ suite: Suite) async throws {
        let location = try root(); defer { try? manager.removeItem(at: location) }
        let calls = Counter()
        let service = TMobileFCCDownloadCache(directory: location, downloader: { _, url, _, _ in
            await calls.increment()
            try await Task.sleep(nanoseconds: 40_000_000)
            try zip.write(to: url); return url
        })
        async let first = service.obtain(file: source(), credentials: credentials, client: client())
        async let second = service.obtain(file: source(), credentials: credentials, client: client())
        let results = try await [first, second]
        suite.expect(results[0].url == results[1].url && results.filter(\.reused).count == 1,
                     "concurrent explicit loads converge on one verified committed entry")
        suite.expect(names(location).count == 1 && (try? Data(contentsOf: results[0].url)) == zip,
                     "concurrent staging cleanup cannot remove the committed archive")
    }
}

actor Counter {
    var value = 0
    func increment() { value += 1 }
}
final class Suite {
    var passed = 0; var failed = 0
    func expect(_ condition: Bool, _ label: String) {
        if condition { passed += 1 }
        else { failed += 1; print("FAIL: \(label)") }
    }
    func failure<E: Error & Equatable>(_ expected: E, _ action: () async throws -> Void, _ label: String) async {
        do { try await action(); expect(false, label) }
        catch { expect((error as? E) == expected, label) }
    }
}

/// Intercepts every URL; the suite never has a live-network fallback.
private final class CacheURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var count = 0
    private static var canonical = true
    static var requests: Int { lock.withLock { count } }
    static var canonicalRequest: Bool { lock.withLock { canonical } }
    static func reset() { lock.withLock { count = 0; canonical = true } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.withLock {
            Self.count += 1
            Self.canonical = Self.canonical && request.httpMethod == "GET"
                && request.url?.absoluteString == "https://broadbandmap.fcc.gov/api/public/map/downloads/downloadFile/availability/12345/2"
                && request.value(forHTTPHeaderField: "username") == "cache-fixture@example.invalid"
                && request.value(forHTTPHeaderField: "hash_value") == "synthetic-cache-token"
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                                       headerFields: ["Content-Type": "application/zip"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(FCCDownloadCacheHarness.zip.prefix(2)))
        client?.urlProtocol(self, didLoad: Data(FCCDownloadCacheHarness.zip.dropFirst(2)))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
