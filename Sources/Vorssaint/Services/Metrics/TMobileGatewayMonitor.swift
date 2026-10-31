// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Combine
import Foundation

/// One LAN reader shared by the visible panel, selected menu bar pins and
/// explicit local history recording. Settings previews are never consumers.
@MainActor
final class TMobileGatewayMonitor {
    static let shared = TMobileGatewayMonitor(
        service: TMobileGatewayService(), defaults: .standard,
        historyIsRecording: { TMobileGatewayHistoryStore.shared.isRecording },
        recordSnapshot: { TMobileGatewayHistoryStore.shared.record(snapshot: $0, at: $1) })
    static let snapshotDidUpdate = Notification.Name("TMobileGatewayMonitor.snapshotDidUpdate")

    let service: TMobileGatewayService
    private let defaults: UserDefaults
    private let historyIsRecording: () -> Bool
    private let recordSnapshot: (TMobileGatewaySnapshot, Date) -> Void
    private var panelVisible = false
    private var radioWindowVisible = false
    private var coverageRecording = false
    private var historyOverride: Bool?
    private var isPolling = false
    private var cancellables = Set<AnyCancellable>()

    init(service: TMobileGatewayService, defaults: UserDefaults,
         historyIsRecording: @escaping () -> Bool,
         recordSnapshot: @escaping (TMobileGatewaySnapshot, Date) -> Void) {
        self.service = service
        self.defaults = defaults
        self.historyIsRecording = historyIsRecording
        self.recordSnapshot = recordSnapshot
        service.$snapshot
            .sink { [weak self] snapshot in
                guard let self, let snapshot else { return }
                let date = Date()
                self.recordSnapshot(snapshot, date)
                NotificationCenter.default.post(name: Self.snapshotDidUpdate, object: self,
                                                userInfo: ["snapshot": snapshot, "date": date])
            }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.syncPreferences() }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: .tMobileGatewayHistoryPreferenceChanged)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.historyOverride = nil
                self?.syncPreferences()
            }
            .store(in: &cancellables)
        syncPreferences()
    }

    func setPanelVisible(_ visible: Bool) {
        panelVisible = visible
        syncPreferences()
    }

    func setRadioWindowVisible(_ visible: Bool) {
        radioWindowVisible = visible
        syncPreferences()
    }

    func setHistoryEnabled(_ enabled: Bool) {
        historyOverride = enabled
        syncPreferences()
    }

    func setCoverageRecording(_ enabled: Bool) {
        coverageRecording = enabled
        syncPreferences()
    }

    func syncPreferences() {
        let menuBarEnabled = MenuBarMetric.enabled(in: defaults).contains { $0.tMobileReading != nil }
        let shouldPoll = TMobileGatewayMenuBarSupport.needsPolling(
            networkAvailable: defaults.bool(forKey: AppFeature.monitorNetwork.availabilityKey),
            panelVisible: panelVisible || radioWindowVisible, panelEnabled: defaults.bool(forKey: DefaultsKey.monitorNetTMobile),
            menuBarEnabled: menuBarEnabled, historyEnabled: coverageRecording || (historyOverride ?? historyIsRecording()))
        if shouldPoll {
            // start() is idempotent for the current validated address and
            // retires the previous request before starting a changed origin.
            service.start(baseURL: defaults.string(forKey: DefaultsKey.tMobileGatewayAddress)
                          ?? TMobileGatewayService.defaultBaseURL)
        } else if isPolling {
            service.cancel()
        }
        isPolling = shouldPoll
    }
}
