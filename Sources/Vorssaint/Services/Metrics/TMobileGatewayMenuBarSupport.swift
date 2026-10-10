// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Foundation

/// Visual choices for the one connected-radio item. They never change which
/// radio is selected, the polling opt-in, or its complete spoken description.
struct TMobileGatewayMenuBarComponents: OptionSet {
    let rawValue: Int
    static let defaultsKey = "tMobileMenuBarComponents"
    static let technology = Self(rawValue: 1)
    static let bars = Self(rawValue: 2)
    static let bands = Self(rawValue: 4)
    static let all: Self = [.technology, .bars, .bands]

    static func sanitized(_ rawValue: Int) -> Self {
        (1...all.rawValue).contains(rawValue) ? Self(rawValue: rawValue) : .all
    }

    static var current: Self {
        sanitized(UserDefaults.standard.integer(forKey: defaultsKey))
    }

    func setting(_ component: Self, enabled: Bool) -> Self {
        let current = Self.sanitized(rawValue)
        let next = enabled ? current.union(component) : current.subtracting(component)
        // The main item checkmark owns hiding the entire item.
        return next.isEmpty ? current : Self.sanitized(next.rawValue)
    }

    var summary: String {
        switch Self.sanitized(rawValue) {
        case .technology: return "Technology only"
        case .bars: return "Signal bars only"
        case .bands: return "Bands only"
        case [.technology, .bars]: return "Technology & bars"
        case [.technology, .bands]: return "Technology & bands"
        case [.bars, .bands]: return "Bars & bands"
        default: return "Technology, bars & bands"
        }
    }
}

/// Legacy reading identities retained for saved preferences and detail routing.
/// The menu bar now renders one connected-radio indicator.
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
    struct ConnectionDisplay: Equatable {
        let badge: String
        let bands: String
        let bars: Int?
        let accessibilityValue: String
    }

    static func connection(snapshot: TMobileGatewaySnapshot?) -> ConnectionDisplay {
        guard let active = TMobileGatewayConnectedRadioSupport.select(from: snapshot) else {
            return .init(badge: "—", bands: "", bars: nil,
                         accessibilityValue: "T-Mobile connection: current radio unavailable")
        }
        // T-Mobile's published network table classifies these NR bands as UC.
        // This is a band-based label, not a gateway-reported UC flag or speed.
        let ucBands: Set<String> = ["n2", "n25", "n41", "n258", "n260", "n261"]
        let uc = active.technology == .fiveG && snapshot?.roaming != true
            && active.bands.contains { ucBands.contains($0) }
        let badge = uc ? "5G UC" : active.technologyLabel
        let bands = String(active.bands.prefix(3).joined(separator: "+").prefix(24))
            + (active.bands.count > 3 ? "+…" : "")
        let bars = active.radio.bars.flatMap { (0...5).contains($0) ? $0 : nil }
        let spokenBars = bars.map { "\($0) of 5 signal bars" } ?? "Signal unavailable"
        let spokenBands = active.bands.isEmpty ? "Band not reported" : "Reported bands \(active.bands.joined(separator: ", "))"
        let inference = uc ? ", UC inferred from the reported band" : ""
        return .init(badge: badge, bands: bands, bars: bars,
                     accessibilityValue: "T-Mobile connection: \(badge), \(spokenBands), \(spokenBars)\(inference)")
    }

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
