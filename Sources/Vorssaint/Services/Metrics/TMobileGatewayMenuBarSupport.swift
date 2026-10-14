// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Foundation

/// Independent pins for each radio. A band pin reports the gateway's current
/// band; it never changes radio configuration or locks a band.
enum TMobileGatewayMenuBarReading: String, CaseIterable {
    case lteSignal, fiveGSignal, lteBands, fiveGBands
    case lteRSRP, fiveGRSRP, lteSINR, fiveGSINR
    case lteRSRQ, fiveGRSRQ, lteRSSI, fiveGRSSI

    var isFiveG: Bool { rawValue.hasPrefix("fiveG") }
    var isSignal: Bool { self == .lteSignal || self == .fiveGSignal }
    var signalStyleDefaultsKey: String {
        isFiveG ? DefaultsKey.tMobile5GMenuBarSignalStyle : DefaultsKey.tMobileLTEMenuBarSignalStyle
    }
    var radioLabel: String { isFiveG ? "5G" : "LTE" }
    var title: String {
        let radio = isFiveG ? "5G" : "LTE (4G)"
        if isSignal { return "T-Mobile \(radio) signal" }
        if self == .lteBands || self == .fiveGBands { return "T-Mobile \(radio) bands" }
        return "T-Mobile \(radio) \(measurement)"
    }
    var measurement: String {
        switch self {
        case .lteSignal, .fiveGSignal: return "signal"
        case .lteBands, .fiveGBands: return "bands"
        case .lteRSRP, .fiveGRSRP: return "RSRP"
        case .lteSINR, .fiveGSINR: return "SINR"
        case .lteRSRQ, .fiveGRSRQ: return "RSRQ"
        case .lteRSSI, .fiveGRSSI: return "RSSI"
        }
    }
}

enum TMobileGatewayMenuBarSupport {
    struct Display: Equatable {
        let label: String
        let value: String
        let minimumValue: String
        let accessibilityValue: String
    }

    static func signalStyle(_ raw: String) -> String { raw == "value" ? "value" : "bars" }

    static func display(_ reading: TMobileGatewayMenuBarReading,
                        snapshot: TMobileGatewaySnapshot?, signalStyle rawStyle: String) -> Display {
        let radio = reading.isFiveG ? snapshot?.fiveG : snapshot?.lte
        let label = reading.isSignal ? reading.radioLabel
            : "\(reading.radioLabel) \(reading.measurement == "bands" ? "band" : reading.measurement)"
        let value: String
        let spoken: String
        let minimum: String
        if reading.isSignal {
            minimum = "▁▂▃▄▅"
            if let bars = radio?.bars, (0...5).contains(bars) {
                value = signalStyle(rawStyle) == "value" ? "\(bars)/5"
                    : String("▁▂▃▄▅".prefix(bars)) + String(repeating: "·", count: 5 - bars)
                spoken = "\(bars) of 5 bars"
            } else { value = "—"; spoken = "Unavailable" }
        } else if reading == .lteBands || reading == .fiveGBands {
            minimum = "n999+n999"
            let bands = radio?.bands ?? []
            value = bands.isEmpty ? "—" : String(bands.prefix(3).joined(separator: "+").prefix(24))
                + (bands.count > 3 ? "+…" : "")
            spoken = bands.isEmpty ? "Unavailable" : bands.joined(separator: ", ")
        } else {
            minimum = "−999.9"
            let number: Double?
            switch reading {
            case .lteRSRP, .fiveGRSRP: number = radio?.rsrp
            case .lteSINR, .fiveGSINR: number = radio?.sinr
            case .lteRSRQ, .fiveGRSRQ: number = radio?.rsrq
            case .lteRSSI, .fiveGRSSI: number = radio?.rssi
            default: number = nil
            }
            if let number, number.isFinite, abs(number) < 1_000 {
                value = String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), number)
                let unit = reading.measurement == "RSRP" || reading.measurement == "RSSI" ? "dBm" : "dB"
                spoken = "\(value) \(unit)"
            } else { value = "—"; spoken = "Unavailable" }
        }
        return Display(label: label, value: value, minimumValue: minimum,
                       accessibilityValue: "\(reading.title): \(spoken)")
    }

    /// The same decision serves the runtime and tests. Merely opening settings
    /// or the preview never requests gateway data.
    static func needsPolling(networkAvailable: Bool, panelVisible: Bool,
                             panelEnabled: Bool, menuBarEnabled: Bool, historyEnabled: Bool) -> Bool {
        networkAvailable && ((panelVisible && panelEnabled) || menuBarEnabled || historyEnabled)
    }
}
