// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint
import SwiftUI

/// A compact inspector for an existing source-declared map reference.
struct TMobileTowerMapInspector: View {
    let pin: TMobileTowerPin
    var measurementCoordinate: TMobileMapCoordinate? = nil
    @State private var showIdentity = false
    @State private var showBandGuide = false

    init(pin: TMobileTowerPin, measurementCoordinate: TMobileMapCoordinate? = nil) {
        self.pin = pin
        self.measurementCoordinate = measurementCoordinate
    }

    private var presentation: TMobileTowerMapPresentation {
        .init(pin: pin, measurementCoordinate: measurementCoordinate)
    }

    var body: some View {
        let value = presentation
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text(verbatim: value.title).font(.title3.weight(.semibold))
                Label(value.status, systemImage: value.isCommunityCellEstimate ? "person.2" : "mappin")
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(.quaternary, in: Capsule())
                Text(value.isCommunityCellEstimate ? "Not a confirmed tower location." : "This reference does not confirm a tower or serving connection.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(value.positionDescription).font(.caption).foregroundStyle(.secondary)
                fact("Latitude", value.latitude, monospaced: true)
                fact("Longitude", value.longitude, monospaced: true)
            }
            Divider()
            fact("Technology", value.technology)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text("Source-declared bands").font(.caption).foregroundStyle(.secondary)
                    if !value.bandDescriptions.isEmpty {
                        Button { showBandGuide = true } label: {
                            Image(systemName: "info.circle").font(.system(size: 13))
                                .frame(width: 24, height: 24).contentShape(Rectangle())
                        }
                            .buttonStyle(.plain).foregroundStyle(.secondary)
                            .textSelection(.disabled)
                            .help("Explain source-declared bands")
                            .accessibilityLabel("Explain source-declared bands")
                            .popover(isPresented: $showBandGuide) {
                                TMobileTowerMapBandGuide(bands: value.bandDescriptions)
                            }
                    }
                }
                Text(verbatim: value.bands).font(.callout)
            }
            fact("Maximum speed / site capacity", value.speedAndCapacity)

            if let position = value.relativePosition {
                VStack(alignment: .leading, spacing: 6) {
                    Text("From measurement location").font(.caption).foregroundStyle(.secondary)
                    fact("Straight-line distance", position.distance)
                    fact("Bearing to reference", position.bearing ?? "Unavailable")
                }
            }

            DisclosureGroup("Cell identity & source", isExpanded: $showIdentity) {
                VStack(alignment: .leading, spacing: 8) {
                    if let cell = value.cellID { fact("Cell ID", cell, monospaced: true) }
                    if let node = value.nodeID { fact(value.nodeLabel, node, monospaced: true) }
                    if let ecgi = value.ecgi { fact("ECGI", ecgi, monospaced: true) }
                    if !value.hasIdentity {
                        Text("Cell identity not provided.").font(.caption).foregroundStyle(.secondary)
                    }
                    fact("Source", value.source)
                    Text("Identifiers are source-declared; they do not prove a serving connection.")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(.top, 6)
            }.font(.callout)

            if value.isCommunityCellEstimate {
                VStack(alignment: .leading, spacing: 3) {
                    Link("Cell data from OpenCelliD", destination: TMobileTowerMapPresentation.openCellIDSource)
                    Link("CC BY-SA 4.0", destination: TMobileTowerMapPresentation.openCellIDLicense)
                }.font(.caption).textSelection(.disabled)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
        .onChange(of: pin.id) { _, _ in showIdentity = false; showBandGuide = false }
    }

    /// Each selectable fact owns an explicit AX label. Combining selectable
    /// children can recurse through AppKit's accessibility description lookup.
    private func fact(_ label: String, _ value: String, monospaced: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(verbatim: label).font(.caption).foregroundStyle(.secondary)
            Text(verbatim: value).font(.callout).monospacedDigit()
                .fontDesign(monospaced ? .monospaced : .default)
        }
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: "\(label): \(value)"))
    }
}

private struct TMobileTowerMapBandGuide: View {
    let bands: [TMobileTowerMapPresentation.BandDescription]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Band guide").font(.headline)
            Text("General band information for this source’s declared bands. It does not establish active service, the site’s full capabilities or a maximum speed.")
                .font(.caption).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(bands, id: \.code) { band in
                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(band.code) · \(band.guide.frequency)").font(.callout.bold())
                            Text(band.guide.category).font(.caption).foregroundStyle(.secondary)
                            Text(band.guide.use)
                            Text(band.guide.tradeoff).foregroundStyle(.secondary)
                        }
                        if band.code != bands.last?.code { Divider() }
                    }
                }.font(.callout).frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: min(300, CGFloat(max(1, bands.count)) * 190))
            if bands.contains(where: { $0.code.hasPrefix("n") }) {
                Link("3GPP 5G band frequencies", destination: TMobileBandGuide.nrSource)
            }
            if bands.contains(where: { $0.code.hasPrefix("b") }) {
                Link("3GPP LTE band frequencies", destination: TMobileBandGuide.lteSource)
            }
        }
        .font(.caption).textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
        .padding(16).frame(width: 320)
    }
}
