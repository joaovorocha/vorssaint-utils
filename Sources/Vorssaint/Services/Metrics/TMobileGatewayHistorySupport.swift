// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

struct TMobileMapCoordinate: Codable, Equatable {
    let latitude: Double
    let longitude: Double
    var isValid: Bool { latitude.isFinite && longitude.isFinite && (-90...90).contains(latitude) && (-180...180).contains(longitude) }
}

struct TMobileTowerPin: Codable, Identifiable, Equatable {
    var id = UUID()
    let name: String
    let latitude: Double
    let longitude: Double
    let bands: String
    // A reference entered by the owner; this is never treated as proof of attachment.
    let cellID: String?
    let radio: TMobileTowerRadio?
    let nodeID: UInt32?
    let ecgi: String?
    let provenance: String?

    init(id: UUID = UUID(), name: String, latitude: Double, longitude: Double,
         bands: String, cellID: String?, radio: TMobileTowerRadio? = nil,
         nodeID: UInt32? = nil, ecgi: String? = nil, provenance: String? = nil) {
        self.id = id; self.name = name; self.latitude = latitude; self.longitude = longitude
        self.bands = bands; self.cellID = cellID; self.radio = radio
        self.nodeID = nodeID; self.ecgi = ecgi; self.provenance = provenance
    }

    var coordinate: TMobileMapCoordinate { .init(latitude: latitude, longitude: longitude) }
    var isValid: Bool {
        coordinate.isValid && Self.validText(name, limit: 100) && !name.isEmpty
            && Self.validText(bands, limit: 100) && Self.validText(cellID ?? "", limit: 32)
            && (ecgi == nil || TMobileTowerReferenceSupport.canonicalECGI(ecgi!) != nil)
            && (radio != .lte || nodeID == nil || nodeID! <= 0x0FFF_FFFF)
            && Self.validText(provenance ?? "", limit: 160)
    }
    private static func validText(_ value: String, limit: Int) -> Bool {
        value.count <= limit && value.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) }
    }
}

struct TMobileHistorySample: Codable, Identifiable, Equatable {
    var id = UUID()
    let date: Date
    let snapshot: TMobileGatewaySnapshot
    let coordinate: TMobileMapCoordinate?
}

enum TMobileTowerImportError: LocalizedError {
    case invalidFile
    var errorDescription: String? { "Use JSON tower records or CSV with name,latitude,longitude,bands,cellID columns. Optional columns: radio (LTE or NR), nodeID (whole number), ecgi (reported decimal/hex identity text), provenance. Coordinates and identifiers must be valid; maximum 5,000 towers and 2 MB." }
}

enum TMobileGatewayHistorySupport {
    static let maximumSamples = 10_000
    static let retention: TimeInterval = 7 * 24 * 60 * 60

    static func retained(_ samples: [TMobileHistorySample], now: Date) -> [TMobileHistorySample] {
        Array(samples.filter { $0.date >= now.addingTimeInterval(-retention) && $0.date <= now
            && TMobileGatewaySupport.isValidSnapshot($0.snapshot)
            && ($0.coordinate == nil || $0.coordinate!.isValid) }.sorted { $0.date < $1.date }.suffix(maximumSamples))
    }

    static func importTowers(_ data: Data, json: Bool) throws -> [TMobileTowerPin] {
        guard data.count <= 2_000_000 else { throw TMobileTowerImportError.invalidFile }
        let towers: [TMobileTowerPin]
        if json {
            // IDs are generated locally; an import cannot overwrite an existing pin.
            struct Record: Decodable {
                let name: String; let latitude: Double; let longitude: Double
                let bands: String?; let cellID: String?
                let radio: TMobileTowerRadio?; let nodeID: UInt32?; let ecgi: String?; let provenance: String?
            }
            guard let rows = try? JSONDecoder().decode([Record].self, from: data) else { throw TMobileTowerImportError.invalidFile }
            towers = rows.map { .init(name: $0.name, latitude: $0.latitude, longitude: $0.longitude,
                                      bands: $0.bands ?? "", cellID: $0.cellID, radio: $0.radio,
                                      nodeID: $0.nodeID, ecgi: $0.ecgi,
                                      provenance: $0.provenance ?? "Imported local file") }
        } else {
            guard let text = String(data: data, encoding: .utf8) else { throw TMobileTowerImportError.invalidFile }
            let rows = try csv(text)
            let required = Set(["name", "latitude", "longitude", "bands", "cellID"])
            let allowed = required.union(["radio", "nodeID", "ecgi", "provenance"])
            guard let header = rows.first, Set(header).count == header.count,
                  required.isSubset(of: Set(header)), Set(header).isSubset(of: allowed)
            else { throw TMobileTowerImportError.invalidFile }
            let columns = Dictionary(uniqueKeysWithValues: header.enumerated().map { ($0.element, $0.offset) })
            towers = try rows.dropFirst().map { row in
                guard row.count == header.count else { throw TMobileTowerImportError.invalidFile }
                func field(_ name: String) -> String? { columns[name].flatMap { row[$0].isEmpty ? nil : row[$0] } }
                guard let name = field("name"), let latitude = field("latitude"), let longitude = field("longitude"),
                      let lat = Double(latitude), let lon = Double(longitude)
                else { throw TMobileTowerImportError.invalidFile }
                let radioText = field("radio"), nodeText = field("nodeID")
                let radio = radioText.flatMap(TMobileTowerRadio.init(rawValue:))
                let node = nodeText.flatMap { value -> UInt32? in
                    guard value.utf8.allSatisfy({ (48...57).contains($0) }) else { return nil }
                    return UInt32(value)
                }
                guard (radioText == nil || radio != nil), (nodeText == nil || node != nil)
                else { throw TMobileTowerImportError.invalidFile }
                return .init(name: name, latitude: lat, longitude: lon, bands: field("bands") ?? "",
                             cellID: field("cellID"), radio: radio, nodeID: node, ecgi: field("ecgi"),
                             provenance: field("provenance") ?? "Imported local file")
            }
        }
        guard !towers.isEmpty, towers.count <= 5_000, towers.allSatisfy(\.isValid) else { throw TMobileTowerImportError.invalidFile }
        return towers
    }

    // Quoted commas and escaped quotes are supported. Multiline labels are rejected by validation.
    private static func csv(_ text: String) throws -> [[String]] {
        var rows: [[String]] = [], row: [String] = [], field = "", quoted = false, closed = false
        var index = text.startIndex
        while index < text.endIndex {
            let ch = text[index], next = text.index(after: index)
            if quoted {
                if ch == "\"" {
                    if next < text.endIndex && text[next] == "\"" { field.append("\""); index = text.index(after: next); continue }
                    quoted = false; closed = true
                } else { field.append(ch) }
            } else if ch == "," { row.append(field); field = ""; closed = false }
            else if ch == "\n" || ch == "\r" || ch == "\r\n" {
                row.append(field); if row != [""] { rows.append(row) }; row = []; field = ""; closed = false
            } else if ch == "\"" {
                guard field.isEmpty && !closed else { throw TMobileTowerImportError.invalidFile }; quoted = true
            } else {
                guard !closed else { throw TMobileTowerImportError.invalidFile }; field.append(ch)
            }
            index = next
        }
        guard !quoted else { throw TMobileTowerImportError.invalidFile }
        if !field.isEmpty || !row.isEmpty { row.append(field); rows.append(row) }
        return rows
    }
}
