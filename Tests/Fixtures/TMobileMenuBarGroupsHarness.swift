// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Foundation

enum MenuBarMetric: String, CaseIterable {
    // PRODUCTION_METRIC_CASES
    func title(_ strings: Strings) -> String { rawValue }
}
struct Strings {
    let monitorShowCPU = "CPU"
    let monitorShowGPU = "GPU"
    let batteryLabel = "Battery"
}
enum DefaultsKey { static let menuBarCombineTemperatures = "combine" }
enum ReviewDefaults { static var current: UserDefaults! }
struct MenuBarMetricAppearance {
    var allowsCombinedTemperatures: Bool
    static var current = MenuBarMetricAppearance(allowsCombinedTemperatures: true)
}
enum Groups {
    struct MetricStatusGroup {
        let id: String
        let metrics: [MenuBarMetric]
        let focusMetric: MenuBarMetric
        let title: String
    }
    // PRODUCTION_GROUPS_METHOD
}

@main struct TMobileMenuBarGroupsHarness {
    static func main() {
        let domain = "com.vorssaint.tests.tmobile-groups.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: domain)!
        ReviewDefaults.current = defaults
        defer { defaults.removePersistentDomain(forName: domain) }
        let radioMetrics = MenuBarMetric.allCases.filter { $0.rawValue.hasPrefix("tMobile") }
        precondition(radioMetrics.count == 12, "All legacy LTE and 5G aliases must reach the grouping contract")
        for combines in [false, true] {
            defaults.set(combines, forKey: DefaultsKey.menuBarCombineTemperatures)
            let groups = Groups.metricStatusGroups(for: radioMetrics, strings: Strings())
            precondition(groups.count == 1 && groups[0].id == "tMobile5G"
                         && groups[0].metrics == [.tMobile5G] && groups[0].focusMetric == .tMobile5G
                         && !groups[0].title.isEmpty,
                         "Every legacy radio pin collapses into one clickable connected-radio item")
        }
        defaults.set(true, forKey: DefaultsKey.menuBarCombineTemperatures)
        let mixed = Groups.metricStatusGroups(for: [.cpu, .cpuTemperature] + radioMetrics, strings: Strings())
        precondition(mixed.count == 2 && mixed.first?.metrics == [.cpu, .cpuTemperature]
                     && mixed.last?.metrics == [.tMobile5G],
                     "CPU temperature grouping remains separate from the single cellular connection")
        print("PASS: all 12 legacy radio aliases collapse into one independently clickable connection")
    }
}
