// SPDX-License-Identifier: GPL-3.0-or-later
import Combine
import CoreFoundation
import Foundation

struct TMobileCoverageFCCLayer: Codable, Identifiable, Equatable {
    let id: UUID
    let publishedDate: String
    let importedAt: Date
    /// Polygon → rings (outer, then holes) → coordinates. No source properties are retained.
    let polygons: [[[TMobileMapCoordinate]]]
    var title: String { "FCC reference · \(publishedDate)" }
}

enum TMobileCoverageReferenceError: LocalizedError {
    case invalidData, invalidDate, cannotSave
    var errorDescription: String? {
        switch self {
        case .invalidDate: return "Enter the coverage dataset’s publication date as YYYY-MM-DD."
        case .invalidData: return "Choose a local GeoJSON FeatureCollection containing only Polygon or MultiPolygon coverage features. Maximum 5 MB, 1,000 polygons and 100,000 coordinates. Rings must be closed WGS84 coordinates."
        case .cannotSave: return "The coverage reference could not be saved on this Mac."
        }
    }
}

enum TMobileCoverageReferenceSupport {
    static let maximumBytes = 5_000_000
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
        var polygons: [[[TMobileMapCoordinate]]] = [], count = 0
        for feature in features {
            guard feature["type"] as? String == "Feature",
                  let geometry = feature["geometry"] as? [String: Any],
                  let type = geometry["type"] as? String else { throw TMobileCoverageReferenceError.invalidData }
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
                guard polygons.count <= 1_000 else { throw TMobileCoverageReferenceError.invalidData }
            }
        }
        guard !polygons.isEmpty else { throw TMobileCoverageReferenceError.invalidData }
        return .init(id: UUID(), publishedDate: publishedDate, importedAt: now, polygons: polygons)
    }
}

/// Local, operator-declared FCC coverage reference. No website scraping or remote loader.
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
            let saved = try JSONDecoder().decode(TMobileCoverageFCCLayer.self, from: Data(contentsOf: file))
            // Revalidate persisted geometry through the same bounded importer.
            let features = saved.polygons.map { polygon in
                ["type": "Feature", "geometry": ["type": "Polygon", "coordinates": polygon.map { $0.map { [$0.longitude, $0.latitude] } }]] as [String: Any]
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
            let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
            guard attrs[.type] as? FileAttributeType == .typeRegular,
                  (attrs[.size] as? NSNumber)?.intValue ?? Int.max <= TMobileCoverageReferenceSupport.maximumBytes
            else { throw TMobileCoverageReferenceError.invalidData }
            let imported = try TMobileCoverageReferenceSupport.parse(Data(contentsOf: url), publishedDate: publishedDate)
            let fm = FileManager.default
            try fm.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let folderAttrs = try fm.attributesOfItem(atPath: folder.path)
            guard folderAttrs[.type] as? FileAttributeType == .typeDirectory else { throw TMobileCoverageReferenceError.cannotSave }
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
            try JSONEncoder().encode(imported).write(to: file, options: .atomic)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            layer = imported; errorMessage = nil
        } catch { errorMessage = (error as? TMobileCoverageReferenceError)?.localizedDescription ?? TMobileCoverageReferenceError.cannotSave.localizedDescription }
    }

    func removeLayer() {
        do {
            if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
            layer = nil; errorMessage = nil
        } catch { errorMessage = TMobileCoverageReferenceError.cannotSave.localizedDescription }
    }
}
