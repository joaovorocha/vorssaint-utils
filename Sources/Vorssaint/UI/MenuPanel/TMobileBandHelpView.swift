// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import SwiftUI

/// Keep the native button separate from the selectable row's AX summary.
/// Ignoring the entire row's children would hide the information button.
struct TMobileBandDetailRow: View {
    let row: TMobileGatewayRadioPresentation.Row
    let bands: [String]
    let isFiveG: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(row.label).foregroundStyle(.secondary).accessibilityHidden(true)
            TMobileBandHelpButton(bands: bands, isFiveG: isFiveG,
                                 capability: row.id == .supportedBands)
            Spacer(minLength: 16)
            VStack(alignment: .trailing) {
                Text(row.value).monospacedDigit().multilineTextAlignment(.trailing)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(row.accessibilityValue)
        }
    }
}

struct TMobileBandHelpButton: View {
    let bands: [String]
    let isFiveG: Bool
    let capability: Bool
    @State private var showing = false

    private var purpose: String {
        "Explain \(capability ? "supported" : "reported") \(isFiveG ? "5G" : "LTE") bands"
    }

    var body: some View {
        Button { showing = true } label: {
            Image(systemName: "info.circle")
                .font(.system(size: 13))
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .textSelection(.disabled)
        .help(purpose)
        .accessibilityLabel(purpose)
        .accessibilityHint("Shows frequency, typical uses, and coverage tradeoffs for these bands.")
        .popover(isPresented: $showing) {
            TMobileBandHelpView(bands: bands, isFiveG: isFiveG, capability: capability) {
                showing = false
            }
        }
    }
}

struct TMobileBandHelpView: View {
    let bands: [String]
    let isFiveG: Bool
    let capability: Bool
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(isFiveG ? "5G band guide" : "LTE band guide").font(.headline)
                Spacer()
                Button("Done", action: close).keyboardShortcut(.cancelAction)
            }
            Text(capability
                 ? "These bands are supported by the gateway. This list does not mean they are connected or available nearby."
                 : "These bands were reported in this reading. The gateway selects the connection; LTE bands can provide an anchor alongside 5G.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if bands.count > 1 {
                Text("\(bands.count) bands · Scroll to see all")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(Array(bands.enumerated()), id: \.offset) { index, band in
                        VStack(alignment: .leading, spacing: 5) {
                            if let entry = TMobileBandGuide.entry(for: band) {
                                Text("\(band) · \(entry.frequency)").font(.headline)
                                Text(entry.category).font(.subheadline).foregroundStyle(.secondary)
                                Text(entry.use)
                                Text(entry.tradeoff).foregroundStyle(.secondary)
                            } else {
                                Text(band).font(.headline)
                                Text("A verified description for this band is not included yet. Its name alone does not establish frequency, performance, or local availability.")
                            }
                        }
                        .fixedSize(horizontal: false, vertical: true)
                        if index < bands.count - 1 { Divider() }
                    }
                }
                .font(.callout).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading).padding(.trailing, 8)
            }
            .scrollIndicators(.visible)
            .frame(height: min(360, CGFloat(max(1, bands.count)) * 130))
            Text("Frequency ranges describe the standard, not your carrier’s entire allocation. Actual speed depends on channel width, signal quality, congestion, and the gateway; no band guarantees a speed or distance.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Link("T-Mobile network and band information", destination: TMobileBandGuide.carrierSource)
                .font(.caption)
            Link("3GPP standard band frequencies", destination: isFiveG ? TMobileBandGuide.nrSource : TMobileBandGuide.lteSource)
                .font(.caption)
        }
        .padding(16).frame(width: 400)
    }
}
