// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Foundation

/// View-owned, read-only reader of the local Tailscale client. It runs the
/// installed CLI and never changes the tailnet or talks to the control plane.
@MainActor
final class TailscaleStatusService: ObservableObject {
    @Published private(set) var status: TailscaleStatus?
    @Published private(set) var failed = false
    /// Round-trip times by peer id, filled only when the user asks.
    @Published private(set) var latency: [String: Double] = [:]
    @Published private(set) var measuring = false
    private var loop: Task<Void, Never>?

    static let cliPath: String? = [
        "/Applications/Tailscale.app/Contents/MacOS/Tailscale",
        "/opt/homebrew/bin/tailscale",
        "/usr/local/bin/tailscale",
    ].first { FileManager.default.isExecutableFile(atPath: $0) }

    static var isInstalled: Bool { cliPath != nil }

    // A Task.sleep loop, not a Timer: App Nap throttles timers in menu-bar apps.
    func start() {
        guard loop == nil, let cli = Self.cliPath else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                let result = await Task.detached {
                    BoundedProcessRunner.run(cli, ["status", "--json"], timeout: 5, maxOutputBytes: 2_000_000)
                }.value
                guard let self, !Task.isCancelled else { return }
                let parsed = result.status == 0 ? TailscaleStatus.parse(result.output) : nil
                if parsed != nil || status == nil { status = parsed }
                failed = parsed == nil
                do { try await Task.sleep(nanoseconds: 15_000_000_000) } catch { return }
            }
        }
    }

    func stop() {
        loop?.cancel()
        loop = nil
    }

    /// One `tailscale ping` each for the first eight online peers.
    func measureLatency() {
        guard !measuring, let cli = Self.cliPath, let peers = status?.peers else { return }
        let targets = peers.filter(\.online).compactMap { peer in peer.address.map { (peer.id, $0) } }.prefix(8)
        measuring = true
        Task { [weak self] in
            let times = await withTaskGroup(of: (String, Double?).self) { group in
                for (id, address) in targets {
                    group.addTask {
                        let result = BoundedProcessRunner.run(cli, ["ping", "-c", "1", "--timeout", "3s", address],
                                                              timeout: 5, maxOutputBytes: 4096)
                        return (id, TailscaleStatus.pingMilliseconds(String(decoding: result.output, as: UTF8.self)))
                    }
                }
                return await group.reduce(into: [String: Double]()) { $0[$1.0] = $1.1 }
            }
            self?.latency = times
            self?.measuring = false
        }
    }
}
