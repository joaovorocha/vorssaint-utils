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

    /// The same decision serves the runtime and tests. Merely opening settings
    /// or the preview never requests gateway data.
    static func needsPolling(networkAvailable: Bool, panelVisible: Bool,
                             panelEnabled: Bool, menuBarEnabled: Bool) -> Bool {
        networkAvailable && ((panelVisible && panelEnabled) || menuBarEnabled)
    }
}
