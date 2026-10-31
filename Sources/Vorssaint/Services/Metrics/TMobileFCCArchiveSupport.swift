// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Darwin
import Foundation
import zlib

/// Extracts the single GeoPackage in an FCC download without loading its contents
/// into memory. Call from a background worker; the caller owns the returned file
/// and removes it after importing the selected region.
enum TMobileFCCArchiveSupport {
    enum ArchiveError: Error, LocalizedError, Equatable {
        case invalidArchive
        case unsupportedArchive
        case unsafeFile
        case sizeLimit
        case checksumMismatch
        case destinationUnavailable

        var errorDescription: String? {
            switch self {
            case .invalidArchive: "The FCC download is not a complete, valid ZIP archive."
            case .unsupportedArchive: "The FCC download must contain one unencrypted GeoPackage using ordinary ZIP compression."
            case .unsafeFile: "The FCC download contains an unsafe filename or file type."
            case .sizeLimit: "The FCC download exceeds the archive size or expansion limit."
            case .checksumMismatch: "The FCC download failed its integrity check. Download it again."
            case .destinationUnavailable: "A private temporary file could not be created for the FCC download."
            }
        }
    }

    private static let maximumArchiveBytes: UInt64 = 512 * 1_024 * 1_024
    private static let maximumOutputBytes: UInt64 = 1_024 * 1_024 * 1_024
    private static let maximumExpansionRatio: UInt64 = 100
    private static let chunkBytes = 64 * 1_024

    static func extractGeoPackage(
        from archiveURL: URL,
        to destinationDirectory: URL,
        cancellationCheck: @escaping () throws -> Void = { try Task.checkCancellation() }
    ) throws -> URL {
        try cancellationCheck()
        guard archiveURL.isFileURL, destinationDirectory.isFileURL else { throw ArchiveError.unsafeFile }
        let inputFD = openDescriptor(archiveURL, flags: O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard inputFD >= 0 else { throw ArchiveError.unsafeFile }
        let input = FileHandle(fileDescriptor: inputFD, closeOnDealloc: true)
        defer { try? input.close() }
        var info = stat()
        guard fstat(inputFD, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size >= 0 else {
            throw ArchiveError.unsafeFile
        }
        let archiveBytes = UInt64(info.st_size)
        guard archiveBytes <= maximumArchiveBytes else { throw ArchiveError.sizeLimit }
        let reader = Reader(file: input, count: archiveBytes, cancellationCheck: cancellationCheck)
        let entry = try readEntry(reader)

        // openat pins creation and cleanup to this directory, including if its
        // pathname changes while a background import is running.
        let directoryFD = openDescriptor(destinationDirectory, flags: O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directoryFD >= 0 else { throw ArchiveError.destinationUnavailable }
        defer { Darwin.close(directoryFD) }
        let outputName = "fcc-\(UUID().uuidString).gpkg"
        let outputFD = outputName.withCString {
            openat(directoryFD, $0, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        }
        guard outputFD >= 0 else { throw ArchiveError.destinationUnavailable }
        let output = FileHandle(fileDescriptor: outputFD, closeOnDealloc: true)
        var succeeded = false
        var closed = false
        defer {
            if !closed { try? output.close() }
            if !succeeded { _ = outputName.withCString { unlinkat(directoryFD, $0, 0) } }
        }

        if entry.method == 0 {
            try copyStored(entry, reader: reader, output: output)
        } else {
            try inflateDeflated(entry, reader: reader, output: output)
        }
        try cancellationCheck()
        try output.synchronize()
        try output.close()
        closed = true
        succeeded = true
        return destinationDirectory.appendingPathComponent(outputName, isDirectory: false)
    }

    private static func openDescriptor(_ url: URL, flags: Int32) -> Int32 {
        var path = url.path
        guard !path.isEmpty, !path.utf8.contains(0) else { return -1 }
        // A trailing slash would make O_NOFOLLOW follow a directory symlink.
        while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
        return path.withCString { Darwin.open($0, flags) }
    }

    private struct Entry {
        var method: UInt16
        var checksum: UInt32
        var compressedBytes: UInt64
        var outputBytes: UInt64
        var dataOffset: UInt64
    }

    private struct Reader {
        let file: FileHandle
        let count: UInt64
        let cancellationCheck: () throws -> Void

        func read(at offset: UInt64, count length: Int) throws -> Data {
            try cancellationCheck()
            guard length >= 0, offset <= count, UInt64(length) <= count - offset else {
                throw ArchiveError.invalidArchive
            }
            if length == 0 { return Data() }
            try file.seek(toOffset: offset)
            guard let data = try file.read(upToCount: length), data.count == length else {
                throw ArchiveError.invalidArchive
            }
            return data
        }
    }

    private static func readEntry(_ reader: Reader) throws -> Entry {
        guard reader.count >= 22 else { throw ArchiveError.invalidArchive }
        let tailLength = Int(min(reader.count, 22 + 65_535))
        let tail = try reader.read(at: reader.count - UInt64(tailLength), count: tailLength)
        var endIndex: Int?
        for index in stride(from: tail.count - 22, through: 0, by: -1) {
            if tail.u32(index) == 0x0605_4b50,
               index + 22 + Int(tail.u16(index + 20)) == tail.count {
                endIndex = index
                break
            }
        }
        guard let endIndex else { throw ArchiveError.invalidArchive }
        let endOffset = reader.count - UInt64(tailLength) + UInt64(endIndex)
        guard tail.u16(endIndex + 4) == 0, tail.u16(endIndex + 6) == 0,
              tail.u16(endIndex + 8) == 1, tail.u16(endIndex + 10) == 1 else {
            throw ArchiveError.unsupportedArchive
        }
        let centralBytes = UInt64(tail.u32(endIndex + 12))
        let centralOffset = UInt64(tail.u32(endIndex + 16))
        guard centralBytes != UInt64(UInt32.max), centralOffset != UInt64(UInt32.max) else {
            throw ArchiveError.unsupportedArchive
        }
        guard centralOffset <= endOffset, centralBytes == endOffset - centralOffset,
              centralBytes >= 46 else { throw ArchiveError.invalidArchive }
        let central = try reader.read(at: centralOffset, count: 46)
        guard central.u32(0) == 0x0201_4b50 else { throw ArchiveError.invalidArchive }
        let version = central.u16(6)
        let flags = central.u16(8)
        let method = central.u16(10)
        let compressed = UInt64(central.u32(20))
        let expanded = UInt64(central.u32(24))
        let nameBytes = Int(central.u16(28))
        let extraBytes = Int(central.u16(30))
        let commentBytes = Int(central.u16(32))
        let attributes = central.u32(38)
        let unixType = (attributes >> 16) & 0o170000
        guard version >= 10, version <= 20, method == 0 || method == 8,
              flags & ~(method == 8 ? UInt16(0x0806) : UInt16(0x0800)) == 0,
              central.u16(34) == 0, central.u32(42) == 0 else {
            throw ArchiveError.unsupportedArchive
        }
        guard attributes & 0x18 == 0, unixType == 0 || unixType == 0o100000 else {
            throw ArchiveError.unsafeFile
        }
        guard compressed != UInt64(UInt32.max), expanded != UInt64(UInt32.max) else {
            throw ArchiveError.unsupportedArchive
        }
        guard expanded > 0, expanded <= maximumOutputBytes, compressed > 0,
              compressed <= maximumArchiveBytes,
              expanded <= compressed * maximumExpansionRatio else { throw ArchiveError.sizeLimit }
        guard method != 0 || compressed == expanded else { throw ArchiveError.invalidArchive }
        guard nameBytes > 0, nameBytes <= 255,
              UInt64(46 + nameBytes + extraBytes + commentBytes) == centralBytes else {
            throw ArchiveError.invalidArchive
        }
        let name = try reader.read(at: centralOffset + 46, count: nameBytes)
        try validateName(name)
        try validateExtra(reader.read(at: centralOffset + UInt64(46 + nameBytes), count: extraBytes))

        let local = try reader.read(at: 0, count: 30)
        guard local.u32(0) == 0x0403_4b50,
              local.u16(4) == version, local.u16(6) == flags, local.u16(8) == method,
              local.u16(10) == central.u16(12), local.u16(12) == central.u16(14),
              local.u32(14) == central.u32(16), local.u32(18) == central.u32(20),
              local.u32(22) == central.u32(24), Int(local.u16(26)) == nameBytes else {
            throw ArchiveError.invalidArchive
        }
        let localExtraBytes = Int(local.u16(28))
        guard try reader.read(at: 30, count: nameBytes) == name else { throw ArchiveError.invalidArchive }
        try validateExtra(reader.read(at: UInt64(30 + nameBytes), count: localExtraBytes))
        let dataOffset = UInt64(30 + nameBytes + localExtraBytes)
        guard dataOffset <= centralOffset, compressed == centralOffset - dataOffset else {
            throw ArchiveError.invalidArchive
        }
        return Entry(method: method, checksum: central.u32(16), compressedBytes: compressed,
                     outputBytes: expanded, dataOffset: dataOffset)
    }

    private static func validateName(_ data: Data) throws {
        guard let name = String(data: data, encoding: .utf8), !name.hasPrefix("."),
              !name.contains(".."), name.lowercased().hasSuffix(".gpkg"),
              data.allSatisfy({ $0 >= 32 && $0 <= 126 && $0 != 47 && $0 != 92 && $0 != 58 }) else {
            throw ArchiveError.unsafeFile
        }
    }

    private static func validateExtra(_ data: Data) throws {
        var offset = 0
        while offset < data.count {
            guard data.count - offset >= 4 else { throw ArchiveError.invalidArchive }
            let tag = data.u16(offset)
            let length = Int(data.u16(offset + 2))
            guard length <= data.count - offset - 4 else { throw ArchiveError.invalidArchive }
            // ZIP64, strong encryption, AES and an alternate Unicode pathname
            // are outside this single, plaintext-basename format.
            guard ![UInt16(0x0001), 0x0017, 0x9901, 0x7075].contains(tag) else {
                throw ArchiveError.unsupportedArchive
            }
            offset += 4 + length
        }
    }

    private static func copyStored(_ entry: Entry, reader: Reader, output: FileHandle) throws {
        var offset: UInt64 = 0
        var checksum = crc32(0, nil, 0)
        while offset < entry.compressedBytes {
            let count = Int(min(UInt64(chunkBytes), entry.compressedBytes - offset))
            let data = try reader.read(at: entry.dataOffset + offset, count: count)
            checksum = data.withUnsafeBytes { crc32(checksum, $0.bindMemory(to: Bytef.self).baseAddress, uInt(count)) }
            try output.write(contentsOf: data)
            offset += UInt64(count)
        }
        guard UInt32(checksum) == entry.checksum else { throw ArchiveError.checksumMismatch }
    }

    private static func inflateDeflated(_ entry: Entry, reader: Reader, output: FileHandle) throws {
        var stream = z_stream()
        guard inflateInit2_(&stream, -MAX_WBITS, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            throw ArchiveError.invalidArchive
        }
        defer { inflateEnd(&stream) }
        var buffer = [UInt8](repeating: 0, count: chunkBytes)
        var readBytes: UInt64 = 0
        var outputBytes: UInt64 = 0
        var checksum = crc32(0, nil, 0)
        var ended = false
        while !ended {
            try reader.cancellationCheck()
            let count = Int(min(UInt64(chunkBytes), entry.compressedBytes - readBytes))
            let data = try reader.read(at: entry.dataOffset + readBytes, count: count)
            readBytes += UInt64(count)
            try data.withUnsafeBytes { input in
                stream.next_in = UnsafeMutablePointer(mutating: input.bindMemory(to: Bytef.self).baseAddress)
                stream.avail_in = uInt(count)
                repeat {
                    try reader.cancellationCheck()
                    let availableBefore = stream.avail_in
                    let result = buffer.withUnsafeMutableBufferPointer { bytes in
                        stream.next_out = bytes.baseAddress
                        stream.avail_out = uInt(bytes.count)
                        return inflate(&stream, Z_NO_FLUSH)
                    }
                    let written = chunkBytes - Int(stream.avail_out)
                    guard UInt64(written) <= entry.outputBytes - outputBytes else { throw ArchiveError.sizeLimit }
                    if written > 0 {
                        checksum = buffer.withUnsafeBufferPointer { crc32(checksum, $0.baseAddress, uInt(written)) }
                        try output.write(contentsOf: Data(buffer.prefix(written)))
                        outputBytes += UInt64(written)
                    }
                    if result == Z_STREAM_END {
                        guard stream.avail_in == 0, readBytes == entry.compressedBytes else {
                            throw ArchiveError.invalidArchive
                        }
                        ended = true
                        break
                    }
                    guard result == Z_OK, written > 0 || stream.avail_in < availableBefore else {
                        throw ArchiveError.invalidArchive
                    }
                } while stream.avail_in > 0 || stream.avail_out == 0
            }
            if !ended && readBytes == entry.compressedBytes { throw ArchiveError.invalidArchive }
        }
        guard outputBytes == entry.outputBytes, UInt64(stream.total_in) == entry.compressedBytes else {
            throw ArchiveError.invalidArchive
        }
        guard UInt32(checksum) == entry.checksum else { throw ArchiveError.checksumMismatch }
    }
}

private extension Data {
    // Only called after the fixed header or extra-field bounds were checked.
    func u16(_ offset: Int) -> UInt16 {
        UInt16(self[offset]) | UInt16(self[offset + 1]) << 8
    }

    func u32(_ offset: Int) -> UInt32 {
        UInt32(self[offset]) | UInt32(self[offset + 1]) << 8 |
            UInt32(self[offset + 2]) << 16 | UInt32(self[offset + 3]) << 24
    }
}
