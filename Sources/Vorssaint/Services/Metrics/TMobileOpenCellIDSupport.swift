// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import CoreFoundation
import Foundation

enum TMobileOpenCellIDRadio: String, CaseIterable, Sendable { case lte = "LTE", nr = "NR" }
enum TMobileOpenCellIDPhase: Equatable { case idle, loading, ready, failed }
enum TMobileOpenCellIDFailure: Error, Equatable {
    case invalidInput, invalidResponse, identityMismatch, notFound, authentication, limit, unavailable, cancelled

    var message: String {
        switch self {
        case .invalidInput: return "Enter valid manual cell identifiers, an API key and your confirmation before looking up a cell."
        case .invalidResponse: return "OpenCellID returned an unsupported response. No coordinates were accepted."
        case .identityMismatch: return "The returned cell identifiers do not match your request. No coordinates were accepted."
        case .notFound: return "OpenCellID has no result for this cell. Check the identifiers; community coverage can be incomplete."
        case .authentication: return "OpenCellID rejected the API key. Enter a valid key to try again."
        case .limit: return "OpenCellID reports that your request allowance is exhausted. Try again after your allowance resets."
        case .unavailable: return "OpenCellID could not complete the lookup. Check the connection and try again manually."
        case .cancelled: return "The lookup was cancelled."
        }
    }
}

/// Manual provider identifiers, never derived from a modem node or sector CID.
struct TMobileOpenCellIDIdentity: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    let radio: TMobileOpenCellIDRadio
    let mcc: String
    let mnc: String
    let tac: UInt32
    let cellID: UInt64

    init?(radio: TMobileOpenCellIDRadio, mcc: String, mnc: String, tac: String, cellID: String) {
        guard mcc.utf8.count == 3, let mccValue = TMobileOpenCellIDSupport.unsigned(mcc), mccValue > 0,
              (1...3).contains(mnc.utf8.count), TMobileOpenCellIDSupport.unsigned(mnc) != nil,
              let area = TMobileOpenCellIDSupport.unsigned(tac), area <= (radio == .lte ? 0xFFFF : 0xFFFFFF),
              let cell = TMobileOpenCellIDSupport.unsigned(cellID), cell <= (radio == .lte ? 0xFFFFFFF : 0xFFFFFFFFF)
        else { return nil }
        self.radio = radio; self.mcc = mcc; self.mnc = mnc; self.tac = UInt32(area); self.cellID = cell
    }
    var description: String { "<manual OpenCellID identity>" }
    var debugDescription: String { description }
    var disclosure: String { "\(radio.rawValue) · MCC \(mcc) · MNC \(mnc) · TAC \(tac) · full cell ID \(cellID)" }
}

/// Displayed only in the explicit lookup view. No Codable/history contract.
struct TMobileOpenCellIDResult: Equatable, CustomStringConvertible, CustomDebugStringConvertible {
    let identity: TMobileOpenCellIDIdentity
    let latitude: Double
    let longitude: Double
    let rangeMeters: Double?
    let samples: UInt64?
    let changeable: Bool?
    var description: String { "<OpenCellID result>" }
    var debugDescription: String { description }
}

enum TMobileOpenCellIDSupport {
    static let maximumResponseBytes = 64 * 1024
    static let provider = URL(string: "https://opencellid.org")!
    static let license = URL(string: "https://creativecommons.org/licenses/by-sa/4.0/")!
    static let documentation = URL(string: "https://wiki.opencellid.org/docs/api/cell-position")!

    static func validToken(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 8192 && value.utf8.allSatisfy { (33...126).contains($0) }
    }

    static func requestURL(identity: TMobileOpenCellIDIdentity, token: String) throws -> URL {
        guard validToken(token) else { throw TMobileOpenCellIDFailure.invalidInput }
        let fields = [("key", token), ("mcc", identity.mcc), ("mnc", identity.mnc),
                      ("lac", String(identity.tac)), ("cellid", String(identity.cellID)),
                      ("radio", identity.radio.rawValue), ("format", "json")]
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        var components = URLComponents(string: "https://opencellid.org/cell/get")!
        components.percentEncodedQuery = fields.map { name, value in
            name + "=" + value.addingPercentEncoding(withAllowedCharacters: allowed)!
        }.joined(separator: "&")
        guard let url = components.url else { throw TMobileOpenCellIDFailure.invalidInput }
        return url
    }

    static func parse(_ data: Data, requested identity: TMobileOpenCellIDIdentity) throws -> TMobileOpenCellIDResult {
        guard !data.isEmpty, data.count <= maximumResponseBytes,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw TMobileOpenCellIDFailure.invalidResponse
        }
        var count = 0
        guard validJSON(root, depth: 0, count: &count) else { throw TMobileOpenCellIDFailure.invalidResponse }
        if root["error"] != nil || root["code"] != nil {
            switch integer(root["code"]) {
            case 1: throw TMobileOpenCellIDFailure.notFound
            case 2: throw TMobileOpenCellIDFailure.authentication
            case 3: throw TMobileOpenCellIDFailure.invalidInput
            case 7: throw TMobileOpenCellIDFailure.limit
            default: throw TMobileOpenCellIDFailure.unavailable
            }
        }
        guard root["radio"] as? String == identity.radio.rawValue,
              integer(root["mcc"]) == unsigned(identity.mcc), integer(root["mnc"]) == unsigned(identity.mnc),
              integer(root["lac"]) == UInt64(identity.tac), integer(root["cellid"]) == identity.cellID else {
            throw TMobileOpenCellIDFailure.identityMismatch
        }
        guard let latitude = number(root["lat"]), (-90...90).contains(latitude),
              let longitude = number(root["lon"]), (-180...180).contains(longitude) else {
            throw TMobileOpenCellIDFailure.invalidResponse
        }
        let range = number(root["range"]).flatMap { $0 >= 0 ? $0 : nil }
        let samples = integer(root["samples"]).flatMap { $0 > 0 ? $0 : nil }
        let changeable = integer(root["changeable"]).flatMap { $0 <= 1 ? $0 == 1 : nil }
        return .init(identity: identity, latitude: latitude, longitude: longitude,
                     rangeMeters: range, samples: samples, changeable: changeable)
    }

    static func unsigned(_ value: String) -> UInt64? {
        guard !value.isEmpty, value.utf8.count <= 20, value.utf8.allSatisfy({ (48...57).contains($0) }) else { return nil }
        return UInt64(value)
    }
    private static func integer(_ raw: Any?) -> UInt64? {
        guard let number = raw as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        return unsigned(number.stringValue)
    }
    private static func number(_ raw: Any?) -> Double? {
        guard let number = raw as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite else { return nil }
        return number.doubleValue
    }
    private static func validJSON(_ value: Any, depth: Int, count: inout Int) -> Bool {
        count += 1
        guard count <= 1024, depth <= 8 else { return false }
        if let object = value as? [String: Any] {
            return object.count <= 128 && object.allSatisfy { key, child in
                key.utf8.count <= 128 && validJSON(child, depth: depth + 1, count: &count)
            }
        }
        if let values = value as? [Any] {
            return values.count <= 128 && values.allSatisfy { validJSON($0, depth: depth + 1, count: &count) }
        }
        if let string = value as? String { return string.utf8.count <= 8192 }
        if let number = value as? NSNumber { return number.doubleValue.isFinite }
        return value is NSNull
    }
}
