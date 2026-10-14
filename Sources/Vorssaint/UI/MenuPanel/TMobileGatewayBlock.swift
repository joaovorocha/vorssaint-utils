// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import SwiftUI

/// View-owned polling stops when the panel closes or this block is hidden.
struct TMobileGatewayBlock: View {
    @Binding var isVisible: Bool
    var editing: Bool
    @StateObject private var service = TMobileGatewayService()
    @ObservedObject private var l10n = L10n.shared
    @AppStorage(DefaultsKey.tMobileGatewayAddress) private var address = TMobileGatewayService.defaultBaseURL
    @State private var configuring = false
    @State private var lastUpdated: Date?

    private var strings: TMobileGatewayStrings { .localized(l10n.language) }

    var body: some View {
        Group {
            if !isVisible {
                PanelHiddenItemRow(title: strings.title, systemImage: "antenna.radiowaves.left.and.right",
                                   isVisible: $isVisible)
            } else {
                VStack(alignment: .leading, spacing: 7) {
                    HStack(spacing: 6) {
                        Label(strings.title, systemImage: "antenna.radiowaves.left.and.right")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                        Button { configuring = true } label: {
                            Image(systemName: "gearshape")
                        }
                        .buttonStyle(.plain)
                        .help(strings.configure)
                        .accessibilityLabel(strings.configure)
                        .popover(isPresented: $configuring) { TMobileGatewayAddressEditor() }
                        if editing { PanelInlineHideButton(isVisible: $isVisible) }
                    }
                    if let snapshot = service.snapshot {
                        readings(snapshot)
                    } else {
                        status
                    }
                }
            }
        }
        .onAppear { updatePolling() }
        .onChange(of: isVisible) { _, _ in updatePolling() }
        .onChange(of: address) { _, _ in updatePolling() }
        .onReceive(service.$snapshot) { snapshot in
            lastUpdated = snapshot == nil ? nil : Date()
        }
        .onDisappear { service.cancel() }
    }

    private func updatePolling() {
        if isVisible && AppFeature.monitorNetwork.isAvailable {
            service.start(baseURL: address)
        } else {
            service.cancel()
        }
    }

    @ViewBuilder private var status: some View {
        if service.phase == .loading {
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text(strings.loading)
            }
            .font(.system(size: 10.5))
            .foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 5) {
                Text(failureMessage)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button(strings.retry) { service.refresh() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
    }

    private var failureMessage: String {
        guard case .failed(let failure) = service.phase else { return strings.unknown }
        switch failure {
        case .invalidAddress: return strings.invalidAddress
        case .authenticationRequired: return strings.authenticationRequired
        case .unavailable: return strings.unavailable
        case .invalidResponse: return strings.invalidResponse
        }
    }

    private func readings(_ snapshot: TMobileGatewaySnapshot) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Text(snapshot.model ?? strings.unknown)
                    .fontWeight(.medium)
                Spacer(minLength: 0)
                Text(registration(snapshot.registration))
                if snapshot.roaming == true { Text(strings.roaming) }
            }
            .font(.system(size: 10.5))
            .foregroundStyle(.secondary)
            if let radio = snapshot.fiveG { radioReadings(radio, title: "5G") }
            if let radio = snapshot.lte { radioReadings(radio, title: "LTE") }
            HStack(spacing: 6) {
                if let firmware = snapshot.firmware {
                    Text("\(strings.firmware): \(firmware)")
                }
                Spacer(minLength: 0)
                if let uptime = snapshot.uptime, uptime < Double(Int.max) {
                    Text("\(strings.uptime): \(MetricFormat.uptime(Int(uptime)))")
                }
            }
            .font(.system(size: 10))
            .foregroundStyle(.tertiary)
            if let lastUpdated {
                HStack(spacing: 4) {
                    Text(strings.lastUpdated)
                    Text(lastUpdated, style: .time)
                    Spacer(minLength: 0)
                    Button { service.refresh() } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.plain)
                        .help(strings.retry)
                        .accessibilityLabel(strings.retry)
                }
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
            }
            Text(strings.usageUnavailable)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func registration(_ value: String?) -> String {
        switch value?.lowercased() {
        case "registered": return strings.registered
        case "not registered", "notregistered", "unregistered", "searching": return strings.notRegistered
        default: return strings.unknown
        }
    }

    private func radioReadings(_ radio: TMobileRadioSignal, title: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(title).fontWeight(.semibold)
                Text(radio.bands.joined(separator: ", ")).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                if let bars = radio.bars {
                    Label("\(bars)/5", systemImage: "chart.bar.fill")
                }
            }
            HStack(spacing: 12) {
                metric("RSRP", radio.rsrp, unit: "dBm")
                metric("SINR", radio.sinr, unit: "dB")
            }
            HStack(spacing: 12) {
                metric("RSRQ", radio.rsrq, unit: "dB")
                metric("RSSI", radio.rssi, unit: "dBm")
            }
            .foregroundStyle(.secondary)
        }
        .font(.system(size: 10.5))
        .monospacedDigit()
    }

    private func metric(_ title: String, _ value: Double?, unit: String) -> some View {
        HStack(spacing: 4) {
            Text(title).foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Text(value.map { "\($0.formatted(.number.precision(.fractionLength(0...1)))) \(unit)" } ?? "—")
        }
        .frame(maxWidth: .infinity)
    }
}

/// An explicit save avoids polling partial addresses while the user types.
struct TMobileGatewayAddressEditor: View {
    @ObservedObject private var l10n = L10n.shared
    @AppStorage(DefaultsKey.tMobileGatewayAddress) private var address = TMobileGatewayService.defaultBaseURL
    @State private var draft = ""
    @Environment(\.dismiss) private var dismiss

    private var strings: TMobileGatewayStrings { .localized(l10n.language) }
    private var valid: Bool { TMobileGatewaySupport.privateLANBaseURL(draft) != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(strings.configure).font(.headline)
            TextField(strings.gatewayAddress, text: $draft)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel(strings.gatewayAddress)
                .onSubmit { save() }
            Text(strings.addressHelp)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if !valid && !draft.isEmpty {
                Text(strings.invalidAddress).font(.caption).foregroundStyle(.secondary)
            }
            Button(strings.save) { save() }
                .disabled(!valid)
        }
        .padding(16)
        .frame(width: 300)
        .onAppear { draft = address }
    }

    private func save() {
        guard let url = TMobileGatewaySupport.privateLANBaseURL(draft) else { return }
        address = url.absoluteString
        dismiss()
    }
}
