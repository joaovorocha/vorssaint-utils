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
    var coordinate: TMobileMapCoordinate { .init(latitude: latitude, longitude: longitude) }
    var isValid: Bool {
        coordinate.isValid && Self.validText(name, limit: 100) && !name.isEmpty
            && Self.validText(bands, limit: 100) && Self.validText(cellID ?? "", limit: 32)
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
    var errorDescription: String? { "Use JSON tower records or CSV with name,latitude,longitude,bands,cellID columns. Coordinates must be valid; maximum 5,000 towers and 2 MB." }
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
            struct Record: Decodable { let name: String; let latitude: Double; let longitude: Double; let bands: String?; let cellID: String? }
            guard let rows = try? JSONDecoder().decode([Record].self, from: data) else { throw TMobileTowerImportError.invalidFile }
            towers = rows.map { .init(name: $0.name, latitude: $0.latitude, longitude: $0.longitude, bands: $0.bands ?? "", cellID: $0.cellID) }
        } else {
            guard let text = String(data: data, encoding: .utf8) else { throw TMobileTowerImportError.invalidFile }
            let rows = try csv(text)
            guard let header = rows.first, header == ["name", "latitude", "longitude", "bands", "cellID"] else { throw TMobileTowerImportError.invalidFile }
            towers = try rows.dropFirst().map { row in
                guard row.count == 5, let lat = Double(row[1]), let lon = Double(row[2]) else { throw TMobileTowerImportError.invalidFile }
                return .init(name: row[0], latitude: lat, longitude: lon, bands: row[3], cellID: row[4].isEmpty ? nil : row[4])
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
