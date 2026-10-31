// SPDX-License-Identifier: GPL-3.0-or-later
import Combine
import CoreFoundation
import Darwin
import Foundation

struct TMobileCoverageFCCLayer: Codable, Identifiable, Equatable {
    let id: UUID
    let publishedDate: String
    let importedAt: Date
    /// Polygon → rings (outer, then holes) → coordinates. Arbitrary GIS properties are excluded.
    let polygons: [[[TMobileMapCoordinate]]]
    var source: TMobileFCCReferenceSource? = nil
    /// FCC predicted minimum signal, aligned with each polygon component.
    /// A missing array is a legacy/unknown layer; nil entries are unknown values.
    /// LTE/NR values describe modeled RSRP, never a measured reading or speed.
    var modeledSignalDBm: [Double?]? = nil
    var title: String { source?.title ?? "FCC reference · \(publishedDate)" }
    var provenance: String { source?.provenance ?? "Imported FCC carrier-reported model · source declared by owner" }
}

enum TMobileCoverageReferenceError: LocalizedError {
    case invalidData, invalidDate, cannotSave
    var errorDescription: String? {
        switch self {
        case .invalidDate: return "Enter the coverage dataset’s Availability Data As Of date as YYYY-MM-DD."
        case .invalidData: return "Choose a local GeoJSON FeatureCollection containing only Polygon or MultiPolygon coverage features. Maximum 5 MB, 1,000 polygons and 100,000 coordinates. Rings must be closed WGS84 coordinates."
        case .cannotSave: return "The coverage reference could not be saved on this Mac."
        }
    }
}

enum TMobileCoverageReferenceSupport {
    static let maximumBytes = 5_000_000
    static let modeledSignalProperty = "fccMinimumSignalDBm"

    static func validModeledSignalDBm(_ value: Double) -> Bool {
        value.isFinite && (-120 ... -50).contains(value)
    }

    /// A selected FIFO, device, or symlink must never block a worker before it
    /// can respond to cancellation. Size is checked again while reading.
    static func readLocalFile(at url: URL, maximumBytes: Int = maximumBytes) throws -> Data {
        guard url.isFileURL, maximumBytes > 0 else { throw TMobileCoverageReferenceError.invalidData }
        let descriptor = open(url.path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw TMobileCoverageReferenceError.invalidData }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_size >= 0, info.st_size <= maximumBytes else { throw TMobileCoverageReferenceError.invalidData }
        var data = Data(), buffer = [UInt8](repeating: 0, count: 65_536)
        while true {
            try Task.checkCancellation()
            let count = read(descriptor, &buffer, min(buffer.count, maximumBytes - data.count + 1))
            if count == 0 { return data }
            if count < 0 {
                if errno == EINTR { continue }
                throw TMobileCoverageReferenceError.invalidData
            }
            guard count <= maximumBytes - data.count else { throw TMobileCoverageReferenceError.invalidData }
            data.append(contentsOf: buffer.prefix(count))
        }
    }

    static func validDate(_ value: String) -> Bool {
        guard value.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil else { return false }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"; formatter.isLenient = false
        guard let date = formatter.date(from: value) else { return false }
        return formatter.string(from: date) == value
    }

    static func parse(_ data: Data, publishedDate: String, now: Date = Date()) throws -> TMobileCoverageFCCLayer {
        guard validDate(publishedDate) else { throw TMobileCoverageReferenceError.invalidDate }
        guard data.count <= maximumBytes,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              root["type"] as? String == "FeatureCollection",
              let features = root["features"] as? [[String: Any]], !features.isEmpty, features.count <= 1_000
        else { throw TMobileCoverageReferenceError.invalidData }
        var polygons: [[[TMobileMapCoordinate]]] = [], signals: [Double?] = [], count = 0
        var hasSignalProperty = false
        for feature in features {
            guard feature["type"] as? String == "Feature",
                  let geometry = feature["geometry"] as? [String: Any],
                  let type = geometry["type"] as? String else { throw TMobileCoverageReferenceError.invalidData }
            var signal: Double?
            if let rawProperties = feature["properties"], !(rawProperties is NSNull) {
                guard let properties = rawProperties as? [String: Any] else { throw TMobileCoverageReferenceError.invalidData }
                if let rawSignal = properties[modeledSignalProperty] {
                    hasSignalProperty = true
                    if !(rawSignal is NSNull) {
                        guard let number = rawSignal as? NSNumber,
                              CFGetTypeID(number) != CFBooleanGetTypeID(),
                              validModeledSignalDBm(number.doubleValue) else { throw TMobileCoverageReferenceError.invalidData }
                        signal = number.doubleValue
                    }
                }
            }
            let rawPolygons: [Any]
            if type == "Polygon", let rings = geometry["coordinates"] { rawPolygons = [rings] }
            else if type == "MultiPolygon", let shapes = geometry["coordinates"] as? [Any] { rawPolygons = shapes }
            else { throw TMobileCoverageReferenceError.invalidData }
            for rawPolygon in rawPolygons {
                guard let rawRings = rawPolygon as? [[Any]], !rawRings.isEmpty, rawRings.count <= 1_000
                else { throw TMobileCoverageReferenceError.invalidData }
                var rings: [[TMobileMapCoordinate]] = []
                for rawRing in rawRings {
                    guard rawRing.count >= 4 else { throw TMobileCoverageReferenceError.invalidData }
                    var ring: [TMobileMapCoordinate] = []
                    for rawPoint in rawRing {
                        count += 1
                        guard count <= 100_000, let point = rawPoint as? [NSNumber], point.count == 2,
                              point.allSatisfy({ CFGetTypeID($0) != CFBooleanGetTypeID() })
                        else { throw TMobileCoverageReferenceError.invalidData }
                        let coordinate = TMobileMapCoordinate(latitude: point[1].doubleValue, longitude: point[0].doubleValue)
                        guard coordinate.isValid else { throw TMobileCoverageReferenceError.invalidData }
                        ring.append(coordinate)
                    }
                    guard ring.first == ring.last, Set(ring.map { "\($0.latitude),\($0.longitude)" }).count >= 3
                    else { throw TMobileCoverageReferenceError.invalidData }
                    rings.append(ring)
                }
                polygons.append(rings)
                signals.append(signal)
                guard polygons.count <= 1_000 else { throw TMobileCoverageReferenceError.invalidData }
            }
        }
        guard !polygons.isEmpty else { throw TMobileCoverageReferenceError.invalidData }
        return .init(id: UUID(), publishedDate: publishedDate, importedAt: now, polygons: polygons,
                     modeledSignalDBm: hasSignalProperty ? signals : nil)
    }
}

/// Local bounded geometry; network retrieval is isolated from this store.
@MainActor final class TMobileCoverageReferenceStore: ObservableObject {
    static let shared = TMobileCoverageReferenceStore()
    @Published private(set) var layer: TMobileCoverageFCCLayer?
    @Published private(set) var errorMessage: String?
    private let folder: URL
    private var file: URL { folder.appendingPathComponent("fcc-reference.json") }

    init(folder: URL? = nil) {
        self.folder = folder ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "io.github.joaovorocha.shadowutils")
            .appendingPathComponent("Coverage-references", isDirectory: true)
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        do {
            let attrs = try FileManager.default.attributesOfItem(atPath: file.path)
            guard attrs[.type] as? FileAttributeType == .typeRegular,
                  (attrs[.size] as? NSNumber)?.intValue ?? Int.max <= 10_000_000 else { throw TMobileCoverageReferenceError.invalidData }
            let saved = try JSONDecoder().decode(TMobileCoverageFCCLayer.self,
                from: TMobileCoverageReferenceSupport.readLocalFile(at: file, maximumBytes: 10_000_000))
            guard saved.source == nil || (saved.source!.isValid && saved.source!.availabilityAsOf == saved.publishedDate)
            else { throw TMobileCoverageReferenceError.invalidData }
            if let signals = saved.modeledSignalDBm {
                guard signals.count == saved.polygons.count,
                      signals.allSatisfy({ $0.map(TMobileCoverageReferenceSupport.validModeledSignalDBm) ?? true })
                else { throw TMobileCoverageReferenceError.invalidData }
            }
            // Revalidate persisted geometry through the same bounded importer.
            let features = saved.polygons.enumerated().map { index, polygon in
                var feature: [String: Any] = ["type": "Feature", "geometry": ["type": "Polygon", "coordinates": polygon.map { $0.map { [$0.longitude, $0.latitude] } }]]
                if let signals = saved.modeledSignalDBm {
                    feature["properties"] = [TMobileCoverageReferenceSupport.modeledSignalProperty: signals[index].map { $0 as Any } ?? NSNull()]
                }
                return feature
            }
            let geo = try JSONSerialization.data(withJSONObject: ["type": "FeatureCollection", "features": features])
            _ = try TMobileCoverageReferenceSupport.parse(geo, publishedDate: saved.publishedDate)
            layer = saved
        } catch { errorMessage = "The saved FCC reference could not be read. Import a valid file to replace it." }
    }

    func importLayer(from url: URL, publishedDate: String) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            _ = importLayer(data: try TMobileCoverageReferenceSupport.readLocalFile(at: url), publishedDate: publishedDate)
        } catch { errorMessage = (error as? TMobileCoverageReferenceError)?.localizedDescription ?? TMobileCoverageReferenceError.cannotSave.localizedDescription }
    }

    @discardableResult
    func importLayer(data: Data, publishedDate: String, source: TMobileFCCReferenceSource? = nil) -> Bool {
        do {
            guard source == nil || (source!.isValid && source!.availabilityAsOf == publishedDate) else {
                throw TMobileCoverageReferenceError.invalidData
            }
            var imported = try TMobileCoverageReferenceSupport.parse(data, publishedDate: publishedDate)
            imported.source = source
            let fm = FileManager.default
            try fm.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let folderAttrs = try fm.attributesOfItem(atPath: folder.path)
            guard folderAttrs[.type] as? FileAttributeType == .typeDirectory else { throw TMobileCoverageReferenceError.cannotSave }
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
            try JSONEncoder().encode(imported).write(to: file, options: .atomic)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            layer = imported; errorMessage = nil
            return true
        } catch {
            errorMessage = (error as? TMobileCoverageReferenceError)?.localizedDescription ?? TMobileCoverageReferenceError.cannotSave.localizedDescription
            return false
        }
    }

    func removeLayer() {
        do {
            if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
            layer = nil; errorMessage = nil
        } catch { errorMessage = TMobileCoverageReferenceError.cannotSave.localizedDescription }
    }
}
