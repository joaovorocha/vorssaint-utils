// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Foundation

enum TMobileGatewayIntegrationTests {
    static func run(_ suite: TestSuite) {
        menuBarReadings(suite)
        suite.expect(Defaults.registeredDefaults[DefaultsKey.monitorNetTMobile] as? Bool == false,
                     "gateway polling requires an explicit opt-in on each Mac")
        let exportedKeys = SettingsBackupSupport.exportKeys()
        let networkConsentKeys = ["menuBarTMobileLTE", "menuBarTMobile5G", "menuBarTMobileLTEBands", "menuBarTMobile5GBands",
                                  "menuBarTMobileLTERSRP", "menuBarTMobile5GRSRP", "menuBarTMobileLTERSINR", "menuBarTMobile5GSINR",
                                  "menuBarTMobileLTERSRQ", "menuBarTMobile5GRSRQ", "menuBarTMobileLTERSSI", "menuBarTMobile5GRSSI", "tMobileHistoryRecording"]
        suite.expect(networkConsentKeys.allSatisfy { !exportedKeys.contains($0) && SettingsBackupSupport.machineStateKeys.contains($0) },
                     "portable backups cannot enable background radio polling or local location history")
        suite.expect(!exportedKeys.contains(DefaultsKey.monitorNetTMobile)
                     && !exportedKeys.contains(DefaultsKey.tMobileGatewayAddress),
                     "restoring a backup cannot enable requests to another network's gateway")
        let info = NSDictionary(contentsOfFile: "Resources/Info.plist")
        let transport = info?["NSAppTransportSecurity"] as? [String: Any]
        suite.expect(transport?["NSAllowsLocalNetworking"] as? Bool == true
                     && transport?["NSAllowsArbitraryLoads"] as? Bool != true,
                     "HTTP gateway reads use the local ATS exception without disabling internet ATS")
        for language in AppLanguage.allCases {
            let strings = TMobileGatewayStrings.localized(language)
            let fields = Mirror(reflecting: strings).children.compactMap { $0.value as? String }
            suite.expect(!fields.isEmpty && fields.allSatisfy { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty },
                         "gateway labels and recovery instructions exist for \(language.rawValue)")
        }
        for language in info?["CFBundleLocalizations"] as? [String] ?? [] {
            let localized = language == "en" ? info
                : NSDictionary(contentsOfFile: "Resources/\(language).lproj/InfoPlist.strings")
            let prompt = localized?["NSLocalNetworkUsageDescription"] as? String ?? ""
            suite.expect(!prompt.isEmpty, "local network consent explains gateway reads in \(language)")
        }
    }

    private static func menuBarReadings(_ suite: TestSuite) {
        let fixture = #"{"signal":{"4g":{"bars":4,"bands":["b2","b66"],"rsrp":-92.5,"sinr":9.4,"rsrq":-10.2,"rssi":-64},"5g":{"bars":3,"bands":["n41"],"rsrp":-97,"sinr":6,"rsrq":-11,"rssi":-68}}}"#
        let snapshot = try? TMobileGatewaySupport.parse(Data(fixture.utf8))
        let display = TMobileGatewayMenuBarSupport.display
        suite.expect(display(.lteSignal, snapshot, "bars").value == "▁▂▃▄·"
                     && display(.fiveGSignal, snapshot, "bars").value == "▁▂▃··",
                     "LTE and 5G pins preserve their separate reported signal strengths")
        suite.expect(display(.fiveGSignal, snapshot, "value").value == "3/5"
                     && display(.lteBands, snapshot, "bars").value == "b2+b66"
                     && display(.fiveGBands, snapshot, "bars").value == "n41",
                     "signal style and actual LTE/5G bands can be selected independently")
        let expected: [(TMobileGatewayMenuBarReading, String)] = [
            (.lteRSRP, "-92.5"), (.fiveGRSRP, "-97.0"), (.lteSINR, "9.4"), (.fiveGSINR, "6.0"),
            (.lteRSRQ, "-10.2"), (.fiveGRSRQ, "-11.0"), (.lteRSSI, "-64.0"), (.fiveGRSSI, "-68.0"),
        ]
        for (reading, value) in expected {
            suite.expect(display(reading, snapshot, "bars").value == value,
                         "\(reading.title) uses its own radio and measured value")
        }
        for reading in TMobileGatewayMenuBarReading.allCases {
            let missing = display(reading, nil, "bars")
            suite.expect(missing.value == "—" && missing.accessibilityValue.contains("Unavailable"),
                         "\(reading.title) remains visible with an honest offline placeholder")
        }
        suite.expect(display(.fiveGSignal, snapshot, "bars").accessibilityValue.contains("3 of 5 bars")
                     && display(.fiveGRSRP, snapshot, "bars").accessibilityValue.contains("dBm")
                     && display(.fiveGSINR, snapshot, "bars").accessibilityValue.contains("dB"),
                     "cellular menu bar accessibility announces radio, strength and units")
        let zero = try? TMobileGatewaySupport.parse(Data(#"{"signal":{"5g":{"bars":0}}}"#.utf8))
        let full = try? TMobileGatewaySupport.parse(Data(#"{"signal":{"5g":{"bars":5}}}"#.utf8))
        suite.expect(display(.fiveGSignal, zero, "bars").value == "·····"
                     && display(.fiveGSignal, full, "bars").value == "▁▂▃▄▅"
                     && display(.fiveGSignal, zero, "value").value == "0/5",
                     "zero signal remains different from unavailable and a full signal fills all five bars")
    }
}
