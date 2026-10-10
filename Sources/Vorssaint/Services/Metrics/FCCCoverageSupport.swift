// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import CoreFoundation
import Foundation

struct FCCCoverageState: Identifiable, Equatable, Sendable {
    let fips: String
    let abbreviation: String
    let name: String
    var id: String { fips }
    static let all: [Self] = [
        .init(fips: "01", abbreviation: "AL", name: "Alabama"),
        .init(fips: "02", abbreviation: "AK", name: "Alaska"),
        .init(fips: "04", abbreviation: "AZ", name: "Arizona"),
        .init(fips: "05", abbreviation: "AR", name: "Arkansas"),
        .init(fips: "06", abbreviation: "CA", name: "California"),
        .init(fips: "08", abbreviation: "CO", name: "Colorado"),
        .init(fips: "09", abbreviation: "CT", name: "Connecticut"),
        .init(fips: "10", abbreviation: "DE", name: "Delaware"),
        .init(fips: "11", abbreviation: "DC", name: "District of Columbia"),
        .init(fips: "12", abbreviation: "FL", name: "Florida"),
        .init(fips: "13", abbreviation: "GA", name: "Georgia"),
        .init(fips: "15", abbreviation: "HI", name: "Hawaii"),
        .init(fips: "16", abbreviation: "ID", name: "Idaho"),
        .init(fips: "17", abbreviation: "IL", name: "Illinois"),
        .init(fips: "18", abbreviation: "IN", name: "Indiana"),
        .init(fips: "19", abbreviation: "IA", name: "Iowa"),
        .init(fips: "20", abbreviation: "KS", name: "Kansas"),
        .init(fips: "21", abbreviation: "KY", name: "Kentucky"),
        .init(fips: "22", abbreviation: "LA", name: "Louisiana"),
        .init(fips: "23", abbreviation: "ME", name: "Maine"),
        .init(fips: "24", abbreviation: "MD", name: "Maryland"),
        .init(fips: "25", abbreviation: "MA", name: "Massachusetts"),
        .init(fips: "26", abbreviation: "MI", name: "Michigan"),
        .init(fips: "27", abbreviation: "MN", name: "Minnesota"),
        .init(fips: "28", abbreviation: "MS", name: "Mississippi"),
        .init(fips: "29", abbreviation: "MO", name: "Missouri"),
        .init(fips: "30", abbreviation: "MT", name: "Montana"),
        .init(fips: "31", abbreviation: "NE", name: "Nebraska"),
        .init(fips: "32", abbreviation: "NV", name: "Nevada"),
        .init(fips: "33", abbreviation: "NH", name: "New Hampshire"),
        .init(fips: "34", abbreviation: "NJ", name: "New Jersey"),
        .init(fips: "35", abbreviation: "NM", name: "New Mexico"),
        .init(fips: "36", abbreviation: "NY", name: "New York"),
        .init(fips: "37", abbreviation: "NC", name: "North Carolina"),
        .init(fips: "38", abbreviation: "ND", name: "North Dakota"),
        .init(fips: "39", abbreviation: "OH", name: "Ohio"),
        .init(fips: "40", abbreviation: "OK", name: "Oklahoma"),
        .init(fips: "41", abbreviation: "OR", name: "Oregon"),
        .init(fips: "42", abbreviation: "PA", name: "Pennsylvania"),
        .init(fips: "44", abbreviation: "RI", name: "Rhode Island"),
        .init(fips: "45", abbreviation: "SC", name: "South Carolina"),
        .init(fips: "46", abbreviation: "SD", name: "South Dakota"),
        .init(fips: "47", abbreviation: "TN", name: "Tennessee"),
        .init(fips: "48", abbreviation: "TX", name: "Texas"),
        .init(fips: "49", abbreviation: "UT", name: "Utah"),
        .init(fips: "50", abbreviation: "VT", name: "Vermont"),
        .init(fips: "51", abbreviation: "VA", name: "Virginia"),
        .init(fips: "53", abbreviation: "WA", name: "Washington"),
        .init(fips: "54", abbreviation: "WV", name: "West Virginia"),
        .init(fips: "55", abbreviation: "WI", name: "Wisconsin"),
        .init(fips: "56", abbreviation: "WY", name: "Wyoming"),
        .init(fips: "60", abbreviation: "AS", name: "American Samoa"),
        .init(fips: "66", abbreviation: "GU", name: "Guam"),
        .init(fips: "69", abbreviation: "MP", name: "Northern Mariana Islands"),
        .init(fips: "72", abbreviation: "PR", name: "Puerto Rico"),
        .init(fips: "74", abbreviation: "UM", name: "U.S. Minor Outlying Islands"),
        .init(fips: "78", abbreviation: "VI", name: "U.S. Virgin Islands")
    ]
    static let california = all.first { $0.fips == "06" }!
}

/// Request-scoped credentials only. This type never reads or writes a credential store.
struct FCCCoverageCredentials: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    fileprivate let username: String
    fileprivate let token: String
    init(username: String, token: String) {
        self.username = username.trimmingCharacters(in: .whitespacesAndNewlines)
        self.token = token.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    var description: String { "FCCCoverageCredentials(redacted)" }
    var debugDescription: String { description }
    var isValid: Bool {
        (3...254).contains(username.utf8.count) && username.contains("@")
            && (1...4096).contains(token.utf8.count)
            && username.utf8.allSatisfy { $0 > 32 && $0 < 127 }
            && token.utf8.allSatisfy { $0 > 32 && $0 < 127 }
    }
}

enum FCCCoverageTechnology: String, CaseIterable, Identifiable, Sendable {
    case lte = "400", nr = "500"
    var id: String { rawValue }
    var title: String { self == .lte ? "4G LTE" : "5G NR" }
}
enum FCCCoverageGeometry: String, CaseIterable, Identifiable, Sendable {
    case raw = "Raw Coverage", hexagons = "Hexagon Coverage"
    var id: String { rawValue }
    var title: String { self == .raw ? "Raw coverage" : "Coverage hexagons" }
}
enum FCCCoverageSpeedTier: String, CaseIterable, Identifiable, Sendable {
    case sevenOne = "7/1", thirtyFiveThree = "35/3"
    var id: String { rawValue }
    var title: String { "\(rawValue) Mbps" }
}
struct FCCCoverageDataFile: Identifiable, Equatable, Sendable {
    let id: String
    let providerID: String
    let providerName: String
    let stateFIPS: String
    let technology: FCCCoverageTechnology
    let speedTier: FCCCoverageSpeedTier?
    let geometry: FCCCoverageGeometry
    let fileName: String
    let recordCount: Int?
    let asOfDate: String
    var title: String {
        [technology.title, speedTier?.title, geometry.title].compactMap { $0 }.joined(separator: " · ")
    }
}
struct FCCCoverageCatalogue: Equatable, Sendable {
    let asOfDate: String
    let checkedAt: Date
    let state: FCCCoverageState
    let files: [FCCCoverageDataFile]
}

enum FCCCoverageFailure: Error, Equatable, LocalizedError, Sendable {
    case invalidInput, authentication, forbidden, rateLimited, network, unavailable
    case invalidResponse, tooLarge, cancelled, fileSystem, destinationExists
    var errorDescription: String? { message }
    var message: String {
        switch self {
        case .invalidInput: return "Enter your FCC account email and API token, then choose a state or territory."
        case .authentication: return "FCC did not accept this email and API token. Check Manage API Access on the FCC website."
        case .forbidden: return "FCC denied API access. Check your token status and API access on the FCC website."
        case .rateLimited: return "FCC’s request limit was reached. Wait a minute, then try again."
        case .network: return "Could not reach the FCC. Check your connection, then try again."
        case .unavailable: return "FCC data is temporarily unavailable. Try again later."
        case .invalidResponse: return "FCC returned data this app could not verify. Open the official download page to continue."
        case .tooLarge: return "This FCC file exceeds the app’s download limit. Use the official FCC download page for larger files."
        case .cancelled: return "FCC request cancelled."
        case .fileSystem: return "The FCC download could not be saved. Choose another destination and try again."
        case .destinationExists: return "A file already exists at this destination. Choose a new name to save the FCC download."
        }
    }
    static func safe(_ error: Error) -> Self {
        if let failure = error as? Self { return failure }
        if error is CancellationError || (error as? URLError)?.code == .cancelled { return .cancelled }
        if error is URLError { return .network }
        return .unavailable
    }
}

enum FCCCoverageSupport {
    static let apiBase = URL(string: "https://broadbandmap.fcc.gov/api/public")!
    static let downloadPage = URL(string: "https://broadbandmap.fcc.gov/data-download")!
    static let tokenPage = URL(string: "https://broadbandmap.fcc.gov/login")!
    static let specification = URL(string: "https://us-fcc.app.box.com/v/bdc-public-data-api-spec")!
    static let maximumMetadataBytes = 32 * 1024 * 1024
    static let maximumDownloadBytes = 512 * 1024 * 1024
    static let tMobileProviderID = "130403"

    // The June 2026 PDF examples use bdc.fcc.gov; the official Swagger uses
    // broadbandmap.fcc.gov. Keep one fixed allowlisted host and never try another
    // hostname with user credentials. All paths are from the official specifications.
    static func request(path: String, query: [URLQueryItem] = [], credentials: FCCCoverageCredentials,
                        acceptsZIP: Bool = false) throws -> URLRequest {
        guard credentials.isValid, path.hasPrefix("/map/"), !path.contains(".."), !path.contains("?") else {
            throw FCCCoverageFailure.invalidInput
        }
        var components = URLComponents(url: apiBase, resolvingAgainstBaseURL: false)!
        components.path += path
        components.queryItems = query.isEmpty ? nil : query
        guard let url = components.url, isCanonical(url) else { throw FCCCoverageFailure.invalidInput }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.httpMethod = "GET"
        request.httpShouldHandleCookies = false
        request.setValue(credentials.username, forHTTPHeaderField: "username")
        request.setValue(credentials.token, forHTTPHeaderField: "hash_value")
        request.setValue(acceptsZIP ? "application/zip, application/octet-stream" : "application/json", forHTTPHeaderField: "Accept")
        return request
    }
    static func isCanonical(_ url: URL) -> Bool {
        url.scheme == "https" && url.host == "broadbandmap.fcc.gov" && url.port == nil
            && url.user == nil && url.password == nil && url.fragment == nil
            && url.path.hasPrefix("/api/public/map/")
    }
    static func checkHTTP(_ response: HTTPURLResponse, requested: URL) throws {
        guard response.url == requested, isCanonical(requested) else { throw FCCCoverageFailure.invalidResponse }
        switch response.statusCode {
        case 200: return
        case 400: throw FCCCoverageFailure.invalidInput
        case 401: throw FCCCoverageFailure.authentication
        case 403: throw FCCCoverageFailure.forbidden
        case 429: throw FCCCoverageFailure.rateLimited
        case 300...399: throw FCCCoverageFailure.invalidResponse
        default: throw FCCCoverageFailure.unavailable
        }
    }
    static func latestAvailabilityDate(_ data: Data) throws -> String {
        let rows = try responseRows(data)
        let dates = try rows.compactMap { row -> String? in
            guard row["data_type"] as? String == "availability" else { return nil }
            guard let date = row["as_of_date"] as? String, validDate(date) else { throw FCCCoverageFailure.invalidResponse }
            return date
        }
        guard let latest = dates.max() else { throw FCCCoverageFailure.invalidResponse }
        return latest
    }
    static func catalogue(_ data: Data, asOfDate: String, state: FCCCoverageState, checkedAt: Date = Date()) throws -> FCCCoverageCatalogue {
        guard validDate(asOfDate) else { throw FCCCoverageFailure.invalidInput }
        let rows = try responseRows(data)
        var files: [FCCCoverageDataFile] = []
        var ids = Set<String>()
        for row in rows {
            guard row["category"] as? String == "Provider", row["technology_type"] as? String == "Mobile Broadband",
                  identifier(row["provider_id"], digits: 6...6) == tMobileProviderID,
                  row["state_fips"] as? String == state.fips,
                  let geometryString = row["subcategory"] as? String,
                  let geometry = FCCCoverageGeometry(rawValue: geometryString) else { continue }
            // 3G is a documented mobile catalogue entry, but this LTE/NR client
            // does not offer it. Its presence must not break the selected state.
            if identifier(row["technology_code"], digits: 3...3) == "300" { continue }
            guard let id = identifier(row["file_id"], digits: 1...18), ids.insert(id).inserted,
                  let code = identifier(row["technology_code"], digits: 3...3),
                  let technology = FCCCoverageTechnology(rawValue: code), row["file_type"] as? String == "gis",
                  let providerName = row["provider_name"] as? String, validText(providerName, maximum: 256),
                  let fileName = row["file_name"] as? String, validText(fileName, maximum: 512),
                  !fileName.contains("/"), !fileName.contains("\\"), !fileName.contains("..") else {
                throw FCCCoverageFailure.invalidResponse
            }
            let speedTier = (row["speed_tier"] as? String).flatMap(FCCCoverageSpeedTier.init(rawValue:))
            if technology == .nr && speedTier == nil { throw FCCCoverageFailure.invalidResponse }
            if technology == .lte, let value = row["speed_tier"], !(value is NSNull) { throw FCCCoverageFailure.invalidResponse }
            let recordCount = integer(row["record_count"])
            if let value = row["record_count"], !(value is NSNull), recordCount == nil { throw FCCCoverageFailure.invalidResponse }
            files.append(.init(id: id, providerID: tMobileProviderID, providerName: providerName, stateFIPS: state.fips,
                               technology: technology, speedTier: speedTier, geometry: geometry,
                               fileName: fileName, recordCount: recordCount, asOfDate: asOfDate))
        }
        files.sort { ($0.technology.rawValue, $0.speedTier?.rawValue ?? "", $0.geometry.rawValue, $0.id)
            < ($1.technology.rawValue, $1.speedTier?.rawValue ?? "", $1.geometry.rawValue, $1.id) }
        return .init(asOfDate: asOfDate, checkedAt: checkedAt, state: state, files: files)
    }
    static func validDate(_ text: String) -> Bool {
        let pieces = text.split(separator: "-", omittingEmptySubsequences: false)
        guard pieces.count == 3, pieces[0].count == 4, pieces[1].count == 2, pieces[2].count == 2,
              text.utf8.allSatisfy({ (48...57).contains($0) || $0 == 45 }),
              let year = Int(pieces[0]), (2022...2100).contains(year),
              let month = Int(pieces[1]), let day = Int(pieces[2]) else { return false }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        guard let date = calendar.date(from: DateComponents(year: year, month: month, day: day)) else { return false }
        let roundTrip = calendar.dateComponents([.year, .month, .day], from: date)
        return roundTrip.year == year && roundTrip.month == month && roundTrip.day == day
    }
    private static func responseRows(_ data: Data) throws -> [[String: Any]] {
        guard data.count <= maximumMetadataBytes, validJSONDepth(data),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let status = integer(root["status_code"]) else { throw FCCCoverageFailure.invalidResponse }
        switch status {
        case 200: break
        case 400: throw FCCCoverageFailure.invalidInput
        case 401: throw FCCCoverageFailure.authentication
        case 403: throw FCCCoverageFailure.forbidden
        case 429: throw FCCCoverageFailure.rateLimited
        default: throw FCCCoverageFailure.unavailable
        }
        guard root["status"] as? String == "successful", let rows = root["data"] as? [[String: Any]], rows.count <= 100_000,
              let count = integer(root["result_count"]), count == rows.count else { throw FCCCoverageFailure.invalidResponse }
        return rows
    }
    private static func validJSONDepth(_ data: Data) -> Bool {
        var depth = 0
        var quoted = false
        var escaped = false
        for byte in data {
            if quoted {
                if escaped { escaped = false }
                else if byte == 92 { escaped = true }
                else if byte == 34 { quoted = false }
            } else if byte == 34 { quoted = true }
            else if byte == 123 || byte == 91 {
                depth += 1
                if depth > 32 { return false }
            } else if byte == 125 || byte == 93 {
                depth -= 1
                if depth < 0 { return false }
            }
        }
        return depth == 0 && !quoted
    }
    private static func identifier(_ value: Any?, digits: ClosedRange<Int>) -> String? {
        guard let integer = integer(value), integer > 0 else { return nil }
        let text = String(integer)
        return digits.contains(text.count) ? text : nil
    }
    private static func integer(_ value: Any?) -> Int? {
        if let text = value as? String {
            guard !text.isEmpty, text.count <= 18, text.utf8.allSatisfy({ (48...57).contains($0) }) else { return nil }
            return Int(text)
        }
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite, number.doubleValue >= 0,
              number.doubleValue.rounded(.towardZero) == number.doubleValue,
              number.doubleValue <= 9_007_199_254_740_991 else { return nil }
        return Int(number.int64Value)
    }
    private static func validText(_ value: String, maximum: Int) -> Bool {
        !value.isEmpty && value.utf8.count <= maximum && !value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }
}
