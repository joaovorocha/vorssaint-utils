// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint
import SwiftUI

/// Local references can accompany either public radio details or an explicitly
/// requested admin read. Matching identifiers never verifies a pin's position.
struct TMobileTowerReferenceView: View {
    let radio: TMobileRadioSignal
    let isFiveG: Bool
    let eNodeBID: UInt32?
    let ecgi: String?
    @ObservedObject private var store = TMobileGatewayHistoryStore.shared
    @State private var showingHistory = false

    init(radio: TMobileRadioSignal, isFiveG: Bool, eNodeBID: UInt32? = nil, ecgi: String? = nil) {
        self.radio = radio; self.isFiveG = isFiveG
        self.eNodeBID = eNodeBID; self.ecgi = ecgi
    }

    private var radioKind: TMobileTowerRadio { isFiveG ? .nr : .lte }
    private var nodeID: UInt32? { isFiveG ? radio.gNodeBID : eNodeBID }
    private var references: [TMobileTowerPin] {
        store.towers.filter { $0.radio == nil || $0.radio == radioKind }.sorted {
            let first = identityMatch($0) != nil, second = identityMatch($1) != nil
            if first != second { return first }
            let order = $0.name.localizedCaseInsensitiveCompare($1.name)
            return order == .orderedSame ? $0.id.uuidString < $1.id.uuidString : order == .orderedAscending
        }
    }

    var body: some View {
        let pins = references
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Local tower references", systemImage: "mappin.and.ellipse").font(.headline)
                Spacer()
                Button("Manage pins…") { showingHistory = true }
            }
            Text("Saved on this Mac. An identifier match links a local reference; the tower location remains unverified.")
                .font(.caption).foregroundStyle(.secondary)
            if pins.isEmpty {
                Text("Add a manual pin or import a local JSON or CSV file to see references for \(radioKind.label).")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                if nodeID == nil && ecgi == nil {
                    Text("No node ID or ECGI reported. Saved pins are candidates only.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(pins.prefix(8)) { pin in
                    TMobileTowerReferenceRow(pin: pin, identity: identityMatch(pin),
                                             measurementCoordinate: store.measurementCoordinate)
                }
                if pins.count > 8 {
                    Text("Showing 8 of \(pins.count) local references. Manage pins to search all saved entries.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if store.measurementCoordinate == nil {
                    Text("Enter a measurement location in Manage pins to show distance and bearing to these saved coordinates.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .textSelection(.enabled)
        .sheet(isPresented: $showingHistory) { TMobileGatewayHistoryView() }
    }

    private func identityMatch(_ pin: TMobileTowerPin) -> TMobileTowerIdentityMatch? {
        TMobileTowerReferenceSupport.match(pin, radio: radioKind, nodeID: nodeID, ecgi: ecgi)
    }
}

private struct TMobileTowerReferenceRow: View {
    let pin: TMobileTowerPin
    let identity: TMobileTowerIdentityMatch?
    let measurementCoordinate: TMobileMapCoordinate?

    private var geometry: TMobileTowerGeometry? {
        measurementCoordinate.flatMap { TMobileTowerReferenceSupport.geometry(from: $0, to: pin.coordinate) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(pin.name).font(.callout.weight(.semibold))
                Spacer()
                Label(identity?.label ?? "Candidate", systemImage: identity == nil ? "mappin" : "link")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text("Location unverified · \(pin.provenance ?? "Local reference; source unspecified")")
                .font(.caption).foregroundStyle(.secondary)
            if let radio = pin.radio {
                HStack(spacing: 10) {
                    Text(radio.label)
                    if let node = pin.nodeID { Text("\(radio.nodeLabel) \(node)") }
                    if let ecgi = pin.ecgi { Text("ECGI \(ecgi)") }
                }.font(.caption).monospacedDigit()
            }
            if let geometry {
                Text(distanceText(geometry)).font(.caption).monospacedDigit().foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .combine)
    }

    private func distanceText(_ geometry: TMobileTowerGeometry) -> String {
        let distance = geometry.distanceMeters < 1_000
            ? "\(geometry.distanceMeters.formatted(.number.precision(.fractionLength(0)))) m"
            : "\((geometry.distanceMeters / 1_000).formatted(.number.precision(.fractionLength(1)))) km"
        let direction = geometry.bearingDegrees.map { " · \($0.formatted(.number.precision(.fractionLength(0))))° bearing" } ?? ""
        return "From your manual measurement location: \(distance)\(direction)"
    }
}
