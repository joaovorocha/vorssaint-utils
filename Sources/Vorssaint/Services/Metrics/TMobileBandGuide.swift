// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Foundation

/// General band education, never a prediction or a carrier deployment list.
/// Frequency references: 3GPP TS 38.104 v17.13.0 and TS 36.104 v17.10.0.
/// Propagation guidance: https://www.t-mobile.com/5g
enum TMobileBandGuide {
    struct Entry {
        let frequency: String
        let category: String
        let use: String
        let tradeoff: String
    }

    static let carrierSource = URL(string: "https://www.t-mobile.com/support/coverage/t-mobile-network")!
    static let nrSource = URL(string: "https://www.etsi.org/deliver/etsi_ts/138100_138199/138104/17.13.00_60/ts_138104v171300p.pdf")!
    static let lteSource = URL(string: "https://www.etsi.org/deliver/etsi_ts/136100_136199/136104/17.10.00_60/ts_136104v171000p.pdf")!

    static func entry(for band: String) -> Entry? {
        entries[band.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()]
    }

    private static let entries: [String: Entry] = [
        "n2": balanced("1.9 GHz"),
        "n5": low("850 MHz"),
        "n12": low("700 MHz"),
        "n25": balanced("1.9 GHz"),
        "n41": capacity("2.5 GHz"),
        "n48": cbrs,
        "n66": balanced("1.7 / 2.1 GHz"),
        "n71": low("600 MHz"),
        "n77": capacity("3.3–4.2 GHz"),
        "n258": millimeterWave("24.25–27.5 GHz"),
        "n260": millimeterWave("39 GHz"),
        "n261": millimeterWave("28 GHz"),
        "b2": balanced("1.9 GHz"),
        "b4": balanced("1.7 / 2.1 GHz"),
        "b5": low("850 MHz"),
        "b12": low("700 MHz"),
        "b41": capacity("2.5 GHz"),
        "b46": Entry(frequency: "5 GHz", category: "Unlicensed spectrum · Extra capacity",
                     use: "Can add data capacity alongside a licensed LTE connection.",
                     tradeoff: "Reach is limited, and the spectrum is shared with other nearby users."),
        "b48": cbrs,
        "b66": balanced("1.7 / 2.1 GHz"),
        "b71": low("600 MHz")
    ]

    private static func low(_ frequency: String) -> Entry {
        Entry(frequency: frequency, category: "Low-band · Coverage and indoor reach",
              use: "Useful for wider-area coverage and reaching farther into buildings.",
              tradeoff: "Capacity still depends on channel width and network load. A strong signal does not guarantee fast data.")
    }

    private static func balanced(_ frequency: String) -> Entry {
        Entry(frequency: frequency, category: "Mid-band · Coverage and capacity",
              use: "Balances reach and data capacity for everyday browsing, streaming, and downloads.",
              tradeoff: "Generally has less reach and indoor penetration than low-band, but better reach than millimeter wave.")
    }

    private static func capacity(_ frequency: String) -> Entry {
        Entry(frequency: frequency, category: "Mid-band · Data capacity",
              use: "Can provide wide channels for busy areas, large downloads, and streaming.",
              tradeoff: "Compared with low-band, reach and indoor penetration are usually more limited. Placement and signal quality matter.")
    }

    private static var cbrs: Entry {
        Entry(frequency: "3.5 GHz", category: "Shared mid-band · Local capacity",
              use: "CBRS spectrum can provide local data capacity and serve private or enterprise networks.",
              tradeoff: "Reach is more limited than low-band. Service depends on deployment and access to the shared spectrum.")
    }

    private static func millimeterWave(_ frequency: String) -> Entry {
        Entry(frequency: frequency, category: "High-band · Millimeter wave",
              use: "Wide channels can provide very high data capacity in compact areas.",
              tradeoff: "Reach is short, and walls or other obstacles can block reception. A nearby, clear path is especially useful.")
    }
}
