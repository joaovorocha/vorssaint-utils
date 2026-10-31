// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import AppKit
import SwiftUI

@MainActor
final class TMobileCellTelemetryWindow: NSObject, NSWindowDelegate {
    static let shared = TMobileCellTelemetryWindow()
    private var window: NSWindow?
    private var service: TMobileCellTelemetryService?

    func show() {
        if let window { window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        let service = TMobileCellTelemetryService()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1120, height: 860),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "T-Mobile Coverage"
        window.contentMinSize = NSSize(width: 860, height: 700)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = NSHostingView(rootView: TMobileCellTelemetryView(service: service) { [weak self] in
            self?.window?.performClose(nil)
        })
        self.service = service
        self.window = window
        TMobileGatewayMonitor.shared.setRadioWindowVisible(true)
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        service?.disconnect()
        TMobileGatewayMonitor.shared.setRadioWindowVisible(false)
        service = nil
        window = nil
    }
}

/// A human-entered, window-scoped session for one read-only telemetry endpoint.
struct TMobileCellTelemetryView: View {
    @ObservedObject var service: TMobileCellTelemetryService
    @ObservedObject private var publicService = TMobileGatewayMonitor.shared.service
    let close: () -> Void
    @AppStorage(DefaultsKey.tMobileGatewayAddress) private var address = TMobileGatewayService.defaultBaseURL
    @Environment(\.colorScheme) private var colorScheme
    @StateObject private var credentials = TMobileGatewayCredentialForm()
    @State private var trustedNetwork = false
    @State private var requestTask: Task<Void, Never>?
    @State private var showingAdminSignIn = false

    private var usesHTTP: Bool { TMobileGatewaySupport.privateLANBaseURL(address)?.scheme == "http" }
    private var busy: Bool { service.phase == .connecting || service.phase == .loading }

    var body: some View {
        TMobileCoverageWorkspaceView(close: finish) { radioTab }
        .onAppear { credentials.updateAddress(address) }
        .onChange(of: address) { _, value in signOut(); trustedNetwork = false; credentials.updateAddress(value) }
        .onDisappear { signOut() }
    }

    private var radioTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Public gateway readings").font(.headline)
                Spacer()
                Button("Refresh gateway") { publicService.refresh() }.disabled(publicService.phase == .loading)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if let snapshot = publicService.snapshot {
                        VStack(alignment: .leading, spacing: 6) {
                            if let model = snapshot.model { LabeledContent("Model", value: model) }
                            if let firmware = snapshot.firmware { LabeledContent("Firmware", value: firmware) }
                            if let uptime = snapshot.uptime, uptime < Double(Int.max) {
                                LabeledContent("Uptime", value: MetricFormat.uptime(Int(uptime)))
                            }
                            if let registration = snapshot.registration { LabeledContent("Registration", value: registration) }
                            if let roaming = snapshot.roaming { LabeledContent("Roaming", value: roaming ? "Yes" : "No") }
                            if let apn = snapshot.apn { LabeledContent("APN", value: apn) }
                        }.font(.callout).textSelection(.enabled)
                    }
                    ForEach(TMobileGatewayRadioPresentation.sections(publicService.snapshot)) { section in
                        radio(.init(signal: section.radio, ecgi: section.radio.ecgi,
                                    supportedBands: section.radio.supportedBands ?? []), isFiveG: section.id == "fiveG")
                    }
                    if publicService.snapshot == nil {
                        Text(publicService.phase == .loading ? "Loading gateway readings…" : "Gateway readings are currently unavailable. Check the configured address and enable the T-Mobile gateway in Monitor settings.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    Divider()
                    Text("Administrator radio details").font(.headline)
                    Text("Read additional channel, PCI, TAC, CQI and bandwidth fields when your firmware provides them.")
                        .font(.callout).foregroundStyle(.secondary)
                    adminStatus
                    if let report = service.report {
                        if let nr = report.fiveG { radio(nr, isFiveG: true) }
                        if let lte = report.lte { radio(lte, isFiveG: false) }
                    } else if !busy && !service.canRefresh {
                        DisclosureGroup("Sign in for additional radio readings", isExpanded: $showingAdminSignIn) { signIn }
                    }
                    Text("Ratings are approximate placement guidance. Green means good or excellent, yellow means fair, and red means poor. RSSI and identifiers have no standalone quality rating. Supported bands describe capability; they do not identify connected or neighboring cells.")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(12)
            }
        }.padding(.top, 12)
    }

    private var adminStatus: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                if busy {
                    ProgressView().controlSize(.small)
                    Text(service.phase == .connecting ? "Signing in…" : "Reading serving cells…")
                }
                if let date = service.fetchedAt { Text("Read \(date.formatted(date: .omitted, time: .standard))") }
                Spacer()
                if service.canRefresh { Button("Refresh readings") { run { await service.refresh() } } }
                if service.canRefresh {
                    Button("Forget saved password") { credentials.forget() }.disabled(!credentials.scopeIsValid)
                }
                if service.phase != .signedOut { Button(busy ? "Cancel & sign out" : "Sign out") { signOut() } }
            }.font(.callout)
            if let message = service.message { Text(message).font(.callout).fixedSize(horizontal: false, vertical: true) }
            if let message = credentials.message { Text(message).font(.callout).fixedSize(horizontal: false, vertical: true) }
        }
    }

    private var signIn: some View {
        GroupBox("Gateway admin sign-in") {
            VStack(alignment: .leading, spacing: 12) {
                Text("Use the gateway admin password, separate from the Wi-Fi password and T-Mobile account. This session reads radio details and ends when this window closes.")
                    .font(.callout).foregroundStyle(.secondary)
                TMobileGatewayCredentialFields(form: credentials)
                Text("Advanced readings are not saved. Refresh is manual.")
                    .font(.caption).foregroundStyle(.secondary)
                if usesHTTP {
                    Text("This gateway uses HTTP. Your administrator credentials travel without encryption on the local network.").font(.callout)
                    Toggle("I’m connected to a trusted private network", isOn: $trustedNetwork)
                }
                Button("Sign in & read radio details") {
                    credentials.updateAddress(address)
                    guard let input = credentials.prepareSignIn() else { return }
                    run {
                        await service.connect(baseURL: input.address, username: input.username, password: input.password)
                        credentials.completeSignIn(input, succeeded: service.phase == .ready)
                    }
                }.buttonStyle(.borderedProminent)
                    .disabled(credentials.password.isEmpty || credentials.username.isEmpty || (usesHTTP && !trustedNetwork)
                              || TMobileGatewaySupport.privateLANBaseURL(address) == nil)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(6).disabled(busy)
        }
    }

    private func radio(_ report: TMobileCellTelemetryRadio, isFiveG: Bool) -> some View {
        GroupBox(isFiveG ? "5G radio details" : "LTE / 4G radio details") {
            VStack(alignment: .leading, spacing: 9) {
                ForEach(TMobileGatewayRadioPresentation.rows(report.signal, isFiveG: isFiveG)) { row in
                    if row.id == .bands || row.id == .supportedBands {
                        TMobileBandDetailRow(row: row,
                                            bands: row.id == .bands ? report.signal.bands : report.signal.supportedBands ?? [],
                                            isFiveG: isFiveG)
                    } else {
                        HStack(alignment: .firstTextBaseline) {
                            Text(row.label).foregroundStyle(.secondary)
                            Spacer(minLength: 16)
                            VStack(alignment: .trailing, spacing: 2) {
                                Text(row.value).monospacedDigit()
                                if let quality = row.qualityLabel { Text(quality).font(.caption) }
                            }.foregroundStyle(row.quality.presentationColor(for: colorScheme))
                        }
                        .accessibilityElement(children: .ignore).accessibilityLabel(row.accessibilityValue)
                    }
                }
                TMobileTowerReferenceView(radio: report.signal, isFiveG: isFiveG,
                                         eNodeBID: report.signal.eNodeBID, ecgi: report.ecgi)
            }.font(.callout).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(6)
        }
    }

    private func run(_ operation: @escaping @MainActor () async -> Void) {
        requestTask?.cancel()
        requestTask = Task { await operation() }
    }
    private func signOut() { requestTask?.cancel(); requestTask = nil; credentials.clearVolatile(); service.disconnect() }
    private func finish() { signOut(); close() }
}
