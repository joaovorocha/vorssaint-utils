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
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 740),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Advanced radio & tower info"
        window.contentMinSize = NSSize(width: 620, height: 560)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = NSHostingView(rootView: TMobileCellTelemetryView(service: service) { [weak self] in
            self?.window?.performClose(nil)
        })
        self.service = service
        self.window = window
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        service?.disconnect()
        service = nil
        window = nil
    }
}

/// A human-entered, window-scoped session for one read-only telemetry endpoint.
struct TMobileCellTelemetryView: View {
    @ObservedObject var service: TMobileCellTelemetryService
    let close: () -> Void
    @AppStorage(DefaultsKey.tMobileGatewayAddress) private var address = TMobileGatewayService.defaultBaseURL
    @Environment(\.colorScheme) private var colorScheme
    @State private var username = "admin"
    @State private var password = ""
    @State private var trustedNetwork = false
    @State private var requestTask: Task<Void, Never>?

    private var usesHTTP: Bool { TMobileGatewaySupport.privateLANBaseURL(address)?.scheme == "http" }
    private var busy: Bool { service.phase == .connecting || service.phase == .loading }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Advanced radio & tower info").font(.title2.bold())
                Spacer()
                Button("Done") { finish() }.keyboardShortcut(.cancelAction)
            }
            Label(address, systemImage: "network").font(.callout).foregroundStyle(.secondary)
            Text("Read serving-cell details reported by your gateway, including channel, PCI, TAC and bandwidth when available.")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                if busy {
                    ProgressView().controlSize(.small)
                    Text(service.phase == .connecting ? "Signing in…" : "Reading serving cells…")
                }
                if let date = service.fetchedAt { Text("Read \(date.formatted(date: .omitted, time: .standard))") }
                Spacer()
                if service.canRefresh { Button("Refresh readings") { run { await service.refresh() } } }
                if service.phase != .signedOut { Button(busy ? "Cancel & sign out" : "Sign out") { signOut() } }
            }.font(.callout)
            if let message = service.message { Text(message).font(.callout).fixedSize(horizontal: false, vertical: true) }
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if let report = service.report {
                        if let nr = report.fiveG { radio(nr, isFiveG: true) }
                        if let lte = report.lte { radio(lte, isFiveG: false) }
                        Text("Ratings are approximate placement guidance. Green means good or excellent, yellow means fair, and red means poor. RSSI and identifiers have no standalone quality rating. Supported bands describe capability; they do not identify connected or neighboring cells.")
                            .font(.caption).foregroundStyle(.secondary)
                    } else if !busy && !service.canRefresh { signIn }
                    GroupBox("Local tower records") {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Match reported node IDs or ECGI to your saved tower pins. Coordinates come from your manual pins or local files. The gateway does not provide a verified neighboring-tower list.")
                                .font(.callout).foregroundStyle(.secondary)
                            Button("Open history & local towers…") { TMobileLocalTowerWindow.shared.show() }
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(6)
                    }
                }.padding(.trailing, 8)
            }
        }
        .padding(22).frame(minWidth: 620, idealWidth: 720, minHeight: 560, idealHeight: 740)
        .onChange(of: address) { _, _ in signOut(); trustedNetwork = false }
        .onDisappear { signOut() }
    }

    private var signIn: some View {
        GroupBox("Gateway admin sign-in") {
            VStack(alignment: .leading, spacing: 12) {
                Text("Use the gateway admin password, separate from the Wi-Fi password and T-Mobile account. This session reads radio details and ends when this window closes.")
                    .font(.callout).foregroundStyle(.secondary)
                TextField("Username", text: $username).textFieldStyle(.roundedBorder)
                SecureField("Gateway admin password", text: $password).textFieldStyle(.roundedBorder)
                Text("Credentials and these advanced readings are not saved. Refresh is manual.")
                    .font(.caption).foregroundStyle(.secondary)
                if usesHTTP {
                    Text("This gateway uses HTTP. Your administrator credentials travel without encryption on the local network.").font(.callout)
                    Toggle("I’m connected to a trusted private network", isOn: $trustedNetwork)
                }
                Button("Sign in & read radio details") {
                    let enteredPassword = password
                    let enteredUsername = username
                    let enteredAddress = address
                    password = ""
                    run { await service.connect(baseURL: enteredAddress, username: enteredUsername, password: enteredPassword) }
                }.buttonStyle(.borderedProminent)
                    .disabled(password.isEmpty || username.isEmpty || (usesHTTP && !trustedNetwork)
                              || TMobileGatewaySupport.privateLANBaseURL(address) == nil)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(6)
        }
    }

    private func radio(_ report: TMobileCellTelemetryRadio, isFiveG: Bool) -> some View {
        GroupBox(isFiveG ? "5G radio details" : "LTE / 4G radio details") {
            VStack(alignment: .leading, spacing: 9) {
                ForEach(TMobileGatewayRadioPresentation.rows(report.signal, isFiveG: isFiveG)) { row in
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
                TMobileTowerReferenceView(radio: report.signal, isFiveG: isFiveG,
                                         eNodeBID: report.signal.eNodeBID, ecgi: report.ecgi)
            }.font(.callout).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(6)
        }
    }

    private func run(_ operation: @escaping @MainActor () async -> Void) {
        requestTask?.cancel()
        requestTask = Task { await operation() }
    }
    private func signOut() { requestTask?.cancel(); requestTask = nil; password = ""; service.disconnect() }
    private func finish() { signOut(); close() }
}

/// Local file editing remains separate from the temporary administrator report.
@MainActor
private final class TMobileLocalTowerWindow: NSObject, NSWindowDelegate {
    static let shared = TMobileLocalTowerWindow()
    private var window: NSWindow?
    func show() {
        if let window { window.makeKeyAndOrderFront(nil); return }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 780),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "History & local towers"
        window.contentMinSize = NSSize(width: 740, height: 650)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = NSHostingView(rootView: TMobileGatewayHistoryView(onDone: { [weak self] in self?.window?.performClose(nil) }))
        self.window = window
        window.center(); window.makeKeyAndOrderFront(nil)
    }
    func windowWillClose(_ notification: Notification) { window = nil }
}
