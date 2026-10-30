// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Network

/// Read-only link to the Shadow server's MQTT broker over the tailnet. The server
/// talks to the gateway; this app only subscribes to what the server publishes.
@MainActor final class ShadowServerConnection: ObservableObject {
    static let shared = ShadowServerConnection()

    enum State: Equatable { case off, connecting, connected, failed(String) }

    @Published private(set) var state = State.off
    @Published private(set) var towers: [ShadowServerTower] = []
    @Published private(set) var serving: ShadowServerTower?
    @Published private(set) var updatedAt: Date?
    /// The gateway reading the server last published; the recorder prefers it over polling the gateway.
    @Published private(set) var routerReading: RouterReading?
    @Published var host: String { didSet { defaults.set(host, forKey: Keys.host) } }
    @Published var port: String { didSet { defaults.set(port, forKey: Keys.port) } }
    @Published var username: String
    @Published var password = ""
    @Published private(set) var hasSavedPassword = false

    private enum Keys {
        static let host = "shadowServer.host", port = "shadowServer.port", enabled = "shadowServer.enabled"
    }
    private struct Saved: Codable { let username: String; let password: String }
    struct RouterReading: Equatable { let snapshot: TMobileGatewaySnapshot; let date: Date }

    private let defaults: UserDefaults
    private let store: any ScopedCredentialStore
    private let scope: ScopedCredentialScope
    // Cached after one read so automatic retries never show Keychain prompts.
    private var credentials: Saved?
    private var connection: NWConnection?
    private var buffer = Data()
    private var watchdog: Task<Void, Never>?
    private var lastInbound = Date.distantPast
    private var retryID: UUID?
    // Live (non-retained) router fields with their arrival time on this Mac.
    private var routerValues: [String: (value: Any, at: Date)] = [:]
    private var routerBuildID: UUID?
    private static let keepAlive: UInt16 = 60

    init(defaults: UserDefaults = .standard, store: any ScopedCredentialStore = KeychainScopedCredentialStore()) {
        self.defaults = defaults
        self.store = store
        scope = .init(service: AppCredentialServices.service("shadow-server-mqtt.v1"), account: "shadow-mqtt")
        host = defaults.string(forKey: Keys.host) ?? ""
        port = defaults.string(forKey: Keys.port) ?? "1884"
        username = "shadow-readonly"
        if let saved = try? loadSaved(allowingUserInteraction: false) {
            credentials = saved; username = saved.username; hasSavedPassword = true
        }
    }

    var isActive: Bool { state == .connecting || state == .connected }

    var statusText: String {
        switch state {
        case .off: return "Shadow server off"
        case .connecting: return "Connecting to Shadow server…"
        case .connected: return "Connected to Shadow server"
        case .failed(let message): return message
        }
    }

    var canConnect: Bool {
        ShadowServerMQTT.isTailnetHost(host) && UInt16(port) != nil && !username.isEmpty
            && (hasSavedPassword || !password.isEmpty)
    }

    /// Reconnects without Keychain UI, and only if the owner turned the link on before.
    func resume() {
        if defaults.bool(forKey: Keys.enabled), state == .off { connect(interactive: false) }
    }

    func connect(interactive: Bool = true) {
        guard ShadowServerMQTT.isTailnetHost(host), let portNumber = UInt16(port),
              let nwPort = NWEndpoint.Port(rawValue: portNumber) else {
            stop("Enter the server's tailnet address (100.x.y.z or name.ts.net)"); return
        }
        if credentials == nil, password.isEmpty {
            credentials = try? loadSaved(allowingUserInteraction: interactive)
        }
        let secret = password.isEmpty ? credentials?.password : password
        guard let secret else { stop("Enter the MQTT password and press Connect"); return }
        if credentials?.username != username || credentials?.password != secret {
            let saved = Saved(username: username, password: secret)
            do {
                let data = try JSONEncoder().encode(saved)
                try store.save(String(decoding: data, as: UTF8.self), scope: scope)
            } catch { stop("The password could not be saved to the Keychain"); return }
            credentials = saved
        }
        password = ""; hasSavedPassword = true
        guard let saved = credentials else { return }
        defaults.set(true, forKey: Keys.enabled)
        teardown()
        state = .connecting
        let connection = NWConnection(host: .init(host.trimmingCharacters(in: .whitespaces)), port: nwPort, using: .tcp)
        self.connection = connection
        connection.stateUpdateHandler = { [weak self] newState in
            Task { @MainActor in self?.handle(newState, saved: saved, connection: connection) }
        }
        connection.start(queue: .main)
    }

    func disconnect() {
        defaults.set(false, forKey: Keys.enabled)
        connection?.send(content: ShadowServerMQTT.disconnect, completion: .idempotent)
        teardown()
        state = .off
    }

    func forgetPassword() {
        disconnect()
        try? store.delete(scope: scope)
        credentials = nil
        hasSavedPassword = false
    }

    private func loadSaved(allowingUserInteraction: Bool) throws -> Saved? {
        guard let value = try store.read(scope: scope, allowingUserInteraction: allowingUserInteraction) else { return nil }
        return try JSONDecoder().decode(Saved.self, from: Data(value.utf8))
    }

    private func handle(_ newState: NWConnection.State, saved: Saved, connection: NWConnection) {
        guard connection === self.connection else { return }
        switch newState {
        case .ready:
            guard Self.peerIsOnTailnet(connection) else {
                stop("Shadow server address resolved outside the tailnet · not connecting"); return
            }
            lastInbound = Date()
            let clientID = "shadow-utils-\(UUID().uuidString.prefix(8))"
            connection.send(content: ShadowServerMQTT.connect(clientID: clientID, username: saved.username,
                                                              password: saved.password, keepAlive: Self.keepAlive),
                            completion: .idempotent)
            // App Nap defers AppKit timers in this background menu-bar app, which
            // starved the keepalive; Task.sleep keeps time (as the gateway poller does).
            watchdog = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 15_000_000_000)
                    guard !Task.isCancelled else { return }
                    self?.tick(connection)
                }
            }
            receive(on: connection)
        case .failed, .waiting:
            fail("Shadow server unreachable · check Tailscale")
        default: break
        }
    }

    private static func peerIsOnTailnet(_ connection: NWConnection) -> Bool {
        guard case .hostPort(let host, _)? = connection.currentPath?.remoteEndpoint else { return false }
        switch host {
        case .ipv4(let address): return ShadowServerMQTT.isTailnetAddress([UInt8](address.rawValue))
        case .ipv6(let address): return ShadowServerMQTT.isTailnetAddress([UInt8](address.rawValue))
        default: return false
        }
    }

    /// Pings while connected and drops links that stop answering (half-open TCP, no CONNACK).
    private func tick(_ connection: NWConnection) {
        guard connection === self.connection else { return }
        let silence = Date().timeIntervalSince(lastInbound)
        if state == .connecting, silence > 15 { fail("Shadow server did not answer the MQTT login"); return }
        if silence > Double(Self.keepAlive) * 1.5 { fail("Shadow server stopped answering"); return }
        if state == .connected { connection.send(content: ShadowServerMQTT.ping, completion: .idempotent) }
    }

    private func receive(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            Task { @MainActor in
                guard let self, connection === self.connection else { return }
                if let data { self.buffer.append(data) }
                do {
                    for packet in try ShadowServerMQTT.decode(&self.buffer) {
                        // A packet may have torn this connection down (rejected login or topics).
                        guard connection === self.connection else { return }
                        self.lastInbound = Date()
                        self.handle(packet, on: connection)
                    }
                } catch { self.fail("Shadow server sent data this app could not read"); return }
                guard connection === self.connection else { return }
                if isComplete || error != nil { self.fail("Shadow server closed the connection"); return }
                self.receive(on: connection)
            }
        }
    }

    private func handle(_ packet: ShadowServerMQTT.Packet, on connection: NWConnection) {
        switch packet {
        case .connAck(let code):
            // 4 = bad username or password, 5 = not authorized: retrying cannot help.
            guard code == 0 else {
                stop(code == 4 || code == 5 ? "Shadow server rejected the MQTT login" : "Shadow server refused the connection (\(code))")
                return
            }
            state = .connected
            connection.send(content: ShadowServerMQTT.subscribe(ShadowServerMQTT.topics + ShadowServerRouter.topics, packetID: 1),
                            completion: .idempotent)
        case .subAck(let granted):
            if granted.contains(0x80) { stop("Shadow server denied this login access to tower topics") }
        case .publish(let topic, let payload, let retained):
            if topic == "van/router/towers/estimated", let list = ShadowServerTower.list(payload) { towers = list }
            if topic == "van/router/towers/serving" { serving = ShadowServerTower.one(payload) }
            // Retained replays may describe a radio that has since disappeared; only live polls count.
            if !retained, topic.hasPrefix(ShadowServerRouter.topicPrefix + "signal/") || topic.hasPrefix(ShadowServerRouter.topicPrefix + "cell/") {
                routerValue(String(topic.dropFirst(ShadowServerRouter.topicPrefix.count)), payload)
            }
            updatedAt = Date()
        case .pingResp, .other: break
        }
    }

    /// The server publishes one topic per field each poll. Build a reading shortly
    /// after the poll's `updated` stamp from fields that arrived live in that poll,
    /// so a field the gateway stopped reporting is not carried forward. The reading
    /// is dated by this Mac's clock, which the recorder's freshness checks use.
    private func routerValue(_ key: String, _ payload: Data) {
        let now = Date()
        if let value = ShadowServerRouter.value(payload) { routerValues[key] = (value, now) } else { routerValues[key] = nil }
        guard key == ShadowServerRouter.updatedKey else { return }
        let build = UUID()
        routerBuildID = build
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard let self, self.routerBuildID == build, self.state == .connected else { return }
            let poll = self.routerValues.filter { abs($0.value.at.timeIntervalSince(now)) <= 5 }.mapValues(\.value)
            guard let reading = ShadowServerRouter.reading(poll) else { return }
            self.routerReading = RouterReading(snapshot: reading.snapshot, date: now)
        }
    }

    /// A failure a retry cannot fix: stays failed until the owner presses Connect.
    private func stop(_ message: String) {
        teardown()
        state = .failed(message)
    }

    /// A transient failure: retries in 15 s while the owner keeps the link on.
    private func fail(_ message: String) {
        teardown()
        state = .failed(message)
        let attempt = UUID()
        retryID = attempt
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(15))
            guard let self, self.retryID == attempt, case .failed = self.state else { return }
            self.state = .off
            self.resume()
        }
    }

    private func teardown() {
        retryID = nil
        routerBuildID = nil
        routerValues = [:]
        routerReading = nil
        watchdog?.cancel(); watchdog = nil
        connection?.stateUpdateHandler = nil
        connection?.cancel(); connection = nil
        buffer = Data()
    }
}
