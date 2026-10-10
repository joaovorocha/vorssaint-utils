// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import CoreFoundation
import Foundation

enum TMobileCellTelemetryPhase: Equatable { case signedOut, connecting, loading, ready, failed }
enum TMobileCellTelemetryFailure: Error, Equatable { case invalidResponse, authenticationRequired, unavailable, cancelled }

/// Session-only serving-cell details. Supported bands describe the modem's
/// inventory, not neighboring cells or bands that are currently connected.
/// This report deliberately has no persistence or history encoding contract.
struct TMobileCellTelemetryRadio: Equatable {
    let signal: TMobileRadioSignal
    let ecgi: String?
    let supportedBands: [String]
}

struct TMobileCellTelemetryReport: Equatable {
    let lte: TMobileCellTelemetryRadio?
    let fiveG: TMobileCellTelemetryRadio?
}

enum TMobileCellTelemetrySupport {
    static let maximumResponseBytes = 128 * 1024

    static func token(from data: Data) throws -> String {
        let root = try object(data)
        let auth = root["auth"] as? [String: Any]
        guard let token = (auth?["token"] ?? root["token"]) as? String,
              !token.isEmpty, token.utf8.count <= 8192,
              token.utf8.allSatisfy({ (33...126).contains($0) })
        else { throw TMobileCellTelemetryFailure.invalidResponse }
        return token
    }

    static func parse(_ data: Data) throws -> TMobileCellTelemetryReport {
        let root = try object(data)
        let cell: [String: Any]
        if let wrapped = root["cell"] {
            guard let value = wrapped as? [String: Any] else { throw TMobileCellTelemetryFailure.invalidResponse }
            cell = value
        } else { cell = root }
        guard ["4g", "5g"].contains(where: { cell[$0] is [String: Any] }) else {
            throw TMobileCellTelemetryFailure.invalidResponse
        }
        let report = try TMobileCellTelemetryReport(lte: radio(cell["4g"], key: "4g"),
                                                  fiveG: radio(cell["5g"], key: "5g"))
        guard report.lte != nil || report.fiveG != nil else { throw TMobileCellTelemetryFailure.invalidResponse }
        return report
    }

    private static func radio(_ raw: Any?, key: String) throws -> TMobileCellTelemetryRadio? {
        guard let raw = raw as? [String: Any] else { return nil }
        let sector = raw["sector"] as? [String: Any] ?? [:]
        // The source resource confirms these flat fields and sector aliases.
        // Copy only this allowlist into the existing public radio validator;
        // never pass GPS, SIM, clients, credentials or an entire raw response.
        var values: [String: Any] = [:]
        for field in ["bars", "rsrp", "rsrq", "rssi", "sinr", "antennaUsed", "bandwidth", "cqi"] {
            values[field] = raw[field]
        }
        values["bands"] = first(raw, ["bands"]) ?? first(sector, ["bands"])
        values["cid"] = first(raw, ["cid", "cellId"]) ?? first(sector, ["cid", "cellId"])
        values["pci"] = first(raw, ["pci", "PCI"])
        values["tac"] = first(raw, ["tac", "TAC"])
        values["earfcn"] = first(raw, ["earfcn", "arfcn", "nrarfcn", "ARFCN"])
        values["gNBID"] = first(raw, ["gNBID", "gnbid", "gnbId", "gNodeBID"])
            ?? first(sector, ["gNBID", "gnbid", "gnbId", "gNodeBID"])
        values["eNBID"] = first(raw, ["eNBID", "eNodeBID", "enbid", "enbId"])
            ?? first(sector, ["eNBID", "eNodeBID", "enbid", "enbId"])
        let ecgi = identity(first(raw, ["ecgi", "ECGI"]))
        values["ecgi"] = ecgi
        let supportedBands = try bands(raw["supportedBands"], key: key)
        if !supportedBands.isEmpty { values["supportedBands"] = supportedBands }

        let encoded = try JSONSerialization.data(withJSONObject: ["signal": [key: values]])
        let snapshot = try TMobileGatewaySupport.parse(encoded)
        let signal = key == "5g" ? snapshot.fiveG : snapshot.lte
        guard signal != nil || ecgi != nil || !supportedBands.isEmpty else { return nil }
        return TMobileCellTelemetryRadio(signal: signal ?? TMobileRadioSignal(bars: nil, bands: [], rsrp: nil,
                                                                              rsrq: nil, rssi: nil, sinr: nil),
                                          ecgi: ecgi, supportedBands: supportedBands)
    }

    private static func bands(_ value: Any?, key: String) throws -> [String] {
        guard let value = value as? [Any] else { return [] }
        let encoded = try JSONSerialization.data(withJSONObject: ["signal": [key: ["bands": value]]])
        let snapshot = try TMobileGatewaySupport.parse(encoded)
        return (key == "5g" ? snapshot.fiveG : snapshot.lte)?.bands ?? []
    }

    private static func first(_ object: [String: Any], _ names: [String]) -> Any? {
        names.lazy.compactMap { name -> Any? in
            guard let value = object[name], !(value is NSNull) else { return nil }
            return value
        }.first
    }

    /// Retain the explicitly returned opaque identity, with no cell/node
    /// calculation. Accept decimal/hex digits and the common PLMN separators.
    private static func identity(_ raw: Any?) -> String? {
        let value: String
        if let string = raw as? String { value = string.trimmingCharacters(in: .whitespacesAndNewlines) }
        else if let number = raw as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() {
            value = number.stringValue
        } else { return nil }
        guard !value.isEmpty, value.utf8.count <= 64,
              value.utf8.contains(where: { (48...57).contains($0) }) else { return nil }
        let digits = value.lowercased().hasPrefix("0x") ? value.dropFirst(2) : value[...]
        let components = digits.split(whereSeparator: { $0 == "-" || $0 == ":" })
        guard !digits.isEmpty, digits.first != "-", digits.first != ":", digits.last != "-", digits.last != ":",
              !digits.contains("--"), !digits.contains("::"), !digits.contains("-:"), !digits.contains(":-"),
              !components.isEmpty, components.contains(where: { $0.contains(where: { $0 != "0" }) }),
              digits.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0)
                  || (97...102).contains($0) || $0 == 45 || $0 == 58 }) else { return nil }
        return value
    }

    private static func object(_ data: Data) throws -> [String: Any] {
        guard !data.isEmpty, data.count <= maximumResponseBytes,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw TMobileCellTelemetryFailure.invalidResponse
        }
        var count = 0
        guard validJSON(root, depth: 0, count: &count) else { throw TMobileCellTelemetryFailure.invalidResponse }
        return root
    }

    private static func validJSON(_ value: Any, depth: Int, count: inout Int) -> Bool {
        count += 1
        guard count <= 4096, depth <= 12 else { return false }
        if let object = value as? [String: Any] {
            return object.count <= 256 && object.allSatisfy { key, child in
                key.utf8.count <= 128 && !key.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
                    && validJSON(child, depth: depth + 1, count: &count)
            }
        }
        if let values = value as? [Any] {
            return values.count <= 256 && values.allSatisfy { validJSON($0, depth: depth + 1, count: &count) }
        }
        if let string = value as? String { return string.utf8.count <= 4096 }
        if let number = value as? NSNumber { return number.doubleValue.isFinite }
        return value is NSNull
    }
}
