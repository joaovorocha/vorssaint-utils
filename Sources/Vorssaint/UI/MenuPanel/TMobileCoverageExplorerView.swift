// SPDX-License-Identifier: GPL-3.0-or-later
import MapKit
import SwiftUI

/// Map-first presentation with explicit, independently selectable source layers.
/// Concrete inputs also allow native previews without opening private stores.
struct TMobileCoverageExplorerView: View {
    let observations: [TMobileCoverageObservation]
    let towers: [TMobileTowerPin]
    let referenceOverlays: [TMobileCoverageMapReferenceOverlay]
    @Binding var metric: TMobileCoverageMetric
    @Binding var displayMode: TMobileCoverageMapMode
    @Binding var selectedObservationID: UUID?
    @Binding var selectedTowerID: UUID?
    @Binding var showsMeasurements: Bool
    @Binding var showTowers: Bool
    @Binding var showFCC: Bool
    var initialRegion: MKCoordinateRegion? = nil
    var onRegionChanged: ((MKCoordinateRegion) -> Void)? = nil
    var onLoadCoverage: () -> Void = {}
    var onFindCells: () -> Void = {}
    var onManageTowers: () -> Void = {}
    var onReadingDetails: () -> Void = {}
    @State private var towerQuery = ""
    @State private var towerListLimit = 12

    private var selectedTower: TMobileTowerPin? { towers.first { $0.id == selectedTowerID } }
    private var selectedReading: TMobileCoverageObservation? {
        observations.first { $0.id == selectedObservationID } ?? observations.last
    }
    private var measurementCoordinate: TMobileMapCoordinate? {
        selectedReading.flatMap { TMobileCoverageMapDrawing.coordinate(for: $0, metric: metric) }
    }
    private var matchingTowers: [TMobileTowerPin] {
        let query = towerQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return towers }
        return towers.filter {
            [$0.name, $0.bands, $0.cellID ?? "", $0.radio?.label ?? ""]
                .contains { $0.localizedCaseInsensitiveContains(query) }
        }
    }
    private var mapSelection: Binding<UUID?> {
        Binding(get: { selectedTower == nil ? selectedObservationID : nil }, set: {
            selectedTowerID = nil
            selectedObservationID = $0
        })
    }
    private var hasModeledSignal: Bool {
        referenceOverlays.contains { $0.modeledSignalDBm?.contains(where: { $0 != nil }) == true }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            layers
            GeometryReader { geometry in
                HStack(alignment: .top, spacing: 16) {
                    mapColumn(height: geometry.size.height)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    Divider()
                    ScrollView {
                        details.padding(.trailing, 4)
                    }
                    .frame(width: geometry.size.width < 1_000 ? 286 : 310)
                }
            }
        }
        .padding(16)
    }

    private var layers: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 16) {
                layerToggles
                Spacer(minLength: 8)
                Button("Data & settings…", action: onLoadCoverage)
            }
            VStack(alignment: .leading, spacing: 8) {
                layerToggles
                Button("Data & settings…", action: onLoadCoverage)
            }
        }
        .font(.callout)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var layerToggles: some View {
        HStack(spacing: 14) {
            Text("Layers").fontWeight(.semibold)
            Toggle("FCC model", isOn: $showFCC)
            Toggle("My readings", isOn: $showsMeasurements)
            Toggle("Towers & cells", isOn: $showTowers)
        }
        .toggleStyle(.checkbox)
        .fixedSize()
    }

    private func mapColumn(height: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    metricPicker
                    Spacer(minLength: 0)
                    displayPicker
                }
                VStack(alignment: .leading, spacing: 8) { metricPicker; displayPicker }
            }
            TMobileCoverageMapView(observations: observations,
                                  towers: showTowers ? towers : [],
                                  referenceOverlays: showFCC ? referenceOverlays : [],
                                  metric: metric, displayMode: displayMode,
                                  selectedObservationID: mapSelection,
                                  selectedTowerID: selectedTowerID,
                                  onTowerSelected: { selectedTowerID = $0 },
                                  showsMeasurements: showsMeasurements,
                                  canvasHeight: max(220, height - 171),
                                  showsExplanations: false,
                                  initialRegion: initialRegion,
                                  onRegionChanged: onRegionChanged)
            legend
        }
    }

    private var metricPicker: some View {
        Picker("Measured", selection: $metric) {
            ForEach(TMobileCoverageMetric.allCases) { Text($0.title).tag($0) }
        }
        .frame(width: 235)
        .disabled(!showsMeasurements)
    }

    private var displayPicker: some View {
        Picker("Reading display", selection: $displayMode) {
            Text("Heat").tag(TMobileCoverageMapMode.heat)
            Text("Points").tag(TMobileCoverageMapMode.samples)
        }
        .labelsHidden().pickerStyle(.segmented).frame(width: 140)
        .disabled(!showsMeasurements)
    }

    private var legend: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Text("FCC model").fontWeight(.medium)
                if hasModeledSignal {
                    LinearGradient(colors: [Color(nsColor: TMobileCoverageMapDrawing.referenceColor(modeledSignalDBm: -120)),
                                            Color(nsColor: TMobileCoverageMapDrawing.referenceColor(modeledSignalDBm: -50))],
                                   startPoint: .leading, endPoint: .trailing)
                        .frame(width: 66, height: 8).clipShape(Capsule())
                    Text("−120 → −50 dBm RSRP")
                } else {
                    RoundedRectangle(cornerRadius: 2).fill(.blue.opacity(0.35)).frame(width: 16, height: 10)
                    Text(referenceOverlays.isEmpty ? "No coverage loaded" : "Coverage footprint")
                }
            }
            HStack(spacing: 12) {
                Text("Measured").fontWeight(.medium)
                Label("Good", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                Label("Fair", systemImage: "minus.circle.fill").foregroundStyle(.orange)
                Label("Poor", systemImage: "exclamationmark.circle.fill").foregroundStyle(.red)
            }
            Text(displayMode == .heat
                 ? "Measured heat uses recorded 50 m cells only. Empty space has no measurements."
                 : "Points are recorded positions. Gray means no value for the selected metric.")
                .foregroundStyle(.secondary)
            HStack(alignment: .top, spacing: 5) {
                Image(systemName: "mappin.circle.fill").foregroundStyle(.purple)
                Text("Pins are unverified references. Select one for coordinates and reported bands.")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.caption)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(selectedTower == nil ? "Measurement" : "Tower / cell reference").font(.headline)
                Spacer()
                if selectedTower != nil {
                    Button { selectedTowerID = nil } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                        .accessibilityLabel("Close tower details")
                }
            }
            if let tower = selectedTower {
                TMobileTowerMapInspector(pin: tower, measurementCoordinate: measurementCoordinate)
            } else if let reading = selectedReading {
                readingDetails(reading)
            } else {
                Label("No saved readings", systemImage: "waveform.path")
                Text("Start recording to build your measured heat map. Select any tower pin to inspect its coordinates.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Divider()
            coverageDetails
            Divider()
            towerList
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func readingDetails(_ reading: TMobileCoverageObservation) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(reading.date.formatted(date: .abbreviated, time: .standard)).font(.callout.weight(.medium))
            if let radio = reading.snapshot.primaryRadioLabel {
                Text("\(radio) · \(reading.primaryRadio?.bands.joined(separator: ", ") ?? "")")
                    .font(.callout).foregroundStyle(.secondary)
            }
            readingFact("Signal strength", reading.rsrp, unit: "dBm")
            readingFact("Signal quality", reading.sinr, unit: "dB")
            readingFact("Tested download", reading.downloadMbps, unit: "Mbps")
            if let coordinate = TMobileCoverageMapDrawing.coordinate(for: reading, metric: metric) {
                Text(String(format: "%.6f, %.6f", coordinate.latitude, coordinate.longitude))
                    .font(.caption.monospaced()).textSelection(.enabled)
                Text(metric == .speed ? "Recorded speed-test location" : reading.correction == nil ? "Recorded location" : "Manually corrected location")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("No mapped location for this reading").font(.caption).foregroundStyle(.secondary)
            }
            Button("Reading details & charts…", action: onReadingDetails).font(.callout)
        }
    }

    private func readingFact(_ label: String, _ value: Double?, unit: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value.map { "\($0.formatted(.number.precision(.fractionLength(0...1)))) \(unit)" } ?? "Unavailable")
                .monospacedDigit()
        }
        .font(.callout)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label): \(value.map { "\($0) \(unit)" } ?? "Unavailable")")
    }

    private var coverageDetails: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("FCC coverage", systemImage: "map.fill").font(.headline)
            if let layer = referenceOverlays.first {
                Text(verbatim: layer.title).font(.callout.weight(.medium))
                Text(verbatim: layer.provenance).font(.caption).foregroundStyle(.secondary)
                Text(hasModeledSignal ? "Blue shades show modeled minimum RSRP for each source polygon."
                     : "This layer provides coverage boundaries without signal values.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Outdoor / in-vehicle model. It does not describe indoor service or tower capacity.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Change coverage area…", action: onLoadCoverage)
            } else {
                Text("Load your area to see T-Mobile’s modeled coverage behind your readings.")
                    .font(.callout).foregroundStyle(.secondary)
                Button("Load FCC coverage…", action: onLoadCoverage).buttonStyle(.borderedProminent)
            }
        }
    }

    private var towerList: some View {
        LazyVStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Towers & cells", systemImage: "antenna.radiowaves.left.and.right").font(.headline)
                Spacer()
                Text("\(towers.count)").font(.caption).foregroundStyle(.secondary)
            }
            if towers.isEmpty {
                Text("Add a local reference file or look up community cell positions for the visible area.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            if towers.count > 12 || !towerQuery.isEmpty {
                TextField("Search name, band or cell ID", text: $towerQuery)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: towerQuery) { _, _ in towerListLimit = 12 }
            }
            ForEach(matchingTowers.prefix(towerListLimit)) { pin in
                Button {
                    showTowers = true
                    selectedTowerID = pin.id
                } label: {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: selectedTowerID == pin.id ? "mappin.circle.fill" : "mappin.circle")
                            .foregroundStyle(.purple)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(verbatim: pin.name).font(.callout.weight(.medium)).foregroundStyle(.primary)
                            Text(String(format: "%.5f, %.5f", pin.latitude, pin.longitude))
                                .font(.caption.monospaced()).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                    .background(selectedTowerID == pin.id ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.04),
                                in: RoundedRectangle(cornerRadius: 8))
                    .contentShape(Rectangle())
                }.buttonStyle(.plain)
            }
            if matchingTowers.count > towerListLimit {
                Text("Showing \(towerListLimit) of \(matchingTowers.count) references").font(.caption).foregroundStyle(.secondary)
                Button("Show next \(min(50, matchingTowers.count - towerListLimit)) references") { towerListLimit += 50 }
            } else if !towerQuery.isEmpty && matchingTowers.isEmpty {
                Text("No matching references").font(.caption).foregroundStyle(.secondary)
            }
            Button("Find nearby cell estimates…", action: onFindCells)
            Button("Manage tower references…", action: onManageTowers)
            if towers.contains(where: { $0.provenance?.localizedCaseInsensitiveContains("opencellid") == true }) {
                HStack(spacing: 8) {
                    Link("OpenCelliD", destination: TMobileTowerMapPresentation.openCellIDSource)
                    Link("CC BY-SA 4.0", destination: TMobileTowerMapPresentation.openCellIDLicense)
                }.font(.caption)
            }
        }
    }
}
