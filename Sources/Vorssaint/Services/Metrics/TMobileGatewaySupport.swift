// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import CoreFoundation
import Foundation

enum TMobileGatewayFailure: Error, Equatable {
    case invalidAddress, authenticationRequired, unavailable, invalidResponse
}

enum TMobileGatewayPhase: Equatable {
    case idle, loading, ready
    case failed(TMobileGatewayFailure)
}

struct TMobileRadioSignal: Equatable {
    let bars: Int?
    let bands: [String]
    let rsrp: Double?
    let rsrq: Double?
    let rssi: Double?
    let sinr: Double?
}

struct TMobileGatewaySnapshot: Equatable {
    let model: String?
    let firmware: String?
    let uptime: TimeInterval?
    let registration: String?
    let roaming: Bool?
    let lte: TMobileRadioSignal?
    let fiveG: TMobileRadioSignal?

    var primaryRadioLabel: String? {
        if fiveG?.rsrp != nil { return "5G" }
        if lte != nil { return "LTE" }
        return fiveG == nil ? nil : "5G"
    }
}

/// Only the gateway's documented public status fields cross this boundary.
/// Credentials, client identifiers, SIM information and GPS are never retained.
enum TMobileGatewaySupport {
    static func privateLANBaseURL(_ input: String) -> URL? {
        let scheme: String
        if input.hasPrefix("http://") { scheme = "http" }
        else if input.hasPrefix("https://") { scheme = "https" }
        else { return nil }

        var authority = String(input.dropFirst(scheme.count + 3))
        if authority.hasSuffix("/") { authority.removeLast() }
        let parts = authority.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 1 || parts.count == 2 else { return nil }
        let host = String(parts[0])
        let octets = host.split(separator: ".", omittingEmptySubsequences: false)
        guard octets.count == 4 else { return nil }
        var numbers: [Int] = []
        for octet in octets {
            guard !octet.isEmpty, octet.utf8.allSatisfy({ (48...57).contains($0) }),
                  octet.count == 1 || octet.first != "0",
                  let value = Int(octet), (0...255).contains(value) else { return nil }
            numbers.append(value)
        }
        let isPrivate = numbers[0] == 10
            || (numbers[0] == 172 && (16...31).contains(numbers[1]))
            || (numbers[0] == 192 && numbers[1] == 168)
        guard isPrivate else { return nil }

        if parts.count == 2 {
            let port = parts[1]
            guard !port.isEmpty, port.utf8.allSatisfy({ (48...57).contains($0) }),
                  port.first != "0", let number = Int(port), (1...65535).contains(number)
            else { return nil }
        }
        // Rebuilding from validated ASCII components prevents URL parser repair,
        // percent escaping, userinfo and alternate IPv4 spellings from slipping in.
        return URL(string: "\(scheme)://\(authority)")
    }

    static func parse(_ data: Data) throws -> TMobileGatewaySnapshot {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let root = object as? [String: Any],
              ["device", "time", "signal"].contains(where: { root[$0] is [String: Any] })
        else { throw TMobileGatewayFailure.invalidResponse }
        let device = root["device"] as? [String: Any] ?? [:]
        let time = root["time"] as? [String: Any] ?? [:]
        let signal = root["signal"] as? [String: Any] ?? [:]
        let generic = signal["generic"] as? [String: Any] ?? [:]
        let uptime = number(time["upTime"])
        return TMobileGatewaySnapshot(
            model: text(device["model"]) ?? text(device["friendlyName"]),
            firmware: text(device["softwareVersion"]),
            uptime: uptime.flatMap { $0 >= 0 ? $0 : nil },
            registration: text(generic["registration"]),
            roaming: boolean(generic["roaming"]),
            lte: radio(signal["4g"]), fiveG: radio(signal["5g"]))
    }

    static func pollingDelay(errorStreak: Int) -> TimeInterval {
        errorStreak <= 0 ? 15 : min(15 * pow(2, Double(min(errorStreak, 3))), 120)
    }

    private static func radio(_ value: Any?) -> TMobileRadioSignal? {
        guard let object = value as? [String: Any] else { return nil }
        let barValue = number(object["bars"])
        let bars = barValue.flatMap { (0...5).contains($0) ? Int($0.rounded()) : nil }
        let bands: [String]
        if let array = object["bands"] as? [Any] { bands = array.compactMap(text) }
        else { bands = text(object["bands"]).map { [$0] } ?? [] }
        let rsrp = number(object["rsrp"]), rsrq = number(object["rsrq"])
        let rssi = number(object["rssi"]), sinr = number(object["sinr"])
        guard bars != nil || !bands.isEmpty || rsrp != nil || rsrq != nil || rssi != nil || sinr != nil
        else { return nil }
        return TMobileRadioSignal(bars: bars, bands: bands, rsrp: rsrp, rsrq: rsrq, rssi: rssi, sinr: sinr)
    }

    private static func text(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 128,
              trimmed.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) })
        else { return nil }
        return trimmed
    }

    private static func number(_ value: Any?) -> Double? {
        let result: Double?
        if let number = value as? NSNumber {
            guard CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
            result = number.doubleValue
        } else if let string = value as? String {
            result = Double(string.trimmingCharacters(in: .whitespacesAndNewlines))
        } else { result = nil }
        return result.flatMap { $0.isFinite ? $0 : nil }
    }

    private static func boolean(_ value: Any?) -> Bool? {
        if let number = value as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return number.boolValue }
            if number == 0 { return false }
            if number == 1 { return true }
        }
        if let text = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            if ["true", "1"].contains(text) { return true }
            if ["false", "0"].contains(text) { return false }
        }
        return nil
    }
}
