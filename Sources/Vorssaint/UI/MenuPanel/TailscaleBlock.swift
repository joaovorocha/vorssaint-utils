// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import SwiftUI

/// This Mac's tailnet state and its peers, read from the local Tailscale client.
struct TailscaleBlock: View {
    @Binding var isVisible: Bool
    var editing: Bool
    @StateObject private var service = TailscaleStatusService()
    @ObservedObject private var l10n = L10n.shared

    private var strings: TailscaleStrings { .localized(l10n.language) }
    private let symbol = "point.3.connected.trianglepath.dotted"

    var body: some View {
        Group {
            if !isVisible {
                PanelHiddenItemRow(title: strings.title, systemImage: symbol, isVisible: $isVisible)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Label(strings.title, systemImage: symbol)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                        if let status = service.status { stateLabel(status.state) }
                        if editing { PanelInlineHideButton(isVisible: $isVisible) }
                    }
                    if let status = service.status {
                        details(status)
                    } else if service.failed {
                        Text(strings.unavailable).font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }
                .onAppear { service.start() }
                .onDisappear { service.stop() }
            }
        }
    }

    private func stateLabel(_ state: TailscaleStatus.State) -> some View {
        let (text, color): (String, Color) = switch state {
        case .running: (strings.connected, .green)
        case .stopped: (strings.stopped, .secondary)
        case .needsLogin: (strings.needsLogin, .orange)
        case .starting, .other: (strings.starting, .secondary)
        }
        return Text(text).font(.system(size: 10, weight: .medium)).foregroundStyle(color)
    }

    @ViewBuilder
    private func details(_ status: TailscaleStatus) -> some View {
        if status.state == .running {
            if let name = status.name ?? status.address {
                row(String(name.prefix { $0 != "." }),
                    value: [status.address, status.name].compactMap { $0 }.joined(separator: "\n"))
            }
            if let exit = status.exitNode { row(strings.exitNode, value: exit) }
            if !status.peers.isEmpty {
                HStack {
                    Text(strings.devices).font(.system(size: 10, weight: .medium)).foregroundStyle(.tertiary)
                    Spacer(minLength: 0)
                    if service.measuring {
                        ProgressView().controlSize(.mini)
                    } else {
                        Button(strings.measureLatency) { service.measureLatency() }
                            .buttonStyle(.plain).font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }
                ForEach(status.peers) { peerRow($0) }
            }
        }
    }

    private func row(_ title: String, value: String) -> some View {
        HStack(alignment: .top) {
            Text(title).font(.system(size: 10)).foregroundStyle(.tertiary)
            Spacer()
            Text(value)
                .font(.system(size: 10.5, weight: .medium)).monospacedDigit()
                .multilineTextAlignment(.trailing).foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
    }

    private func peerRow(_ peer: TailscaleStatus.Peer) -> some View {
        HStack(spacing: 6) {
            Circle().fill(peer.online ? Color.green : Color.secondary.opacity(0.4)).frame(width: 6, height: 6)
            Text(peer.name).font(.system(size: 10.5)).lineLimit(1).truncationMode(.middle)
                .foregroundStyle(peer.online ? .primary : .secondary)
                .help([peer.address, peer.os].compactMap { $0 }.joined(separator: " · "))
            if peer.isExitNode {
                Image(systemName: "arrow.up.forward.circle").font(.system(size: 9)).foregroundStyle(.secondary)
                    .help(strings.exitNode)
            }
            Spacer(minLength: 4)
            Text(pathText(peer)).font(.system(size: 10)).monospacedDigit().foregroundStyle(.tertiary)
        }
        .accessibilityElement(children: .combine)
    }

    private func pathText(_ peer: TailscaleStatus.Peer) -> String {
        guard peer.online else { return strings.offline }
        let path = peer.relay.map { "\(strings.relay) \($0)" } ?? strings.direct
        guard let ms = service.latency[peer.id] else { return path }
        return "\(path) · \(Int(ms.rounded())) ms"
    }
}
