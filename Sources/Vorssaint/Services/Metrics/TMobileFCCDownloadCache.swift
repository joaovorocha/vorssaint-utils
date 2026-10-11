// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import CryptoKit
import Darwin
import Foundation

/// An explicit load action downloads into the app's private cache. A cache hit
/// verifies the full source identity and the bytes recorded after the official
/// client's HTTPS download; it makes no request and never touches Downloads.
actor TMobileFCCDownloadCache {
    struct CachedDownload: Sendable {
        let url: URL
        let reused: Bool
    }
    typealias Downloader = @Sendable (FCCCoverageDataFile, URL, FCCCoverageCredentials, FCCCoverageClient) async throws -> URL

    enum Failure: Error, LocalizedError, Equatable {
        case unsafeDirectory, cannotSave, invalidArchive
        var errorDescription: String? {
            switch self {
            case .unsafeDirectory: "The app’s FCC cache folder is unavailable or unsafe."
            case .cannotSave: "The FCC file could not be saved in the app’s cache. Free some disk space, then try again."
            case .invalidArchive: "The downloaded FCC file failed its local integrity check. Try loading coverage again."
            }
        }
    }

    private let directory: URL?
    private let downloader: Downloader
    private static let maximumManifestBytes = 16 * 1_024
    private static let archiveName = "coverage.zip"
    private static let manifestName = "source.json"

    init(directory: URL? = nil, downloader: @escaping Downloader = { file, destination, credentials, client in
        try await client.downloadGeoPackage(file: file, to: destination, credentials: credentials)
    }) {
        self.directory = directory
        self.downloader = downloader
    }

    func obtain(file: FCCCoverageDataFile, credentials: FCCCoverageCredentials,
                client: FCCCoverageClient) async throws -> CachedDownload {
        do {
            try Task.checkCancellation()
            let identity = try SourceIdentity(file)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            let key = Self.hex(SHA256.hash(data: try encoder.encode(identity)))
            let location = try directory ?? Self.defaultDirectory()
            let root = try Directory.open(location, create: true)
            defer { root.close() }
            if let hit = try Self.cached(identity: identity, key: key, root: root) {
                return .init(url: hit, reused: true)
            }
            try Task.checkCancellation()
            // A UUID staging directory isolates this request. Old entries remain
            // in place until the complete replacement is ready for publication.
            let stagingName = ".download-\(UUID().uuidString)"
            let staging = try root.createChild(stagingName)
            defer { staging.close(); root.removeChild(stagingName) }
            let destination = try staging.url().appendingPathComponent(Self.archiveName)
            let downloaded = try await downloader(file, destination, credentials, client)
            try Task.checkCancellation()
            guard downloaded.standardizedFileURL == destination.standardizedFileURL,
                  try root.stillNames(stagingName, directory: staging) else { throw Failure.invalidArchive }
            let fingerprint = try Self.fingerprint(in: staging)
            let manifest = Manifest(version: 1, source: identity, bytes: fingerprint.bytes, sha256: fingerprint.sha256)
            try staging.write(try encoder.encode(manifest), name: Self.manifestName)
            try Task.checkCancellation()
            // Another explicit request may have finished while this actor was
            // awaiting the download. Reuse its verified result in that case.
            if let hit = try Self.cached(identity: identity, key: key, root: root) {
                return .init(url: hit, reused: true)
            }
            guard try root.stillNames(stagingName, directory: staging) else { throw Failure.unsafeDirectory }
            try root.publish(stagingName, as: key)
            return .init(url: try root.url().appendingPathComponent(key, isDirectory: true)
                .appendingPathComponent(Self.archiveName), reused: false)
        } catch is CancellationError { throw FCCCoverageFailure.cancelled }
        catch let error as FCCCoverageFailure { throw error }
        catch let error as Failure { throw error }
        catch { throw Failure.cannotSave }
    }

    private static func defaultDirectory() throws -> URL {
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            throw Failure.cannotSave
        }
        return caches.appendingPathComponent("io.github.joaovorocha.shadowutils", isDirectory: true)
            .appendingPathComponent("FCCCoverage", isDirectory: true)
    }

    private struct SourceIdentity: Codable, Equatable {
        let fileID: String
        let providerID: String
        let providerName: String
        let stateFIPS: String
        let asOfDate: String
        let technology: String
        let speedTier: String?
        let geometry: String
        let fileName: String
        let recordCount: Int?

        init(_ file: FCCCoverageDataFile) throws {
            guard file.providerID == FCCCoverageSupport.tMobileProviderID, file.geometry == .raw,
                  FCCCoverageState.all.contains(where: { $0.fips == file.stateFIPS }),
                  FCCCoverageSupport.validDate(file.asOfDate),
                  !file.id.isEmpty, file.id.count <= 18, file.id.utf8.allSatisfy({ (48...57).contains($0) }),
                  (Int(file.id) ?? 0) > 0,
                  (file.technology == .lte && file.speedTier == nil) || (file.technology == .nr && file.speedTier != nil),
                  !file.fileName.isEmpty, file.fileName.utf8.count <= 512,
                  !file.fileName.contains("/"), !file.fileName.contains("\\"), !file.fileName.contains(".."),
                  file.fileName.utf8.allSatisfy({ $0 >= 32 && $0 != 127 }),
                  !file.providerName.isEmpty, file.providerName.utf8.count <= 1_024,
                  file.recordCount == nil || file.recordCount! >= 0 else { throw FCCCoverageFailure.invalidInput }
            fileID = file.id; providerID = file.providerID; providerName = file.providerName
            stateFIPS = file.stateFIPS; asOfDate = file.asOfDate; technology = file.technology.rawValue
            speedTier = file.speedTier?.rawValue; geometry = file.geometry.rawValue
            fileName = file.fileName; recordCount = file.recordCount
        }
    }
    private struct Manifest: Codable {
        let version: Int
        let source: SourceIdentity
        let bytes: Int
        let sha256: String
    }
    private struct Fingerprint { let bytes: Int; let sha256: String }

    private static func cached(identity: SourceIdentity, key: String, root: Directory) throws -> URL? {
        try Task.checkCancellation()
        guard let entry = try? root.child(key) else { return nil }
        defer { entry.close() }
        do {
            let bytes = try entry.read(name: manifestName, limit: maximumManifestBytes)
            let manifest = try JSONDecoder().decode(Manifest.self, from: bytes)
            guard manifest.version == 1, manifest.source == identity,
                  (4...FCCCoverageSupport.maximumDownloadBytes).contains(manifest.bytes),
                  manifest.sha256.count == 64, manifest.sha256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { return nil }
            let actual = try fingerprint(in: entry)
            guard actual.bytes == manifest.bytes, actual.sha256 == manifest.sha256,
                  try root.stillNames(key, directory: entry) else { return nil }
            return try root.url().appendingPathComponent(key, isDirectory: true).appendingPathComponent(archiveName)
        } catch is CancellationError { throw CancellationError() }
        catch { return nil }
    }

    /// A regular, single-link file only. Hashing is streaming and checks both the
    /// starting size and actual bytes, including growth during the read.
    private static func fingerprint(in directory: Directory) throws -> Fingerprint {
        let fd = try directory.openFile(archiveName)
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? file.close() }
        var before = stat()
        guard fstat(fd, &before) == 0, before.st_size >= 4,
              before.st_size <= FCCCoverageSupport.maximumDownloadBytes else { throw Failure.invalidArchive }
        var digest = SHA256(); var count = 0; var prefix = Data()
        while true {
            try Task.checkCancellation()
            let chunk = try file.read(upToCount: 64 * 1_024) ?? Data()
            if chunk.isEmpty { break }
            guard chunk.count <= FCCCoverageSupport.maximumDownloadBytes - count else { throw Failure.invalidArchive }
            if prefix.count < 4 { prefix.append(chunk.prefix(4 - prefix.count)) }
            count += chunk.count; digest.update(data: chunk)
        }
        var after = stat()
        guard prefix == Data([0x50, 0x4b, 0x03, 0x04]), count == before.st_size,
              fstat(fd, &after) == 0, before.st_size == after.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
              before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec else { throw Failure.invalidArchive }
        return .init(bytes: count, sha256: hex(digest.finalize()))
    }
    private static func hex<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
        digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Directory descriptors pin writes and cleanup. Every path component is
    /// opened with NOFOLLOW, so pre-existing directory/file symlinks are rejected.
    private final class Directory {
        let fd: Int32
        init(_ fd: Int32) { self.fd = fd }
        func close() { Darwin.close(fd) }
        static func open(_ url: URL, create: Bool) throws -> Directory {
            guard url.isFileURL, url.host == nil || url.host == "" || url.host == "localhost",
                  url.query == nil, url.fragment == nil, !url.path.utf8.contains(0), url.path.hasPrefix("/") else {
                throw Failure.unsafeDirectory
            }
            let components = url.path.split(separator: "/").map(String.init)
            guard !components.isEmpty, !components.contains("."), !components.contains("..") else { throw Failure.unsafeDirectory }
            var current = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard current >= 0 else { throw Failure.unsafeDirectory }
            do {
                for component in components {
                    var next = component.withCString { openat(current, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) }
                    if next < 0, errno == ENOENT, create {
                        guard component.withCString({ mkdirat(current, $0, mode_t(0o700)) }) == 0 || errno == EEXIST else {
                            throw Failure.cannotSave
                        }
                        next = component.withCString { openat(current, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) }
                    }
                    guard next >= 0 else { throw Failure.unsafeDirectory }
                    Darwin.close(current); current = next
                }
                var info = stat()
                guard fstat(current, &info) == 0, info.st_uid == getuid(), info.st_mode & 0o077 == 0 else {
                    throw Failure.unsafeDirectory
                }
                return Directory(current)
            } catch { Darwin.close(current); throw error }
        }
        func child(_ name: String, requirePrivate: Bool = true) throws -> Directory {
            let childFD = name.withCString { openat(fd, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) }
            guard childFD >= 0 else { throw Failure.unsafeDirectory }
            var info = stat()
            guard fstat(childFD, &info) == 0, info.st_uid == getuid(), !requirePrivate || info.st_mode & 0o077 == 0 else {
                Darwin.close(childFD); throw Failure.unsafeDirectory
            }
            return Directory(childFD)
        }
        func createChild(_ name: String) throws -> Directory {
            guard name.withCString({ mkdirat(fd, $0, mode_t(0o700)) }) == 0 else { throw Failure.cannotSave }
            do { return try child(name) }
            catch { removeChild(name); throw error }
        }
        func url() throws -> URL {
            var path = [CChar](repeating: 0, count: Int(MAXPATHLEN))
            guard fcntl(fd, F_GETPATH, &path) == 0 else { throw Failure.unsafeDirectory }
            let url = URL(fileURLWithPath: String(cString: path), isDirectory: true)
            // F_GETPATH resolves a renamed ancestor; reopen without following
            // symlinks and verify this pathname still names the pinned directory.
            let reopened = try Self.open(url, create: false)
            defer { reopened.close() }
            guard same(as: reopened) else { throw Failure.unsafeDirectory }
            return url
        }
        func same(as other: Directory) -> Bool {
            var lhs = stat(); var rhs = stat()
            return fstat(fd, &lhs) == 0 && fstat(other.fd, &rhs) == 0 && lhs.st_dev == rhs.st_dev && lhs.st_ino == rhs.st_ino
        }
        func stillNames(_ name: String, directory: Directory) throws -> Bool {
            guard let current = try? child(name) else { return false }
            defer { current.close() }; return current.same(as: directory)
        }
        func openFile(_ name: String) throws -> Int32 {
            let descriptor = name.withCString { openat(fd, $0, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC) }
            guard descriptor >= 0 else { throw Failure.invalidArchive }
            var info = stat()
            guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
                  info.st_nlink == 1, info.st_uid == getuid() else {
                Darwin.close(descriptor); throw Failure.invalidArchive
            }
            return descriptor
        }
        func read(name: String, limit: Int) throws -> Data {
            let descriptor = try openFile(name)
            let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            defer { try? file.close() }
            var info = stat()
            guard fstat(descriptor, &info) == 0, info.st_size >= 0, info.st_size <= limit else { throw Failure.invalidArchive }
            let data = try file.read(upToCount: limit + 1) ?? Data()
            guard data.count == info.st_size, data.count <= limit else { throw Failure.invalidArchive }
            return data
        }
        func write(_ data: Data, name: String) throws {
            let descriptor = name.withCString { openat(fd, $0, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600)) }
            guard descriptor >= 0 else { throw Failure.cannotSave }
            let output = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            defer { try? output.close() }
            try output.write(contentsOf: data); try output.synchronize()
            guard fsync(fd) == 0 else { throw Failure.cannotSave }
        }
        func publish(_ staging: String, as destination: String) throws {
            // EXCL never overwrites a concurrently created entry. An invalid
            // existing entry is atomically swapped only after the new one is ready.
            let result = staging.withCString { source in destination.withCString { target in
                renameatx_np(fd, source, fd, target, UInt32(RENAME_EXCL))
            } }
            if result != 0 {
                guard errno == EEXIST else { throw Failure.cannotSave }
                guard staging.withCString({ source in destination.withCString { target in
                    renameatx_np(fd, source, fd, target, UInt32(RENAME_SWAP))
                } }) == 0 else { throw Failure.cannotSave }
            }
            // Publication has committed; a later fsync error must not remove the
            // published entry. It is still validated before any subsequent reuse.
            _ = fsync(fd)
        }
        func removeChild(_ name: String) {
            var info = stat()
            guard name.withCString({ fstatat(fd, $0, &info, AT_SYMLINK_NOFOLLOW) }) == 0 else { return }
            if info.st_mode & S_IFMT == S_IFDIR {
                guard let child = try? self.child(name, requirePrivate: false) else { return }
                let listingFD = dup(child.fd)
                if let listing = fdopendir(listingFD) {
                    while let item = readdir(listing) {
                        let entry = withUnsafePointer(to: &item.pointee.d_name) {
                            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
                        }
                        if entry != "." && entry != ".." { child.removeChild(entry) }
                    }
                    closedir(listing)
                } else if listingFD >= 0 { Darwin.close(listingFD) }
                child.close()
                _ = name.withCString { unlinkat(fd, $0, AT_REMOVEDIR) }
            } else { _ = name.withCString { unlinkat(fd, $0, 0) } }
        }
    }
}
