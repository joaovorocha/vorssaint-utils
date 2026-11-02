// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

#if SHADOW_UTILITIES
import SwiftUI

/// Fork-only router switch for the Features hub: turning it on opens the
/// setup sheet (model, then how this Mac reaches the router).
struct RouterFeatureCard: View {
    @AppStorage(DefaultsKey.monitorNetTMobile) private var enabled = false
    @AppStorage(RouterSetup.modelKey) private var model = RouterSetup.Model.g4ar.rawValue
    // The real link state, so the summary never disagrees with what the app does.
    @AppStorage(ShadowServerConnection.Keys.enabled) private var serverEnabled = false
    @ObservedObject private var features = FeatureRuntime.shared
    @State private var settingUp = false

    private var available: Bool { AppFeature.monitorNetwork.isAvailable }

    var body: some View {
        SettingsCard(title: "Router") {
            Toggle(isOn: Binding(get: { enabled && available }, set: setEnabled)) {
                VStack(alignment: .leading, spacing: 2) {
                    Label("T-Mobile gateway", systemImage: "antenna.radiowaves.left.and.right")
                    Text(enabled && available ? summary : "Signal, bands and coverage from your home internet router.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .disabled(!available)
            if !available {
                Text("Turn on Network in the Monitor section first.")
                    .font(.caption).foregroundStyle(.secondary)
            } else if enabled {
                Button("Router setup…") { settingUp = true }
            }
        }
        .sheet(isPresented: $settingUp) { RouterSetupSheet() }
    }

    private var summary: String {
        let model = RouterSetup.Model(rawValue: model) ?? .g4ar
        let connection: RouterSetup.Connection = serverEnabled ? .automatic : .direct
        return "\(model.title) · \(connection.title)"
    }

    /// Only shows or hides the gateway; the Shadow link also feeds coverage recording, so it is left alone.
    private func setEnabled(_ on: Bool) {
        enabled = on
        if on { settingUp = true }
    }
}

enum RouterSetup {
    static let modelKey = "routerSetup.model"

    enum Model: String, CaseIterable, Identifiable {
        case g4ar, otherTMobile
        var id: String { rawValue }
        var title: String {
            switch self {
            case .g4ar: return "T-Mobile TMO-G4AR"
            case .otherTMobile: return "Other T-Mobile 5G gateway"
            }
        }
    }

    enum Connection: String, CaseIterable, Identifiable {
        case automatic, direct
        var id: String { rawValue }
        var title: String {
            switch self {
            case .automatic: return "Direct at home, Shadow server elsewhere"
            case .direct: return "Direct only"
            }
        }
    }
}

struct RouterSetupSheet: View {
    @AppStorage(RouterSetup.modelKey) private var model = RouterSetup.Model.g4ar.rawValue
    @AppStorage(ShadowServerConnection.Keys.enabled) private var serverEnabled = false
    @ObservedObject private var shadow = ShadowServerConnection.shared
    // Local until the link is actually on: picking Automatic shows the server fields before they are filled in.
    @State private var connection = RouterSetup.Connection.direct.rawValue
    @AppStorage(DefaultsKey.tMobileGatewayAddress) private var address = TMobileGatewayService.defaultBaseURL
    @State private var editingAddress = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Router setup").font(.title2.bold())
            Picker("Model", selection: $model) {
                ForEach(RouterSetup.Model.allCases) { Text($0.title).tag($0.rawValue) }
            }
            if model == RouterSetup.Model.otherTMobile.rawValue {
                Text("Shadow Utilities reads the gateway’s local status page. Only the TMO-G4AR has been tested; other models may show no readings.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Picker("Connection", selection: $connection) {
                ForEach(RouterSetup.Connection.allCases) { Text($0.title).tag($0.rawValue) }
            }
            .pickerStyle(.radioGroup)
            .onChange(of: connection) { _, value in
                if value == RouterSetup.Connection.direct.rawValue {
                    shadow.disconnect()
                } else if shadow.canConnect, !shadow.isActive {
                    shadow.connect()
                }
            }
            HStack {
                Text("Gateway address: \(address)").font(.callout)
                Spacer()
                Button("Change…") { editingAddress = true }
                    .popover(isPresented: $editingAddress) { TMobileGatewayAddressEditor() }
            }
            if connection == RouterSetup.Connection.automatic.rawValue {
                Divider()
                Text("Tailscale").font(.headline)
                RouterTailscaleStatus()
                Divider()
                Text("Shadow server").font(.headline)
                ShadowServerControls()
            }
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460)
        .onAppear {
            connection = (serverEnabled ? RouterSetup.Connection.automatic : .direct).rawValue
            shadow.resume()
        }
    }
}

/// The tailnet the Shadow server is reached over: this Mac's state and the server peer.
struct RouterTailscaleStatus: View {
    @StateObject private var tailscale = TailscaleStatusService()
    @ObservedObject private var shadow = ShadowServerConnection.shared
    @AppStorage(DefaultsKey.monitorNetTailscale) private var showInPanel = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !TailscaleStatusService.isInstalled {
                Text("Tailscale is not installed. This Mac reaches the Shadow server over your tailnet, so install Tailscale and sign in first.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else if let status = tailscale.status {
                Label(thisMac(status), systemImage: status.state == .running ? "checkmark.circle" : "exclamationmark.circle")
                Label(server(status), systemImage: "server.rack")
            } else if tailscale.failed {
                Label("Tailscale status unavailable. Open Tailscale and check that it is running.", systemImage: "exclamationmark.circle")
            } else {
                Text("Reading Tailscale…").foregroundStyle(.secondary)
            }
            HStack {
                Toggle("Show Tailscale in the panel", isOn: $showInPanel)
                Spacer()
                if TailscaleStatusService.isInstalled {
                    Button("Open Tailscale") {
                        NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications/Tailscale.app"))
                    }
                }
            }
        }
        .font(.callout)
        .onAppear { tailscale.start() }
        .onDisappear { tailscale.stop() }
    }

    private func thisMac(_ status: TailscaleStatus) -> String {
        guard status.state == .running else { return "This Mac is not connected to the tailnet" }
        return "This Mac: " + [status.name, status.address].compactMap { $0 }.joined(separator: " · ")
    }

    private func server(_ status: TailscaleStatus) -> String {
        let host = shadow.host.trimmingCharacters(in: .whitespaces).lowercased()
        guard !host.isEmpty else { return "Shadow server: enter its tailnet address below" }
        guard let peer = status.peers.first(where: { $0.address == host || $0.name.lowercased().hasPrefix(host) }) else {
            return "Shadow server \(host) is not in this tailnet"
        }
        return "Shadow server \(peer.name): " + (peer.online ? (peer.relay.map { "online, relayed via \($0)" } ?? "online, direct") : "offline")
    }
}

/// Shadow server link fields, shared by the router setup sheet and the Coverage window.
struct ShadowServerControls: View {
    @ObservedObject private var shadow = ShadowServerConnection.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("The Shadow server talks to the T-Mobile gateway and publishes tower estimates. This Mac only reads them over your tailnet.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            TextField("Server tailnet address (100.x.y.z or name.ts.net)", text: $shadow.host)
            TextField("Port", text: $shadow.port).frame(width: 120)
            TextField("MQTT username", text: $shadow.username)
            SecureField(shadow.hasSavedPassword ? "Password saved in Keychain" : "MQTT password", text: $shadow.password)
            HStack {
                if shadow.isActive {
                    Button("Disconnect") { shadow.disconnect() }
                } else {
                    Button("Connect") { shadow.connect() }.disabled(!shadow.canConnect)
                }
                if shadow.hasSavedPassword { Button("Forget password") { shadow.forgetPassword() } }
                Spacer()
                Text("\(shadow.towers.count) server towers").foregroundStyle(.secondary)
            }
            Label(shadow.statusText, systemImage: shadow.state == .connected ? "network" : "network.slash").font(.caption)
        }.textFieldStyle(.roundedBorder)
    }
}
#endif
