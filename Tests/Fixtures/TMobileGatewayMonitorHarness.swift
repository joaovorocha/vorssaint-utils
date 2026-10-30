// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Combine
import Foundation

// Only unrelated app wiring is doubled. The coordinator, transport, parsing,
// retirement barrier and demand formatter compile from production sources.
enum DefaultsKey {
    static let monitorNetTMobile = "panel"
    static let tMobileGatewayAddress = "address"
    static let tMobileLTEMenuBarSignalStyle = "lteStyle"
    static let tMobile5GMenuBarSignalStyle = "5gStyle"
}
enum AppFeature {
    case monitorNetwork
    var availabilityKey: String { "networkAvailable" }
}
struct MenuBarMetric {
    let tMobileReading: TMobileGatewayMenuBarReading?
    static func enabled(in defaults: UserDefaults) -> [MenuBarMetric] {
        defaults.bool(forKey: "menu") ? [MenuBarMetric(tMobileReading: .fiveGSignal)] : []
    }
}
@MainActor final class TMobileGatewayHistoryStore {
    static let shared = TMobileGatewayHistoryStore()
    var isRecording = false
    func record(snapshot: TMobileGatewaySnapshot, at date: Date) {}
}
extension Notification.Name {
    static let tMobileGatewayHistoryPreferenceChanged = Notification.Name("test.historyPreferenceChanged")
}

@main struct TMobileGatewayMonitorHarness {
    static let relayed = TMobileGatewaySnapshot(model: nil, firmware: nil, uptime: nil, registration: "registered",
        roaming: false, lte: nil, fiveG: TMobileRadioSignal(bars: 2, bands: ["n41"], rsrp: -112, rsrq: nil, rssi: nil, sinr: 4))

    @MainActor static func main() {
        let domain = "com.vorssaint.tests.tmobile-monitor.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        defaults.set(true, forKey: "networkAvailable")
        defaults.set("http://192.168.12.1", forKey: "address")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MonitorProtocol.self]
        let service = TMobileGatewayService(configuration: configuration)
        var recordings = 0
        let monitor = TMobileGatewayMonitor(service: service, defaults: defaults,
            historyIsRecording: { false }, recordSnapshot: { _, _ in recordings += 1 })
        monitor.syncPreferences()
        settle()
        check(MonitorProtocol.count == 0, "default off performs no gateway request")
        monitor.setPanelVisible(true)
        settle()
        check(MonitorProtocol.count == 0, "visible but disabled panel performs no request")
        defaults.set(true, forKey: "panel")
        monitor.syncPreferences()
        wait { service.phase == .ready }
        check(MonitorProtocol.count == 1 && recordings == 1, "enabled visible panel shares one successful snapshot")
        let direct = service.snapshot
        service.useRelayed(relayed, at: Date())
        check(service.snapshot == direct && !service.isRelayed, "a relayed reading never replaces a live LAN reading")
        monitor.setRadioWindowVisible(true)
        monitor.setPanelVisible(false)
        settle()
        check(service.phase == .ready && MonitorProtocol.count == 1,
              "standalone radio window retains the same reader when the dropdown closes")
        monitor.setRadioWindowVisible(false)
        check(service.phase == .idle && service.snapshot == nil,
              "closing the last radio window clears live readings")
        monitor.setPanelVisible(true)
        wait { service.phase == .ready }
        check(MonitorProtocol.count == 2, "reopening the panel resumes one shared reader")
        defaults.set(true, forKey: "menu")
        monitor.syncPreferences()
        monitor.setHistoryEnabled(true)
        monitor.syncPreferences()
        settle()
        check(MonitorProtocol.count == 2, "adding menu bar and history consumers does not start duplicate requests")
        monitor.setPanelVisible(false)
        check(service.phase == .ready, "closing panel retains demand from menu bar and history")
        defaults.set(false, forKey: "menu")
        monitor.syncPreferences()
        check(service.phase == .ready, "history recording retains the shared reader")
        monitor.setHistoryEnabled(false)
        check(service.phase == .idle && service.snapshot == nil, "last consumer stopping clears live readings")
        // Explicit Coverage demand is independent of the dropdown's display
        // preference, but still obeys the global network-feature boundary.
        defaults.set(false, forKey: "panel")
        monitor.setCoverageRecording(true)
        wait { service.phase == .ready }
        check(MonitorProtocol.count == 3 && recordings == 3,
              "coverage recording alone starts one public reader with panel, window, menu and history off")
        monitor.setCoverageRecording(true)
        monitor.syncPreferences()
        settle()
        check(MonitorProtocol.count == 3 && service.phase == .ready,
              "repeated coverage demand does not start duplicate requests")
        defaults.set(true, forKey: "panel")
        monitor.setRadioWindowVisible(true)
        monitor.setPanelVisible(true)
        monitor.setHistoryEnabled(true)
        settle()
        check(MonitorProtocol.count == 3,
              "window, panel and history join coverage through the same reader")
        monitor.setRadioWindowVisible(false)
        monitor.setPanelVisible(false)
        monitor.setHistoryEnabled(false)
        check(service.phase == .ready && MonitorProtocol.count == 3,
              "coverage retains the shared reader after every other consumer closes")
        monitor.setCoverageRecording(false)
        check(service.phase == .idle && service.snapshot == nil,
              "stopping the last coverage consumer clears live readings")
        defaults.set(false, forKey: "networkAvailable")
        monitor.setCoverageRecording(true)
        settle()
        check(service.phase == .idle && MonitorProtocol.count == 3,
              "coverage demand cannot bypass a disabled network feature")
        monitor.setCoverageRecording(false)
        defaults.set(true, forKey: "networkAvailable")
        monitor.syncPreferences()
        settle()
        check(service.phase == .idle && MonitorProtocol.count == 3,
              "restoring the network feature with coverage off creates no request")
        defaults.set(true, forKey: "menu")
        monitor.syncPreferences()
        wait { service.phase == .ready }
        check(MonitorProtocol.count == 4, "re-enabling a pin resumes the same reader")
        monitor.setRadioWindowVisible(true)
        defaults.set(false, forKey: "networkAvailable")
        monitor.syncPreferences()
        check(service.phase == .idle && service.snapshot == nil, "removing network feature cancels all consumers")
        monitor.setRadioWindowVisible(false)
        defaults.set(true, forKey: "networkAvailable")
        defaults.set("http://8.8.8.8", forKey: "address")
        monitor.syncPreferences()
        settle()
        check(service.phase == .failed(.invalidAddress) && MonitorProtocol.count == 4,
              "invalid origins do not open another request")
        defaults.set(false, forKey: "menu")
        monitor.syncPreferences()
        let failing = URLSessionConfiguration.ephemeral
        failing.protocolClasses = [UnreachableProtocol.self]
        let offLAN = TMobileGatewayService(configuration: failing)
        offLAN.useRelayed(relayed, at: Date())
        check(offLAN.snapshot == nil, "a stopped reader ignores relayed readings")
        offLAN.start(baseURL: "http://192.168.12.1")
        wait { if case .failed = offLAN.phase { return true } else { return false } }
        offLAN.useRelayed(relayed, at: Date())
        check(offLAN.snapshot == relayed && offLAN.isRelayed && offLAN.phase == .ready,
              "a relayed reading fills in while the LAN gateway is unreachable")
        offLAN.refresh()
        wait { UnreachableProtocol.count >= 2 && offLAN.phase != .loading }
        check(offLAN.snapshot == relayed && offLAN.isRelayed, "a failed LAN poll keeps a fresh relayed reading")
        offLAN.cancel()
        check(offLAN.snapshot == nil && !offLAN.isRelayed, "stopping the reader clears the relayed reading")
        print("PASS: 26 T-Mobile shared-reader lifecycle checks; every request intercepted locally")
    }

    private static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() { fatalError("FAIL: \(message)") }
    }
    private static func settle() { RunLoop.main.run(until: Date().addingTimeInterval(0.03)) }
    private static func wait(_ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(2)
        while !condition() && Date() < deadline { settle() }
        check(condition(), "asynchronous gateway request completed")
    }
}

private final class MonitorProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var captured = 0
    static var count: Int { lock.withLock { captured } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.withLock { Self.captured += 1 }
        let reply = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: reply, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"signal":{"5g":{"bars":3,"bands":["n41"],"rsrp":-97}}}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private final class UnreachableProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var captured = 0
    static var count: Int { lock.withLock { captured } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.withLock { Self.captured += 1 }
        client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
    }
    override func stopLoading() {}
}
