// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Foundation

/// This Mac's view of its tailnet, parsed from `tailscale status --json`.
/// Only the fields shown in the panel are read: account names, emails, keys
/// and the tailnet's own name never leave the JSON.
struct TailscaleStatus: Equatable {
    enum State: Equatable { case running, stopped, needsLogin, starting, other }

    struct Peer: Equatable, Identifiable {
        let id: String
        let name: String
        let address: String?
        let os: String
        let online: Bool
        /// The DERP region relaying traffic; nil once a direct path is up.
        let relay: String?
        let isExitNode: Bool
    }

    let state: State
    let name: String?
    let address: String?
    let exitNode: String?
    let peers: [Peer]

    static func parse(_ data: Data) -> TailscaleStatus? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let backend = root["BackendState"] as? String else { return nil }
        let state: State = switch backend {
        case "Running": .running
        case "Stopped": .stopped
        case "NeedsLogin", "NeedsMachineAuth": .needsLogin
        case "Starting": .starting
        default: .other
        }
        let me = root["Self"] as? [String: Any] ?? [:]
        let peers = ((root["Peer"] as? [String: Any]) ?? [:]).compactMap { key, value -> Peer? in
            guard let peer = value as? [String: Any] else { return nil }
            let direct = !((peer["CurAddr"] as? String) ?? "").isEmpty
            let relay = (peer["Relay"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            return Peer(id: (peer["ID"] as? String) ?? key,
                        name: displayName(peer),
                        address: ipv4(peer["TailscaleIPs"]),
                        os: (peer["OS"] as? String) ?? "",
                        online: (peer["Online"] as? Bool) ?? false,
                        relay: direct ? nil : relay,
                        isExitNode: (peer["ExitNode"] as? Bool) ?? false)
        }
        .sorted { ($0.online ? 0 : 1, $0.name.lowercased()) < ($1.online ? 0 : 1, $1.name.lowercased()) }
        return TailscaleStatus(state: state,
                               name: fqdn(me["DNSName"]),
                               address: ipv4(root["TailscaleIPs"]) ?? ipv4(me["TailscaleIPs"]),
                               exitNode: peers.first(where: \.isExitNode)?.name,
                               peers: peers)
    }

    /// Round-trip time from `tailscale ping` output, e.g.
    /// "pong from host (100.x.y.z) via DERP(sfo) in 45ms".
    static func pingMilliseconds(_ output: String) -> Double? {
        guard let line = output.split(separator: "\n").first(where: { $0.hasPrefix("pong from ") }),
              let range = line.range(of: #" in ([0-9]+(\.[0-9]+)?)ms"#, options: .regularExpression) else { return nil }
        return Double(line[range].dropFirst(4).dropLast(2))
    }

    private static func displayName(_ peer: [String: Any]) -> String {
        if let dns = fqdn(peer["DNSName"]), let label = dns.split(separator: ".").first { return String(label) }
        return (peer["HostName"] as? String) ?? "?"
    }

    private static func fqdn(_ value: Any?) -> String? {
        guard var name = value as? String, !name.isEmpty else { return nil }
        if name.hasSuffix(".") { name.removeLast() }
        return name
    }

    private static func ipv4(_ value: Any?) -> String? {
        (value as? [String])?.first { $0.contains(".") }
    }
}
