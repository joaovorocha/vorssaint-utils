// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

enum TMobileGatewayIndicatorTests {
    static func run(_ suite: TestSuite) {
        func snapshot(_ bands: [String], roaming: Bool = false) -> TMobileGatewaySnapshot {
            .init(model: nil, firmware: nil, uptime: nil, registration: "registered", roaming: roaming,
                  lte: .init(bars: 5, bands: ["b66"], rsrp: -90, rsrq: nil, rssi: nil, sinr: nil),
                  fiveG: .init(bars: 2, bands: bands, rsrp: -100, rsrq: nil, rssi: nil, sinr: nil))
        }
        let uc = TMobileGatewayMenuBarSupport.connection(snapshot: snapshot(["n41"]))
        suite.expect(uc.badge == "5G UC" && uc.bands == "n41" && uc.bars == 2,
                     "one connection display combines selected NR badge, actual band and its own signal")
        suite.expect(uc.accessibilityValue.contains("2 of 5") && uc.accessibilityValue.contains("inferred")
                     && !uc.accessibilityValue.contains("b66"),
                     "spoken connection identifies the current radio and UC inference without LTE anchor bands")
        for band in ["n2", "n25", "n41", "n258", "n260", "n261"] {
            suite.expect(TMobileGatewayMenuBarSupport.connection(snapshot: snapshot([band])).badge == "5G UC",
                         "UC classification follows the published T-Mobile NR band table")
        }
        for band in ["n71", "n77", "n999"] {
            suite.expect(TMobileGatewayMenuBarSupport.connection(snapshot: snapshot([band])).badge == "5G",
                         "other or unknown bands do not invent a UC classification")
        }
        suite.expect(TMobileGatewayMenuBarSupport.connection(snapshot: snapshot(["n41"], roaming: true)).badge == "5G",
                     "a roaming connection does not infer T-Mobile UC branding from its band")
        let missing = TMobileGatewayMenuBarSupport.connection(snapshot: nil)
        suite.expect(missing.badge == "—" && missing.bands.isEmpty && missing.bars == nil,
                     "unavailable connection has no stale technology, band or invented zero signal")
        let noBands = TMobileGatewayMenuBarSupport.connection(snapshot: snapshot([]))
        suite.expect(noBands.badge == "5G" && noBands.bands.isEmpty
                     && noBands.accessibilityValue.contains("Band not reported"),
                     "a serving signal without a band remains honest about the missing band")
        let carrierAggregation = TMobileGatewayMenuBarSupport.connection(snapshot: snapshot(["n41", "n25"]))
        suite.expect(carrierAggregation.bands == "n41+n25", "reported active NR bands share one block without inventing a primary carrier")

        let order = Defaults.sanitizedMenuBarMetricOrder("cpu,tMobileLTEBands,memory,tMobile5G,tMobileLTERSRP,network")
        suite.expect(Array(order.prefix(4)) == ["cpu", "tMobile5G", "memory", "network"]
                     && order.filter { Defaults.legacyTMobileMetricNames.contains($0) } == ["tMobile5G"],
                     "legacy radio slots collapse at their first position into one connection choice")
        let domain = "com.vorssaint.tests.tmobile-indicator"
        let defaults = UserDefaults(suiteName: domain)!
        defaults.removePersistentDomain(forName: domain)
        defer { defaults.removePersistentDomain(forName: domain) }
        Defaults.migrateTMobileConnectionIndicator(in: defaults)
        suite.expect(!defaults.bool(forKey: DefaultsKey.menuBarTMobile5G), "a fresh profile stays opted out of background gateway reads")
        defaults.removePersistentDomain(forName: domain)
        defaults.set(true, forKey: DefaultsKey.menuBarTMobileLTEBands)
        Defaults.migrateTMobileConnectionIndicator(in: defaults)
        suite.expect(defaults.bool(forKey: DefaultsKey.menuBarTMobile5G), "existing LTE-only or band-only consent migrates to the combined indicator")
        defaults.set(false, forKey: DefaultsKey.menuBarTMobile5G)
        Defaults.migrateTMobileConnectionIndicator(in: defaults)
        suite.expect(!defaults.bool(forKey: DefaultsKey.menuBarTMobile5G), "a later explicit opt-out is not undone by legacy pins")
        suite.expect(SettingsBackupSupport.machineStateKeys.contains(DefaultsKey.tMobileUnifiedMenuBarMigrated)
                     && !SettingsBackupSupport.exportKeys().contains(DefaultsKey.tMobileUnifiedMenuBarMigrated),
                     "the local polling migration marker cannot be transported in a settings backup")
    }
}
