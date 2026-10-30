// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Foundation

enum TMobileSignalQuality: String, Codable, CaseIterable {
    case unknown, poor, fair, good, excellent

    var label: String {
        switch self {
        case .unknown: return "Unavailable"
        case .poor: return "Poor"
        case .fair: return "Fair"
        case .good: return "Good"
        case .excellent: return "Excellent"
        }
    }
}

enum TMobileSignalMetric: String, CaseIterable {
    case rsrp, rsrq, rssi, sinr

    var label: String { rawValue.uppercased() }
    var unit: String { self == .rsrp || self == .rssi ? "dBm" : "dB" }
    var explanation: String {
        switch self {
        case .rsrp: return "Reference signal power. A less negative value means a stronger cellular signal."
        case .rsrq: return "Reference signal quality. A less negative value usually means cleaner reception."
        case .rssi: return "Total received power, including interference and noise. Compare it on the same radio and bandwidth."
        case .sinr: return "Signal compared with interference and noise. A higher value means a cleaner cellular link."
        }
    }
}

/// Placement guidance, not a carrier rating or a predicted speed. Thresholds
/// are approximate app heuristics; keep the gateway's own bars independent.
enum TMobileGatewayDiagnostics {
    static func quality(for value: Double?, metric: TMobileSignalMetric) -> TMobileSignalQuality {
        guard let value, value.isFinite else { return .unknown }
        switch metric {
        case .rsrp:
            guard (-160 ... -20).contains(value) else { return .unknown }
            if value >= -85 { return .excellent }
            if value >= -95 { return .good }
            if value >= -105 { return .fair }
            return .poor
        case .rsrq:
            guard (-50 ... 0).contains(value) else { return .unknown }
            if value >= -7 { return .excellent }
            if value >= -10 { return .good }
            if value >= -15 { return .fair }
            return .poor
        case .sinr:
            guard (-40 ... 80).contains(value) else { return .unknown }
            if value >= 20 { return .excellent }
            if value >= 13 { return .good }
            if value >= 0 { return .fair }
            return .poor
        case .rssi:
            // RSSI includes noise and depends on channel bandwidth. Do not
            // manufacture a standalone quality verdict from total power.
            return .unknown
        }
    }

    static func quality(forRSRP value: Double?) -> String {
        quality(for: value, metric: .rsrp).label
    }

    static func bandDescription(_ band: String) -> String? {
        switch band.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "n41": return "2.5 GHz mid-band 5G; part of T-Mobile Ultra Capacity coverage."
        case "n71": return "600 MHz low-band 5G; part of T-Mobile Extended Range coverage."
        case "n2", "n25": return "1900 MHz mid-band 5G."
        case "b4", "b66": return "1700/2100 MHz LTE; band 66 extends band 4."
        case "b5": return "850 MHz LTE."
        case "b12": return "700 MHz low-band LTE."
        case "b71": return "600 MHz low-band LTE."
        default: return nil
        }
    }

    static func tips(for snapshot: TMobileGatewaySnapshot) -> [String] {
        let primary = snapshot.fiveG?.rsrp != nil ? snapshot.fiveG : snapshot.lte ?? snapshot.fiveG
        var result: [String] = []
        if let rsrp = primary?.rsrp, quality(for: rsrp, metric: .rsrp) == .poor {
            result.append("Try several gateway positions, including a higher shelf or window. Compare readings after the connection settles.")
        }
        if let sinr = primary?.sinr, sinr < 0 {
            result.append("Interference exceeds the measured signal. Compare SINR and RSRQ in another position; more bars alone may not improve the link.")
        } else if let rsrq = primary?.rsrq, rsrq < -15 {
            result.append("Signal quality is low. Compare RSRQ and SINR across several positions and at different times of day.")
        }
        if snapshot.fiveG == nil, snapshot.lte != nil {
            result.append("Only LTE measurements are available. This does not prove a 5G outage; the gateway may not be reporting a current 5G connection.")
        }
        if snapshot.roaming == true {
            result.append("The gateway reports roaming. Check your service and coverage in T-Life if this is unexpected.")
        }
        if primary?.bands.contains("n41") == true {
            result.append("n41 is T-Mobile's 2.5 GHz mid-band 5G. It can offer capacity, but the band name does not predict your speed.")
        } else if primary?.bands.contains("n71") == true {
            result.append("n71 is T-Mobile's 600 MHz Extended Range 5G. Compare real performance instead of treating a band change as a fault.")
        }
        result.append("Use Ethernet for a comparison test to separate cellular reception from Wi-Fi issues. Signal ratings are approximate and do not measure internet speed.")
        return result
    }

    /// Conventional 20-bit macro-eNB / 8-bit local-cell split only. Other LTE
    /// eNB formats exist: this is an estimate, never a confirmed tower identity.
    /// Do not pass a 5G NCI; its gNB split requires information we do not have.
    static func lteENodeBID(cellID: UInt64?) -> UInt32? {
        guard let cellID, cellID <= 0xFFFFFFF else { return nil }
        return UInt32(cellID >> 8)
    }

    static func lteSectorID(cellID: UInt64?) -> UInt8? {
        guard let cellID, cellID <= 0xFFFFFFF else { return nil }
        return UInt8(cellID & 0xFF)
    }
}
