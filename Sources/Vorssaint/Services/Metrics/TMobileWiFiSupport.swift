// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import CoreFoundation
import Foundation

enum TMobileWiFiPhase: Equatable {
    case signedOut, connecting, loading, ready, reviewing, applying, verifying, verified, conflict, outcomeUnknown, failed
}

enum TMobileWiFiField: String, CaseIterable { case name, password, broadcast, guest }

struct TMobileWiFiSSID: Identifiable, Equatable {
    let id: Int
    let name: String?
    let passwordPresent: Bool
    let broadcastEnabled: Bool?
    let guest: Bool?
    let twoPointFourEnabled: Bool?
    let fiveEnabled: Bool?
    let encryptionMode: String?
    let encryptionVersion: String?
    let editableFields: Set<TMobileWiFiField>
}

struct TMobileWiFiRadio: Identifiable, Equatable {
    let id: String
    let isEnabled: Bool?
    let channel: String?
    let bandwidth: String?
    let mode: String?
    let transmissionPower: String?
    let maxClients: Int?
    let muMIMOEnabled: Bool?
    let wmmEnabled: Bool?
    let airtimeFairness: Bool?
}

struct TMobileWiFiConfiguration: Equatable {
    let ssids: [TMobileWiFiSSID]
    let radios: [TMobileWiFiRadio]
    let bandSteeringEnabled: Bool?
}

/// Never make this Codable or publish it: a replacement password belongs only
/// to the local editor and the private, short-lived review transaction.
struct TMobileWiFiEdit: CustomStringConvertible, CustomDebugStringConvertible {
    let ssidID: Int
    var name: String? = nil
    var password: String? = nil
    var broadcastEnabled: Bool? = nil
    var guest: Bool? = nil
    var description: String { "TMobileWiFiEdit(redacted)" }
    var debugDescription: String { description }
}

struct TMobileWiFiReview: Identifiable, Equatable {
    let id: UUID
    let origin: String
    let changes: [String]
    let isRestore: Bool
}

enum TMobileWiFiFailure: Error {
    case invalidResponse, invalidEdit, incompleteCredentials, authenticationRequired, unavailable, cancelled
}

enum TMobileWiFiSupport {
    static let maximumResponseBytes = 128 * 1024

    static func token(from data: Data) throws -> String {
        let root = try object(data)
        let auth = root["auth"] as? [String: Any]
        guard let token = (auth?["token"] ?? root["token"]) as? String,
              !token.isEmpty, token.utf8.count <= 8192,
              token.utf8.allSatisfy({ (33...126).contains($0) }) else { throw TMobileWiFiFailure.invalidResponse }
        return token
    }

    static func validName(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 32 && !hasControls(value)
    }

    static func validPassword(_ value: String) -> Bool {
        (8...63).contains(value.utf8.count) && value.utf8.allSatisfy { (32...126).contains($0) }
            && !value.allSatisfy({ $0 == "*" })
            && !["<redacted>", "redacted", "<hidden>"].contains(value.lowercased())
    }

    fileprivate static func object(_ data: Data) throws -> [String: Any] {
        guard !data.isEmpty, data.count <= maximumResponseBytes,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw TMobileWiFiFailure.invalidResponse
        }
        var count = 0
        guard validJSON(root, depth: 0, count: &count) else { throw TMobileWiFiFailure.invalidResponse }
        return root
    }

    private static func validJSON(_ value: Any, depth: Int, count: inout Int) -> Bool {
        count += 1
        guard count <= 4096, depth <= 12 else { return false }
        if let dict = value as? [String: Any] {
            return dict.count <= 256 && dict.allSatisfy { key, child in
                key.utf8.count <= 128 && !hasControls(key) && validJSON(child, depth: depth + 1, count: &count)
            }
        }
        if let array = value as? [Any] {
            return array.count <= 256 && array.allSatisfy { validJSON($0, depth: depth + 1, count: &count) }
        }
        if let string = value as? String { return string.utf8.count <= 4096 }
        if let number = value as? NSNumber { return number.doubleValue.isFinite }
        return value is NSNull
    }

    fileprivate static func text(_ value: Any?) -> String? {
        guard let value = value as? String, !value.isEmpty, value.utf8.count <= 128, !hasControls(value) else { return nil }
        return value
    }

    fileprivate static func bool(_ value: Any?) -> Bool? {
        guard let value = value as? NSNumber, CFGetTypeID(value) == CFBooleanGetTypeID() else { return nil }
        return value.boolValue
    }

    fileprivate static func display(_ value: Any?) -> String? {
        if let text = text(value) { return text }
        guard let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(),
              value.doubleValue.isFinite else { return nil }
        return value.stringValue
    }

    private static func hasControls(_ value: String) -> Bool {
        value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }
}

/// Contains credential-bearing JSON. Keep private to the admin service; only
/// `configuration` crosses into ObservableObject/UI state. No disk persistence.
struct TMobileWiFiPayload: CustomStringConvertible, CustomDebugStringConvertible {
    private let root: [String: Any]
    let configuration: TMobileWiFiConfiguration
    private let canonical: Data
    var description: String { "TMobileWiFiPayload(redacted)" }
    var debugDescription: String { description }

    init(data: Data) throws {
        let root = try TMobileWiFiSupport.object(data)
        guard let rows = root["ssids"] as? [[String: Any]], !rows.isEmpty, rows.count <= 16 else {
            throw TMobileWiFiFailure.invalidResponse
        }
        self.root = root
        canonical = try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
        let ssids = rows.enumerated().map { index, row in
            var fields = Set<TMobileWiFiField>()
            let name = TMobileWiFiSupport.text(row["ssidName"])
            if let name, TMobileWiFiSupport.validName(name) { fields.insert(.name) }
            if row["wpaKey"] is String { fields.insert(.password) }
            let broadcast = TMobileWiFiSupport.bool(row["isBroadcastEnabled"])
            if broadcast != nil { fields.insert(.broadcast) }
            let guest = TMobileWiFiSupport.bool(row["guest"])
            if guest != nil { fields.insert(.guest) }
            return TMobileWiFiSSID(id: index, name: name, passwordPresent: row["wpaKey"] is String,
                                  broadcastEnabled: broadcast, guest: guest,
                                  twoPointFourEnabled: TMobileWiFiSupport.bool(row["2.4ghzSsid"]),
                                  fiveEnabled: TMobileWiFiSupport.bool(row["5.0ghzSsid"]),
                                  encryptionMode: TMobileWiFiSupport.text(row["encryptionMode"]),
                                  encryptionVersion: TMobileWiFiSupport.text(row["encryptionVersion"]), editableFields: fields)
        }
        let radios = ["2.4ghz", "5.0ghz"].compactMap { key -> TMobileWiFiRadio? in
            guard let row = root[key] as? [String: Any] else { return nil }
            let maxClients = TMobileWiFiSupport.display(row["maxClients"]).flatMap(Int.init).flatMap { (0...4096).contains($0) ? $0 : nil }
            return TMobileWiFiRadio(id: key, isEnabled: TMobileWiFiSupport.bool(row["isRadioEnabled"]),
                                   channel: TMobileWiFiSupport.display(row["channel"]),
                                   bandwidth: TMobileWiFiSupport.display(row["channelBandwidth"]),
                                   mode: TMobileWiFiSupport.text(row["mode"]),
                                   transmissionPower: TMobileWiFiSupport.display(row["transmissionPower"]), maxClients: maxClients,
                                   muMIMOEnabled: TMobileWiFiSupport.bool(row["isMUMIMOEnabled"]),
                                   wmmEnabled: TMobileWiFiSupport.bool(row["isWMMEnabled"]),
                                   airtimeFairness: TMobileWiFiSupport.bool(row["airtimeFairness"]))
        }
        configuration = .init(ssids: ssids, radios: radios,
                              bandSteeringEnabled: TMobileWiFiSupport.bool((root["bandSteering"] as? [String: Any])?["isEnabled"]))
    }

    func sameConfiguration(as other: TMobileWiFiPayload) -> Bool { canonical == other.canonical }
    func encoded() -> Data { canonical }

    func applying(_ edits: [TMobileWiFiEdit]) throws -> (payload: TMobileWiFiPayload, changes: [String]) {
        guard !edits.isEmpty, edits.count <= 16, Set(edits.map(\.ssidID)).count == edits.count,
              var rows = root["ssids"] as? [[String: Any]] else { throw TMobileWiFiFailure.invalidEdit }
        var changes: [String] = []
        for edit in edits {
            guard rows.indices.contains(edit.ssidID) else { throw TMobileWiFiFailure.invalidEdit }
            let allowed = configuration.ssids[edit.ssidID].editableFields
            var row = rows[edit.ssidID]
            if let name = edit.name {
                guard allowed.contains(.name), TMobileWiFiSupport.validName(name) else { throw TMobileWiFiFailure.invalidEdit }
                if row["ssidName"] as? String != name {
                    let previous = configuration.ssids[edit.ssidID].name ?? "Not reported"
                    row["ssidName"] = name
                    changes.append("Network \(edit.ssidID + 1): name “\(previous)” → “\(name)”")
                }
            }
            if let password = edit.password {
                guard allowed.contains(.password), TMobileWiFiSupport.validPassword(password) else { throw TMobileWiFiFailure.invalidEdit }
                if row["wpaKey"] as? String != password { row["wpaKey"] = password; changes.append("Network \(edit.ssidID + 1): password will change (hidden)") }
            }
            if let broadcast = edit.broadcastEnabled {
                guard allowed.contains(.broadcast) else { throw TMobileWiFiFailure.invalidEdit }
                if TMobileWiFiSupport.bool(row["isBroadcastEnabled"]) != broadcast {
                    row["isBroadcastEnabled"] = broadcast; changes.append("Network \(edit.ssidID + 1): broadcast will turn \(broadcast ? "on" : "off")")
                }
            }
            if let guest = edit.guest {
                guard allowed.contains(.guest) else { throw TMobileWiFiFailure.invalidEdit }
                if TMobileWiFiSupport.bool(row["guest"]) != guest { row["guest"] = guest; changes.append("Network \(edit.ssidID + 1): guest mode will turn \(guest ? "on" : "off")") }
            }
            rows[edit.ssidID] = row
        }
        // Full POSTs must never send a redaction placeholder or silently omit
        // a protected network's credential. Require explicit replacement first.
        guard rows.allSatisfy({ ($0["wpaKey"] as? String).map(TMobileWiFiSupport.validPassword) == true }) else {
            throw TMobileWiFiFailure.incompleteCredentials
        }
        var updated = root
        updated["ssids"] = rows
        return (try TMobileWiFiPayload(data: JSONSerialization.data(withJSONObject: updated, options: [.sortedKeys])), changes)
    }

    func inverse(of edits: [TMobileWiFiEdit]) throws -> [TMobileWiFiEdit] {
        guard let rows = root["ssids"] as? [[String: Any]] else { throw TMobileWiFiFailure.invalidResponse }
        return try edits.map { edit in
            guard rows.indices.contains(edit.ssidID) else { throw TMobileWiFiFailure.invalidEdit }
            let row = rows[edit.ssidID]
            var inverse = TMobileWiFiEdit(ssidID: edit.ssidID)
            if edit.name != nil { inverse.name = row["ssidName"] as? String }
            if edit.password != nil {
                guard let password = row["wpaKey"] as? String, TMobileWiFiSupport.validPassword(password) else { throw TMobileWiFiFailure.incompleteCredentials }
                inverse.password = password
            }
            if edit.broadcastEnabled != nil { inverse.broadcastEnabled = TMobileWiFiSupport.bool(row["isBroadcastEnabled"]) }
            if edit.guest != nil { inverse.guest = TMobileWiFiSupport.bool(row["guest"]) }
            return inverse
        }
    }
}
