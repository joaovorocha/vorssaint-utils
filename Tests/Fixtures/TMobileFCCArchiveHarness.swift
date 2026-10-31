// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Darwin
import Foundation
import zlib

@main
struct TMobileFCCArchiveTests {
    private static var checks = 0
    private static var failures = 0

    static func main() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("fcc-archive-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let destination = folder.appendingPathComponent("output")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        let archive = folder.appendingPathComponent("fixture.zip")
        let sentinel = destination.appendingPathComponent("sample.gpkg")
        try Data("existing file".utf8).write(to: sentinel)
        let payload = randomBytes(280_000)

        func extract(_ data: Data, cancellationCheck: @escaping () throws -> Void = {}) throws -> URL {
            try data.write(to: archive)
            return try TMobileFCCArchiveSupport.extractGeoPackage(from: archive, to: destination, cancellationCheck: cancellationCheck)
        }
        func expectRejected(_ data: Data, _ name: String, expected: TMobileFCCArchiveSupport.ArchiveError? = nil) {
            let before = contents(destination)
            do {
                let result = try extract(data)
                expect(false, "rejects \(name)")
                try? FileManager.default.removeItem(at: result)
            } catch {
                expect(expected == nil || (error as? TMobileFCCArchiveSupport.ArchiveError) == expected,
                       "rejects \(name) with the expected error")
            }
            expect(contents(destination) == before, "\(name) leaves no extracted file")
        }

        for deflated in [false, true] {
            let result = try extract(makeZIP(payload: payload, deflated: deflated))
            expect(try Data(contentsOf: result) == payload, "\(deflated ? "deflated" : "stored") bytes round trip")
            expect(result.deletingLastPathComponent().standardizedFileURL.path == destination.standardizedFileURL.path
                       && result.pathExtension == "gpkg", "output is in the caller's folder")
            let permissions = try FileManager.default.attributesOfItem(atPath: result.path)[.posixPermissions] as? NSNumber
            expect(permissions?.intValue == 0o600, "output permissions are private")
            try FileManager.default.removeItem(at: result)
        }
        let first = try extract(makeZIP(payload: payload))
        let second = try extract(makeZIP(payload: payload))
        expect(first != second, "repeated imports create distinct files")
        expect(try Data(contentsOf: sentinel) == Data("existing file".utf8), "an existing destination file is never overwritten")
        try FileManager.default.removeItem(at: first)
        try FileManager.default.removeItem(at: second)

        let ordinary = makeZIP(payload: Data("a small GeoPackage fixture".utf8))
        for count in [0, 1, 21, 30, ordinary.count - 1] {
            expectRejected(Data(ordinary.prefix(count)), "truncation at \(count)")
        }
        expectRejected(ordinary + Data([0]), "trailing bytes")
        var wrong = ordinary
        wrong[0] = 0
        expectRejected(wrong, "invalid local signature")
        wrong = ordinary
        wrong[ordinary.count - 22] = 0
        expectRejected(wrong, "missing end record")
        wrong = ordinary
        wrong.put16(2, at: wrong.count - 22 + 10)
        expectRejected(wrong, "multiple entries", expected: .unsupportedArchive)
        wrong = ordinary
        wrong.put16(1, at: wrong.count - 22 + 4)
        expectRejected(wrong, "multiple disks", expected: .unsupportedArchive)
        wrong = ordinary
        wrong.put32(UInt32.max, at: wrong.count - 22 + 16)
        expectRejected(wrong, "ZIP64 central offset", expected: .unsupportedArchive)

        for name in ["../sample.gpkg", "nested/sample.gpkg", "nested\\sample.gpkg", "/sample.gpkg", "C:sample.gpkg", ".sample.gpkg", "sample..gpkg", "sample.txt", "sample.gpkg/", "sample\0.gpkg", "caf\u{00e9}.gpkg"] {
            expectRejected(makeZIP(payload: payload, name: name), "unsafe name \(name.debugDescription)", expected: .unsafeFile)
        }
        expectRejected(makeZIP(payload: payload, attributes: 0o120777 << 16), "symbolic link", expected: .unsafeFile)
        expectRejected(makeZIP(payload: payload, attributes: 0o040755 << 16), "Unix directory", expected: .unsafeFile)
        expectRejected(makeZIP(payload: payload, attributes: 0x10), "DOS directory", expected: .unsafeFile)
        expectRejected(makeZIP(payload: payload, attributes: 0o020600 << 16), "device node", expected: .unsafeFile)
        for flags: UInt16 in [1, 8, 0x40, 0x2000] {
            expectRejected(makeZIP(payload: payload, flags: flags), "unsupported flags \(flags)", expected: .unsupportedArchive)
        }
        expectRejected(makeZIP(payload: payload, methodOverride: 12), "unsupported compression", expected: .unsupportedArchive)
        expectRejected(makeZIP(payload: payload, version: 45), "ZIP64 extraction version", expected: .unsupportedArchive)
        for tag: UInt16 in [1, 0x17, 0x9901, 0x7075] {
            var extra = Data(); extra.append16(tag); extra.append16(0)
            expectRejected(makeZIP(payload: payload, extra: extra), "unsupported extra \(tag)", expected: .unsupportedArchive)
        }
        expectRejected(makeZIP(payload: payload, extra: Data([0x55])), "truncated extra header")
        expectRejected(makeZIP(payload: payload, extra: Data([0x55, 0x54, 5, 0, 1])), "truncated extra value")
        var safeExtra = Data(); safeExtra.append16(0x5455); safeExtra.append16(1); safeExtra.append(0)
        let withExtra = try extract(makeZIP(payload: payload, flags: 0x800, extra: safeExtra, comment: Data("FCC".utf8)))
        expect(try Data(contentsOf: withExtra) == payload, "ordinary metadata, UTF-8 flag and archive comments are accepted")
        try FileManager.default.removeItem(at: withExtra)

        let centralOffset = Int(ordinary.u32(ordinary.count - 22 + 16))
        for (offset, label) in [(centralOffset + 8, "flags"), (centralOffset + 16, "CRC"), (centralOffset + 12, "timestamp"), (centralOffset + 20, "compressed size"), (centralOffset + 24, "expanded size"), (centralOffset + 46, "filename")] {
            wrong = ordinary; wrong[offset] ^= 1
            expectRejected(wrong, "local/central \(label) mismatch")
        }
        wrong = ordinary; wrong.put32(1, at: centralOffset + 42)
        expectRejected(wrong, "nonzero local-header offset", expected: .unsupportedArchive)
        wrong = ordinary; wrong.put32(UInt32.max, at: centralOffset + 24)
        expectRejected(wrong, "ZIP64 output sentinel", expected: .unsupportedArchive)
        wrong = ordinary; wrong.put32(1_073_741_825, at: centralOffset + 24)
        expectRejected(wrong, "output above one GiB", expected: .sizeLimit)
        expectRejected(makeZIP(payload: Data(repeating: 65, count: 200_000), deflated: true), "excessive expansion ratio", expected: .sizeLimit)

        wrong = ordinary; wrong[30 + "sample.gpkg".utf8.count] ^= 1
        expectRejected(wrong, "stored CRC failure", expected: .checksumMismatch)
        var brokenDeflate = makeZIP(payload: payload, deflated: true)
        brokenDeflate[30 + "sample.gpkg".utf8.count] = 0x07
        expectRejected(brokenDeflate, "invalid deflate stream")
        let compressed = rawDeflate(payload)
        expectRejected(makeZIP(payload: payload, deflated: true, compressedOverride: compressed + Data([0])), "bytes after deflate end")
        expectRejected(makeZIP(payload: payload, deflated: true, compressedOverride: compressed.dropLast()), "truncated deflate stream")
        expectRejected(makeZIP(payload: payload, deflated: true, declaredOutput: UInt32(payload.count - 1)), "deflate output over declared budget", expected: .sizeLimit)
        expectRejected(makeZIP(payload: payload, deflated: true, declaredOutput: UInt32(payload.count + 1)), "deflate output under declared size")
        expectRejected(makeZIP(payload: payload, deflated: true, checksumOverride: 0), "deflated CRC failure", expected: .checksumMismatch)

        let beforeCancellation = contents(destination)
        for cancelledAt in [1, 14] {
            var calls = 0
            do {
                _ = try extract(makeZIP(payload: payload, deflated: true)) {
                    calls += 1
                    if calls == cancelledAt { throw CancellationError() }
                }
                expect(false, "cancellation at checkpoint \(cancelledAt) throws")
            } catch is CancellationError {
                expect(true, "cancellation at checkpoint \(cancelledAt) propagates")
            } catch { expect(false, "cancellation propagates its type: \(error)") }
            expect(contents(destination) == beforeCancellation, "cancellation at checkpoint \(cancelledAt) cleans output")
        }

        let oversized = folder.appendingPathComponent("oversized.zip")
        FileManager.default.createFile(atPath: oversized.path, contents: nil)
        let sparse = try FileHandle(forWritingTo: oversized)
        try sparse.truncate(atOffset: 536_870_913); try sparse.close()
        do {
            _ = try TMobileFCCArchiveSupport.extractGeoPackage(from: oversized, to: destination)
            expect(false, "archive above 512 MiB is refused")
        } catch { expect(error as? TMobileFCCArchiveSupport.ArchiveError == .sizeLimit, "archive above 512 MiB is refused before reading") }
        let symlink = folder.appendingPathComponent("symlink.zip")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: archive)
        do {
            _ = try TMobileFCCArchiveSupport.extractGeoPackage(from: symlink, to: destination)
            expect(false, "input symlink is refused")
        } catch { expect(error as? TMobileFCCArchiveSupport.ArchiveError == .unsafeFile, "input symlink is refused") }
        let pipe = folder.appendingPathComponent("pipe.zip")
        expect(pipe.path.withCString { mkfifo($0, mode_t(0o600)) } == 0, "FIFO fixture is created")
        do {
            _ = try TMobileFCCArchiveSupport.extractGeoPackage(from: pipe, to: destination)
            expect(false, "nonregular input is refused without blocking")
        } catch { expect(error as? TMobileFCCArchiveSupport.ArchiveError == .unsafeFile, "nonregular input is refused without blocking") }
        let linkedDestination = folder.appendingPathComponent("linked-output")
        try FileManager.default.createSymbolicLink(at: linkedDestination, withDestinationURL: destination)
        for target in [linkedDestination, URL(fileURLWithPath: linkedDestination.path, isDirectory: true)] {
            do {
                _ = try TMobileFCCArchiveSupport.extractGeoPackage(from: archive, to: target)
                expect(false, "destination symlink is refused, including directory URLs")
            } catch { expect(error as? TMobileFCCArchiveSupport.ArchiveError == .destinationUnavailable, "destination symlink is refused, including directory URLs") }
        }

        if CommandLine.arguments.count == 2 {
            let official = URL(fileURLWithPath: CommandLine.arguments[1])
            let result = try TMobileFCCArchiveSupport.extractGeoPackage(from: official, to: destination)
            let info = try FileManager.default.attributesOfItem(atPath: result.path)
            expect((info[.size] as? NSNumber)?.uint64Value == 304_394_240, "specified public FCC fixture expands to the expected size")
            let file = try FileHandle(forReadingFrom: result)
            expect(try file.read(upToCount: 16) == Data("SQLite format 3\0".utf8), "specified public FCC fixture has a SQLite header")
            try file.close(); try FileManager.default.removeItem(at: result)
        }
        expect(contents(destination) == [sentinel.lastPathComponent], "only the preexisting sentinel remains")
        print("TMobileFCCArchiveTests: \(checks - failures)/\(checks) PASS")
        if failures > 0 { exit(1) }
    }

    private static func expect(_ condition: Bool, _ label: String) {
        checks += 1
        if !condition { failures += 1; print("FAIL: \(label)") }
    }

    private static func contents(_ folder: URL) -> Set<String> {
        Set((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
    }

    private static func randomBytes(_ count: Int) -> Data {
        var state: UInt32 = 0x1234_5678
        return Data((0..<count).map { _ in
            state ^= state << 13; state ^= state >> 17; state ^= state << 5
            return UInt8(truncatingIfNeeded: state)
        })
    }

    private static func rawDeflate(_ data: Data) -> Data {
        var stream = z_stream()
        precondition(deflateInit2_(&stream, Z_DEFAULT_COMPRESSION, Z_DEFLATED, -MAX_WBITS, 8, Z_DEFAULT_STRATEGY,
                                 ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK)
        defer { deflateEnd(&stream) }
        var output = [UInt8](repeating: 0, count: Int(compressBound(uLong(data.count))))
        let result = data.withUnsafeBytes { input in
            output.withUnsafeMutableBufferPointer { buffer in
                stream.next_in = UnsafeMutablePointer(mutating: input.bindMemory(to: Bytef.self).baseAddress)
                stream.avail_in = uInt(data.count)
                stream.next_out = buffer.baseAddress
                stream.avail_out = uInt(buffer.count)
                return deflate(&stream, Z_FINISH)
            }
        }
        precondition(result == Z_STREAM_END)
        return Data(output.prefix(Int(stream.total_out)))
    }

    private static func makeZIP(payload: Data, name: String = "sample.gpkg", deflated: Bool = false,
                                attributes: UInt32 = 0o100644 << 16, flags: UInt16 = 0, version: UInt16 = 20,
                                methodOverride: UInt16? = nil, extra: Data = Data(), comment: Data = Data(),
                                compressedOverride: Data? = nil, declaredOutput: UInt32? = nil,
                                checksumOverride: UInt32? = nil) -> Data {
        let nameData = Data(name.utf8)
        let compressed = compressedOverride ?? (deflated ? rawDeflate(payload) : payload)
        let checksum = checksumOverride ?? payload.withUnsafeBytes { UInt32(crc32(0, $0.bindMemory(to: Bytef.self).baseAddress, uInt(payload.count))) }
        let method = methodOverride ?? (deflated ? 8 : 0)
        var data = Data()
        data.append32(0x0403_4b50); data.append16(version); data.append16(flags); data.append16(method)
        data.append16(0); data.append16(0); data.append32(checksum)
        data.append32(UInt32(compressed.count)); data.append32(declaredOutput ?? UInt32(payload.count))
        data.append16(UInt16(nameData.count)); data.append16(UInt16(extra.count))
        data.append(nameData); data.append(extra); data.append(compressed)
        let centralOffset = data.count
        data.append32(0x0201_4b50); data.append16(0x0314); data.append16(version)
        data.append16(flags); data.append16(method); data.append16(0); data.append16(0)
        data.append32(checksum); data.append32(UInt32(compressed.count)); data.append32(declaredOutput ?? UInt32(payload.count))
        data.append16(UInt16(nameData.count)); data.append16(UInt16(extra.count)); data.append16(0)
        data.append16(0); data.append16(0); data.append32(attributes); data.append32(0)
        data.append(nameData); data.append(extra)
        let centralSize = data.count - centralOffset
        data.append32(0x0605_4b50); data.append16(0); data.append16(0); data.append16(1); data.append16(1)
        data.append32(UInt32(centralSize)); data.append32(UInt32(centralOffset)); data.append16(UInt16(comment.count)); data.append(comment)
        return data
    }
}

private extension Data {
    mutating func append16(_ value: UInt16) { append(UInt8(truncatingIfNeeded: value)); append(UInt8(truncatingIfNeeded: value >> 8)) }
    mutating func append32(_ value: UInt32) { append16(UInt16(truncatingIfNeeded: value)); append16(UInt16(truncatingIfNeeded: value >> 16)) }
    mutating func put16(_ value: UInt16, at index: Int) { self[index] = UInt8(truncatingIfNeeded: value); self[index + 1] = UInt8(truncatingIfNeeded: value >> 8) }
    mutating func put32(_ value: UInt32, at index: Int) { put16(UInt16(truncatingIfNeeded: value), at: index); put16(UInt16(truncatingIfNeeded: value >> 16), at: index + 2) }
    func u32(_ offset: Int) -> UInt32 { UInt32(self[offset]) | UInt32(self[offset + 1]) << 8 | UInt32(self[offset + 2]) << 16 | UInt32(self[offset + 3]) << 24 }
}
