// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import AppKit

/// Keep administration alive when the menu bar popover closes or a link opens.
@MainActor
final class TMobileWiFiSettingsWindow: NSObject, NSWindowDelegate {
    static let shared = TMobileWiFiSettingsWindow()
    private var window: NSWindow?
    private var service: TMobileWiFiService?
    var hasPendingWrite: Bool { service?.phase == .applying || service?.phase == .verifying }

    func show() {
        if let window { window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        let session = TMobileWiFiService()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 780),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Wi-Fi & router settings"
        window.contentMinSize = NSSize(width: 740, height: 650)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = NSHostingView(rootView: TMobileWiFiSettingsView(service: session) { [weak self] in
            self?.window?.performClose(nil)
        })
        self.service = session
        self.window = window
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard let service else { return true }
        return service.phase != .applying && service.phase != .verifying
    }

    func windowWillClose(_ notification: Notification) {
        service?.disconnect()
        service = nil
        window = nil
    }
}

/// A window-scoped admin session, separate from the public signal reader.
struct TMobileWiFiSettingsView: View {
    let close: () -> Void
    @AppStorage(DefaultsKey.tMobileGatewayAddress) private var address = TMobileGatewayService.defaultBaseURL
    @ObservedObject var service: TMobileWiFiService
    @State private var username = "admin"
    @State private var password = ""
    @State private var trustedNetwork = false
    @State private var edits: [Int: TMobileWiFiEdit] = [:]
    @State private var editorGeneration = UUID()
    @State private var requestTask: Task<Void, Never>?
    @State private var confirmingApply = false
    @State private var confirmingReload = false
    @State private var interruptedOrigin: String?

    init(service: TMobileWiFiService, close: @escaping () -> Void) {
        self.service = service
        self.close = close
    }

    private var usesHTTP: Bool { TMobileGatewaySupport.privateLANBaseURL(address)?.scheme == "http" }
    private var busy: Bool {
        [.connecting, .loading, .applying, .verifying].contains(service.phase)
    }
    private var writing: Bool { [.applying, .verifying].contains(service.phase) }
    private var editingAllowed: Bool { [.ready, .verified].contains(service.phase) && service.review == nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Wi-Fi & router settings").font(.title2.bold())
                Spacer()
                Button("Done") { finish() }.keyboardShortcut(.cancelAction).disabled(writing)
            }
            HStack {
                Label(address, systemImage: "network").textSelection(.enabled)
                Spacer()
                if service.configuration != nil {
                    Button("Sign out") { clearDrafts(); service.disconnect() }.disabled(busy)
                }
            }.font(.callout).foregroundStyle(.secondary)
            if busy { HStack { ProgressView().controlSize(.small); Text(phaseLabel) }.accessibilityElement(children: .combine) }
            if let message = service.message {
                Text(message).font(.callout).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }
            if let interruptedOrigin {
                Text("The previous gateway (\(interruptedOrigin)) may have received an unconfirmed change. Check that gateway’s settings before sending it another change.")
                    .font(.callout).fixedSize(horizontal: false, vertical: true)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if let configuration = service.configuration {
                        if let review = service.review { reviewView(review) }
                        else {
                            if service.phase == .outcomeUnknown {
                                GroupBox("Check the last change") {
                                    VStack(alignment: .leading, spacing: 10) {
                                        Text("The connection ended before the result could be confirmed. Reconnect to the gateway, then check its current settings before sending another change.")
                                        Button("Check pending change") { run { await service.verifyPending() } }.disabled(busy)
                                    }.frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                            HStack {
                                Text("Wi-Fi networks").font(.headline)
                                Spacer()
                                Button("Reload settings") {
                                    if edits.isEmpty { reload() } else { confirmingReload = true }
                                }.disabled(busy || service.phase == .outcomeUnknown)
                            }
                            Text("Edit an existing network, then review the changes. A new name or password can disconnect devices until they rejoin.")
                                .font(.callout).foregroundStyle(.secondary)
                            ForEach(configuration.ssids) { ssid in
                                TMobileWiFiNetworkEditor(ssid: ssid) { edit in
                                    if let edit { edits[ssid.id] = edit } else { edits.removeValue(forKey: ssid.id) }
                                }
                            }.id(editorGeneration).disabled(!editingAllowed)
                            if configuration.ssids.isEmpty { Text("The gateway did not report any Wi-Fi networks.").foregroundStyle(.secondary) }
                            HStack {
                                Button("Review changes…") {
                                    let pending = Array(edits.values).sorted { $0.ssidID < $1.ssidID }
                                    run { await service.prepare(pending); if service.review != nil { clearDrafts() } }
                                }.buttonStyle(.borderedProminent).disabled(edits.isEmpty || !editingAllowed)
                                if !edits.isEmpty { Button("Discard edits") { clearDrafts() }.disabled(busy) }
                                Spacer()
                                if service.canRestore {
                                    Button("Review restore of previous settings…") { run { await service.prepareRestore() } }
                                        .disabled(busy || service.phase == .outcomeUnknown)
                                }
                            }
                            radioSettings(configuration)
                        }
                    } else { signIn }
                    otherSettings
                }.padding(.trailing, 8)
            }
        }
        .padding(22).frame(minWidth: 740, idealWidth: 800, minHeight: 650, idealHeight: 780)
        .interactiveDismissDisabled(writing)
        .onChange(of: service.configuration) { _, _ in clearDrafts() }
        .onChange(of: address) { previous, _ in
            if writing { interruptedOrigin = previous }
            password = ""; trustedNetwork = false; clearDrafts(); requestTask?.cancel(); service.disconnect()
        }
        .onDisappear { requestTask?.cancel(); password = ""; edits.removeAll(); service.disconnect() }
        .confirmationDialog(service.review?.isRestore == true ? "Restore the reviewed Wi-Fi settings?" : "Apply the reviewed Wi-Fi changes?", isPresented: $confirmingApply, titleVisibility: .visible) {
            if let review = service.review {
                Button(review.isRestore ? "Restore settings" : "Apply changes", role: .destructive) {
                    let reviewID = review.id
                    run { await service.apply(reviewID: reviewID) }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Changes are sent to \(service.review?.origin ?? address). Wi-Fi devices may disconnect. Use Ethernet if you need to keep access during the change.")
        }
        .confirmationDialog("Discard unsaved Wi-Fi edits?", isPresented: $confirmingReload, titleVisibility: .visible) {
            Button("Discard and reload", role: .destructive) { reload() }
            Button("Keep editing", role: .cancel) {}
        }
    }

    private var signIn: some View {
        GroupBox("Gateway admin sign-in") {
            VStack(alignment: .leading, spacing: 12) {
                Text("Use the gateway admin password from its label. This is separate from your Wi-Fi password and T-Mobile account.")
                    .font(.callout).foregroundStyle(.secondary)
                TextField("Username", text: $username).textFieldStyle(.roundedBorder)
                SecureField("Gateway admin password", text: $password).textFieldStyle(.roundedBorder)
                Text("Sign-in lasts for this window. The admin password and current Wi-Fi passwords are not saved by Shadow Utilities.")
                    .font(.caption).foregroundStyle(.secondary)
                if usesHTTP {
                    Text("This gateway uses HTTP. Your admin password and Wi-Fi configuration travel without encryption on this local network.")
                        .font(.callout)
                    Toggle("I’m connected to a trusted private network", isOn: $trustedNetwork)
                }
                Button("Sign in & load settings") {
                    let enteredPassword = password
                    let enteredUsername = username
                    password = ""
                    run { await service.connect(baseURL: address, username: enteredUsername, password: enteredPassword) }
                }.buttonStyle(.borderedProminent)
                    .disabled(busy || password.isEmpty || username.isEmpty || (usesHTTP && !trustedNetwork)
                              || TMobileGatewaySupport.privateLANBaseURL(address) == nil)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(6)
        }
    }

    private func reviewView(_ review: TMobileWiFiReview) -> some View {
        GroupBox(review.isRestore ? "Review restore" : "Review Wi-Fi changes") {
            VStack(alignment: .leading, spacing: 12) {
                LabeledContent("Gateway", value: review.origin)
                ForEach(Array(review.changes.enumerated()), id: \.offset) { _, change in Text(change) }
                Text("Password values stay hidden. The gateway is checked again before saving; if settings changed elsewhere, reload and review them again.")
                    .font(.callout).foregroundStyle(.secondary)
                Text("When previous values are available, keep this window open to review a restore after a confirmed change. Restore also requires your confirmation.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button(review.isRestore ? "Confirm restore…" : "Confirm & apply…") { confirmingApply = true }
                        .buttonStyle(.borderedProminent).disabled(busy)
                    Button("Cancel review") { service.cancelReview(); clearDrafts() }.disabled(busy)
                }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(6)
        }
    }

    private func radioSettings(_ configuration: TMobileWiFiConfiguration) -> some View {
        GroupBox("Reported radio settings") {
            VStack(alignment: .leading, spacing: 12) {
                LabeledContent("Band steering", value: boolean(configuration.bandSteeringEnabled))
                ForEach(configuration.radios) { radio in
                    Divider()
                    Text(radio.id == "2.4ghz" ? "2.4 GHz" : radio.id == "5.0ghz" ? "5 GHz" : radio.id).font(.headline)
                    LabeledContent("Radio", value: boolean(radio.isEnabled))
                    LabeledContent("Channel", value: radio.channel ?? "Not reported")
                    LabeledContent("Bandwidth", value: radio.bandwidth ?? "Not reported")
                    LabeledContent("Wi-Fi mode", value: radio.mode ?? "Not reported")
                    LabeledContent("Transmit power", value: radio.transmissionPower ?? "Not reported")
                    LabeledContent("Maximum clients", value: radio.maxClients.map(String.init) ?? "Not reported")
                    LabeledContent("MU-MIMO", value: boolean(radio.muMIMOEnabled))
                    LabeledContent("WMM", value: boolean(radio.wmmEnabled))
                    LabeledContent("Airtime fairness", value: boolean(radio.airtimeFairness))
                }
                Text("These values are shown as reported. This G4AR integration does not change radio settings or choose a manual channel.")
                    .font(.caption).foregroundStyle(.secondary)
            }.font(.callout).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(6)
        }
    }

    private var otherSettings: some View {
        GroupBox("More gateway settings") {
            VStack(alignment: .leading, spacing: 10) {
                Text("Use T-Life for frequency bands, WPA version/encryption, creating networks and gateway restart. These controls have no verified local write contract in this G4AR integration.")
                    .font(.callout).foregroundStyle(.secondary)
                Text("The documented firmware has no local DHCP, firewall or port-forward controls. Gateway firmware updates are managed by T-Mobile.")
                    .font(.caption).foregroundStyle(.secondary)
                Link("T-Life settings guide", destination: URL(string: "https://www.t-mobile.com/support/home-internet/app")!)
                if let gatewayURL = TMobileGatewaySupport.privateLANBaseURL(address) {
                    Link("Open gateway web page", destination: gatewayURL)
                }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(6)
        }.disabled(writing)
    }

    private var phaseLabel: String {
        switch service.phase {
        case .connecting: return "Signing in…"
        case .loading: return "Reading Wi-Fi settings…"
        case .applying: return "Applying reviewed changes…"
        case .verifying: return "Checking gateway settings…"
        default: return "Working…"
        }
    }
    private func boolean(_ value: Bool?) -> String { value.map { $0 ? "On" : "Off" } ?? "Not reported" }
    private func clearDrafts() { edits.removeAll(); editorGeneration = UUID() }
    private func reload() { clearDrafts(); run { await service.refresh() } }
    private func run(_ operation: @escaping @MainActor () async -> Void) {
        requestTask?.cancel()
        requestTask = Task { await operation() }
    }
    private func finish() { requestTask?.cancel(); password = ""; clearDrafts(); service.disconnect(); close() }
}

private struct TMobileWiFiNetworkEditor: View {
    let ssid: TMobileWiFiSSID
    let changed: (TMobileWiFiEdit?) -> Void
    @State private var name = ""
    @State private var replacingPassword = false
    @State private var password = ""
    @State private var broadcast = false
    @State private var guest = false

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                if ssid.editableFields.contains(.name) {
                    TextField("Network name (SSID)", text: $name).textFieldStyle(.roundedBorder)
                    Text("Up to 32 UTF-8 bytes.").font(.caption).foregroundStyle(.secondary)
                } else { LabeledContent("Network name", value: ssid.name ?? "Not reported") }
                LabeledContent("Password", value: ssid.passwordPresent ? "Configured · hidden" : "Not reported")
                if ssid.editableFields.contains(.password) {
                    Toggle("Replace Wi-Fi password", isOn: $replacingPassword)
                    if replacingPassword {
                        SecureField("New Wi-Fi password", text: $password).textFieldStyle(.roundedBorder)
                        Text("8–63 printable ASCII characters. Spaces are preserved.").font(.caption).foregroundStyle(.secondary)
                    }
                }
                if ssid.editableFields.contains(.broadcast) { Toggle("Broadcast network name", isOn: $broadcast) }
                else { LabeledContent("Broadcast network name", value: boolean(ssid.broadcastEnabled)) }
                if ssid.editableFields.contains(.guest) { Toggle("Guest network", isOn: $guest) }
                else { LabeledContent("Guest network", value: boolean(ssid.guest)) }
                DisclosureGroup("Frequency & security") {
                    VStack(alignment: .leading, spacing: 7) {
                        LabeledContent("2.4 GHz", value: boolean(ssid.twoPointFourEnabled))
                        LabeledContent("5 GHz", value: boolean(ssid.fiveEnabled))
                        LabeledContent("WPA version", value: ssid.encryptionVersion ?? "Not reported")
                        LabeledContent("Encryption", value: ssid.encryptionMode ?? "Not reported")
                        Text("Reported values. Manage these options in T-Life.").font(.caption).foregroundStyle(.secondary)
                    }.font(.callout).textSelection(.enabled)
                }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(6)
        } label: { Label(ssid.name ?? "Network \(ssid.id + 1)", systemImage: "wifi").font(.headline) }
        .onAppear { name = ssid.name ?? ""; broadcast = ssid.broadcastEnabled ?? false; guest = ssid.guest ?? false }
        .onChange(of: name) { _, _ in report() }
        .onChange(of: replacingPassword) { _, enabled in if !enabled { password = "" }; report() }
        .onChange(of: password) { _, _ in report() }
        .onChange(of: broadcast) { _, _ in report() }
        .onChange(of: guest) { _, _ in report() }
        .onDisappear { password = "" }
    }

    private func report() {
        let newName = ssid.editableFields.contains(.name) && name != ssid.name ? name : nil
        let newPassword = replacingPassword && ssid.editableFields.contains(.password) ? password : nil
        let newBroadcast = ssid.editableFields.contains(.broadcast) && broadcast != ssid.broadcastEnabled ? broadcast : nil
        let newGuest = ssid.editableFields.contains(.guest) && guest != ssid.guest ? guest : nil
        guard newName != nil || newPassword != nil || newBroadcast != nil || newGuest != nil else { changed(nil); return }
        changed(TMobileWiFiEdit(ssidID: ssid.id, name: newName, password: newPassword, broadcastEnabled: newBroadcast, guest: newGuest))
    }
    private func boolean(_ value: Bool?) -> String { value.map { $0 ? "On" : "Off" } ?? "Not reported" }
}
