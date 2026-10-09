// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import SwiftUI

/// Shares a single reader with explicitly pinned metrics and local history.
struct TMobileGatewayBlock: View {
    @Binding var isVisible: Bool
    var editing: Bool
    @ObservedObject private var service = TMobileGatewayMonitor.shared.service
    @ObservedObject private var l10n = L10n.shared
    @AppStorage(DefaultsKey.tMobileGatewayAddress) private var address = TMobileGatewayService.defaultBaseURL
    @State private var configuring = false
    @State private var lastUpdated: Date?
    @State private var showingHistory = false
    @State private var showingTips = false

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
                    HStack {
                        Button("Signal guide & tips") { showingTips = true }
                        Spacer(minLength: 0)
                        Button("History & towers") { showingHistory = true }
                    }.buttonStyle(.bordered).controlSize(.small)
                }
            }
        }
        .onAppear { updatePolling() }
        .onChange(of: isVisible) { _, _ in updatePolling() }
        .onChange(of: address) { _, _ in updatePolling() }
        .onReceive(service.$snapshot) { snapshot in
            lastUpdated = snapshot == nil ? nil : Date()
        }
        .onDisappear { TMobileGatewayMonitor.shared.setPanelVisible(false) }
        .sheet(isPresented: $showingHistory) { TMobileGatewayHistoryView() }
        .sheet(isPresented: $showingTips) { TMobileGatewayTipsView(snapshot: service.snapshot) }
    }

    private func updatePolling() {
        TMobileGatewayMonitor.shared.setPanelVisible(isVisible)
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
                    TMobileSignalBars(bars: bars, radio: title)
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
            DisclosureGroup("Radio details") {
                VStack(alignment: .leading, spacing: 3) {
                    detail("Cell ID", radio.cellID.map(String.init))
                    detail("Antenna", radio.antenna)
                    detail("Bandwidth", radio.bandwidthMHz.map { "\($0.formatted()) MHz" })
                    detail("Channel", radio.channel.map(String.init))
                    detail("PCI", radio.physicalCellID.map(String.init))
                    detail("TAC", radio.trackingAreaCode.map(String.init))
                    detail("CQI", radio.cqi.map(String.init))
                    detail("gNB ID", radio.gNodeBID.map(String.init))
                    Text("Not reported fields remain unavailable. Cell IDs do not provide tower coordinates.")
                        .font(.system(size: 9)).foregroundStyle(.tertiary)
                }.textSelection(.enabled)
            }
        }
        .font(.system(size: 10.5))
        .monospacedDigit()
    }

    private func detail(_ name: String, _ value: String?) -> some View {
        HStack { Text(name).foregroundStyle(.secondary); Spacer(minLength: 0); Text(value ?? "Not reported") }
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
    @State private var history = false
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
            Divider()
            Text("Pin LTE / 5G signal, bands and individual numbers in Settings → Monitor → In the menu bar.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Button("Local history & tower map…") { history = true }
        }
        .padding(16)
        .frame(width: 300)
        .onAppear { draft = address }
        .sheet(isPresented: $history) { TMobileGatewayHistoryView() }
    }

    private func save() {
        guard let url = TMobileGatewaySupport.privateLANBaseURL(draft) else { return }
        address = url.absoluteString
        dismiss()
    }
}

private struct TMobileSignalBars: View {
    let bars: Int
    let radio: String
    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(1...5, id: \.self) { index in
                RoundedRectangle(cornerRadius: 1).fill(index <= bars ? Color.primary : Color.secondary.opacity(0.25))
                    .frame(width: 3, height: CGFloat(index * 2 + 3))
            }
            Text("\(bars)/5").padding(.leading, 3)
        }.accessibilityElement(children: .ignore).accessibilityLabel("\(radio) signal, \(bars) of 5 bars")
    }
}

private struct TMobileGatewayTipsView: View {
    let snapshot: TMobileGatewaySnapshot?
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Text("Cellular signal guide").font(.title2.bold()); Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.cancelAction) }
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Bars are reported by your gateway. The ratings below are approximate placement guidance, not T-Mobile ratings or a speed prediction.")
                        .font(.callout).foregroundStyle(.secondary)
                    ForEach(TMobileSignalMetric.allCases, id: \.self) { metric in
                        VStack(alignment: .leading, spacing: 5) {
                            Text("\(metric.label) · \(metric.unit)").font(.headline)
                            Text(metric.explanation)
                            HStack(spacing: 20) {
                                guideReading("LTE", radio: snapshot?.lte, metric: metric)
                                guideReading("5G", radio: snapshot?.fiveG, metric: metric)
                            }.font(.callout).monospacedDigit()
                        }
                    }
                    if let snapshot {
                        Divider()
                        Text("Tips for these readings").font(.headline)
                        ForEach(Array(TMobileGatewayDiagnostics.tips(for: snapshot).enumerated()), id: \.offset) { index, tip in Text("\(index + 1). \(tip)") }
                        ForEach(Array(Set((snapshot.lte?.bands ?? []) + (snapshot.fiveG?.bands ?? []))).sorted(), id: \.self) { band in
                            if let description = TMobileGatewayDiagnostics.bandDescription(band) { Text("\(band): \(description)") }
                        }
                        if let apn = snapshot.apn { Text("Reported APN: \(apn)").font(.caption) }
                    }
                    Divider()
                    Text("Band choices in the menu bar select what you see. The gateway chooses the connected band; this app does not change it. Monthly account usage is not provided by this local status endpoint.")
                        .font(.callout).foregroundStyle(.secondary)
                    Link("T-Mobile network and band information", destination: URL(string: "https://www.t-mobile.com/support/coverage/t-mobile-network")!)
                    Link("T-Mobile gateway placement help", destination: URL(string: "https://www.t-mobile.com/support/home-internet/t-mobile-gateway/network-speed")!)
                    Link("T-Mobile coverage map", destination: URL(string: "https://www.t-mobile.com/coverage/coverage-map")!)
                }.textSelection(.enabled).padding(.trailing, 8)
            }
        }.padding(20).frame(width: 590, height: 660)
    }
    private func guideReading(_ label: String, radio: TMobileRadioSignal?, metric: TMobileSignalMetric) -> some View {
        let value: Double? = {
            switch metric { case .rsrp: return radio?.rsrp; case .rsrq: return radio?.rsrq; case .rssi: return radio?.rssi; case .sinr: return radio?.sinr }
        }()
        let quality = TMobileGatewayDiagnostics.quality(for: value, metric: metric)
        return Text("\(label): \(value.map { "\($0.formatted()) \(metric.unit)" } ?? "Not reported")\(quality == .unknown ? "" : " · " + quality.label)")
    }
}
