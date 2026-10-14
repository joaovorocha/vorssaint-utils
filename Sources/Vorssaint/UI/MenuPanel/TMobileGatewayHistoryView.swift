// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import Charts
import UniformTypeIdentifiers

struct TMobileGatewayHistoryView: View {
    private let onDone: (() -> Void)?
    private let showsHeader: Bool
    @ObservedObject private var store = TMobileGatewayHistoryStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var importing = false
    @State private var editingPin = false
    @State private var editingMeasurement = false
    @State private var metric = TMobileSignalMetric.rsrp
    @State private var useFiveG = true
    @State private var clearingHistory = false
    @State private var towerQuery = ""
    init(onDone: (() -> Void)? = nil, showsHeader: Bool = true) { self.onDone = onDone; self.showsHeader = showsHeader }
    private var visibleTowers: [TMobileTowerPin] {
        store.towers.filter { towerQuery.isEmpty || $0.name.localizedCaseInsensitiveContains(towerQuery)
            || $0.bands.localizedCaseInsensitiveContains(towerQuery) || ($0.cellID ?? "").localizedCaseInsensitiveContains(towerQuery)
            || ($0.nodeID.map(String.init) ?? "").localizedCaseInsensitiveContains(towerQuery)
            || ($0.ecgi ?? "").localizedCaseInsensitiveContains(towerQuery) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if showsHeader { HStack {
                Text("T-Mobile history & towers").font(.title2.bold())
                Spacer()
                Button("Done") { if let onDone { onDone() } else { dismiss() } }.keyboardShortcut(.cancelAction)
            } }
            Toggle("Record local signal history", isOn: $store.isRecording)
            Text("Saves one sample per minute while Shadow Utilities is running. Keeps up to 7 days / 10,000 readings on this Mac. No GPS, online tower lookup or uploads.")
                .font(.caption).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        Picker("Radio", selection: $useFiveG) { Text("5G").tag(true); Text("LTE / 4G").tag(false) }.pickerStyle(.segmented).frame(width: 210)
                        Picker("Metric", selection: $metric) { ForEach(TMobileSignalMetric.allCases, id: \.self) { Text($0.label).tag($0) } }.frame(width: 190)
                        Spacer()
                        Text("\(store.samples.count) readings").foregroundStyle(.secondary)
                    }
                    if store.samples.isEmpty {
                        ContentUnavailableView("No readings saved", systemImage: "chart.xyaxis.line", description: Text("Turn on recording to start a local history. Your live readings remain available without recording."))
                            .frame(height: 160)
                    } else {
                        Chart(Array(store.samples.suffix(240))) { sample in
                            if let value = value(sample) { PointMark(x: .value("Time", sample.date), y: .value(metric.unit, value)).symbolSize(12) }
                        }
                        .chartYAxisLabel("\(metric.label) (\(metric.unit))")
                        .frame(height: 170)
                        .accessibilityLabel("\(useFiveG ? "5G" : "LTE") \(metric.label) history")
                        Text("Chart shows the most recent 240 readings. Gaps or missing fields mean the gateway did not report a value.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Divider()
                    HStack {
                        Text("Local tower map").font(.headline)
                        Spacer()
                        Button("Import towers…") { importing = true }
                        Button("Add tower…") { editingPin = true }
                        Button("Measurement location…") { editingMeasurement = true }
                    }
                    Text("Offline coordinate map. Pins come from your file or manual entries. A nearby tower or matching label does not prove it is your connected tower.")
                        .font(.caption).foregroundStyle(.secondary)
                    TMobileOfflineTowerMap(towers: store.towers, samples: Array(store.samples.suffix(500)))
                    Text("CSV columns: name,latitude,longitude,bands,cellID. Optional extra columns: radio (LTE or NR), nodeID, ecgi, provenance. JSON accepts an array of the same fields; only name and coordinates are required. Import adds pins to your existing list.")
                        .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    TextField("Find a saved tower by name, band or identifier", text: $towerQuery).textFieldStyle(.roundedBorder)
                    if store.towers.count > 50 { Text("Showing the first 50 matching towers of \(store.towers.count) saved. Search to find another pin.").font(.caption) }
                    if let removed = store.removedTower { Button("Undo removal of \(removed.name)") { store.undoTowerRemoval() } }
                    if let coordinate = store.measurementCoordinate {
                        Text("New readings tagged at \(coordinate.latitude.formatted()), \(coordinate.longitude.formatted()) — entered manually.")
                            .font(.caption)
                        Button("Stop tagging new readings") { store.measurementCoordinate = nil }
                    }
                    ForEach(visibleTowers.prefix(50)) { tower in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Label(tower.name, systemImage: "antenna.radiowaves.left.and.right")
                                Spacer()
                                Text(tower.bands)
                                Button("Remove") { store.removeTower(tower) }.accessibilityLabel("Remove local tower \(tower.name)")
                            }
                            Text("Candidate · Location unverified · \(tower.provenance ?? "Local reference; source unspecified")").foregroundStyle(.secondary)
                            Text("\(tower.latitude.formatted()), \(tower.longitude.formatted())")
                            HStack(spacing: 10) {
                                if let radio = tower.radio { Text(radio.label) }
                                if let node = tower.nodeID { Text("Node ID \(node)") }
                                if let ecgi = tower.ecgi { Text("ECGI \(ecgi)") }
                                if let cid = tower.cellID { Text("Legacy reference \(cid)") }
                            }.monospacedDigit()
                        }.font(.caption).textSelection(.enabled)
                    }
                    if !store.samples.isEmpty {
                        Divider()
                        Text("Recent readings").font(.headline)
                        Button("Clear saved readings…", role: .destructive) { clearingHistory = true }
                        ForEach(store.samples.suffix(10).reversed()) { sample in
                            HStack {
                                Text(sample.date, style: .time)
                                Spacer()
                                Text(value(sample).map { "\($0.formatted(.number.precision(.fractionLength(0...1)))) \(metric.unit)" } ?? "Not reported")
                                Text((useFiveG ? sample.snapshot.fiveG : sample.snapshot.lte)?.bands.joined(separator: ", ") ?? "—")
                            }.font(.caption).monospacedDigit()
                        }
                    }
                }.padding(.trailing, 8)
            }
        }
        .padding(20).frame(minWidth: 740, idealWidth: 800, minHeight: 650, idealHeight: 780)
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json, .commaSeparatedText], allowsMultipleSelection: false) { result in
            if case .success(let urls) = result, let url = urls.first { store.importTowers(from: url) }
        }
        .sheet(isPresented: $editingPin) { TMobileCoordinateEditor(measurement: false) }
        .sheet(isPresented: $editingMeasurement) { TMobileCoordinateEditor(measurement: true) }
        .onAppear { store.prune() }
        .confirmationDialog("Clear all saved signal readings? Tower pins and the recording setting will remain.", isPresented: $clearingHistory, titleVisibility: .visible) {
            Button("Clear saved readings", role: .destructive) { store.clearHistory() }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Local data", isPresented: Binding(get: { store.errorMessage != nil }, set: { if !$0 { store.dismissError() } })) {
            Button("OK") { store.dismissError() }
        } message: { Text(store.errorMessage ?? "") }
    }

    private func value(_ sample: TMobileHistorySample) -> Double? {
        guard let radio = useFiveG ? sample.snapshot.fiveG : sample.snapshot.lte else { return nil }
        switch metric { case .rsrp: return radio.rsrp; case .rsrq: return radio.rsrq; case .rssi: return radio.rssi; case .sinr: return radio.sinr }
    }
}

private struct TMobileCoordinateEditor: View {
    let measurement: Bool
    @ObservedObject private var store = TMobileGatewayHistoryStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var latitude = ""
    @State private var longitude = ""
    @State private var bands = ""
    @State private var cellID = ""
    @State private var radio: TMobileTowerRadio?
    @State private var nodeID = ""
    @State private var ecgi = ""
    @State private var provenance = "Manual entry"
    private var parsedNodeID: UInt32? {
        guard !nodeID.isEmpty, nodeID.utf8.allSatisfy({ (48...57).contains($0) }) else { return nil }
        guard let value = UInt32(nodeID), radio != .lte || value <= 0x0FFF_FFFF else { return nil }
        return value
    }
    private var coordinate: TMobileMapCoordinate? {
        guard let lat = Double(latitude), let lon = Double(longitude) else { return nil }
        let value = TMobileMapCoordinate(latitude: lat, longitude: lon)
        return value.isValid ? value : nil
    }
    private var pin: TMobileTowerPin? {
        guard let coordinate else { return nil }
        guard nodeID.isEmpty || parsedNodeID != nil else { return nil }
        let pin = TMobileTowerPin(name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                                 latitude: coordinate.latitude, longitude: coordinate.longitude,
                                 bands: bands, cellID: cellID.isEmpty ? nil : cellID, radio: radio,
                                 nodeID: parsedNodeID, ecgi: ecgi.isEmpty ? nil : ecgi,
                                 provenance: provenance.isEmpty ? nil : provenance)
        return pin.isValid ? pin : nil
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(measurement ? "Tag future readings with a location" : "Add a local tower pin").font(.headline)
            if !measurement { TextField("Tower name", text: $name) }
            TextField("Latitude (−90 to 90)", text: $latitude)
            TextField("Longitude (−180 to 180)", text: $longitude)
            if !measurement {
                TextField("Bands (optional, e.g. n41, B66)", text: $bands)
                TextField("Cell ID reference (optional)", text: $cellID)
                Picker("Radio (optional)", selection: $radio) {
                    Text("Unspecified").tag(TMobileTowerRadio?.none)
                    ForEach(TMobileTowerRadio.allCases, id: \.self) { Text($0.label).tag(Optional($0)) }
                }
                TextField("\(radio?.nodeLabel ?? "Node ID") (optional decimal number)", text: $nodeID)
                TextField("ECGI (optional reported decimal/hex text)", text: $ecgi)
                TextField("Source / provenance (optional)", text: $provenance)
                Text("Select LTE or NR to compare explicit identifiers. Legacy Cell ID and bands remain reference labels. Location stays unverified.")
                    .font(.caption).foregroundStyle(.secondary)
                if !nodeID.isEmpty && parsedNodeID == nil { Text("Node ID must be a whole number from 0 to \(radio == .lte ? "268,435,455" : "4,294,967,295").").font(.caption) }
                if !ecgi.isEmpty && TMobileTowerReferenceSupport.canonicalECGI(ecgi) == nil { Text("Enter the reported decimal/hex identity text, up to 64 characters. Hyphens or colons may separate groups; keep its original format.").font(.caption) }
            }
            Text("Enter decimal coordinates. Stored only on this Mac. This does not request your device’s location.")
                .font(.caption).foregroundStyle(.secondary)
            if coordinate == nil && (!latitude.isEmpty || !longitude.isEmpty) { Text("Enter valid latitude and longitude numbers.").font(.caption) }
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save") {
                    if measurement { store.measurementCoordinate = coordinate }
                    else if let pin { store.addTower(pin) }
                    dismiss()
                }.disabled(measurement ? coordinate == nil : pin == nil).keyboardShortcut(.defaultAction)
            }
        }.textFieldStyle(.roundedBorder).padding(20).frame(width: 400)
        .onAppear {
            if measurement, let coordinate = store.measurementCoordinate {
                latitude = String(coordinate.latitude); longitude = String(coordinate.longitude)
            }
        }
    }
}

private struct TMobileOfflineTowerMap: View {
    let towers: [TMobileTowerPin]
    let samples: [TMobileHistorySample]
    @State private var zoom = 1.0
    @State private var offset = CGSize.zero
    @State private var dragStart = CGSize.zero
    private var coordinates: [TMobileMapCoordinate] { towers.map(\.coordinate) + samples.compactMap(\.coordinate) }
    private var bounds: (lat: Double, lon: Double, latSpan: Double, lonSpan: Double) {
        let points = coordinates
        let minLat = points.map(\.latitude).min() ?? -60, maxLat = points.map(\.latitude).max() ?? 60
        let minLon = points.map(\.longitude).min() ?? -150, maxLon = points.map(\.longitude).max() ?? 150
        return ((minLat + maxLat) / 2, (minLon + maxLon) / 2, max((maxLat-minLat)*1.2, 0.02), max((maxLon-minLon)*1.2, 0.02))
    }
    var body: some View {
        let extent = bounds
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Button("Zoom in") { zoom = min(zoom * 1.5, 64) }
                Button("Zoom out") { zoom = max(zoom / 1.5, 1) }
                Button("Fit all") { zoom = 1; offset = .zero; dragStart = .zero }
                Spacer()
                Text("▲ Tower   ● Saved reading").font(.caption)
            }
            GeometryReader { geometry in
                ZStack(alignment: .topLeading) {
                    Canvas { context, size in
                        var grid = Path()
                        for fraction in stride(from: 0.0, through: 1.0, by: 0.25) {
                            grid.move(to: CGPoint(x: size.width * fraction, y: 0)); grid.addLine(to: CGPoint(x: size.width * fraction, y: size.height))
                            grid.move(to: CGPoint(x: 0, y: size.height * fraction)); grid.addLine(to: CGPoint(x: size.width, y: size.height * fraction))
                        }
                        context.stroke(grid, with: .color(.secondary.opacity(0.2)), lineWidth: 1)
                        for coordinate in samples.compactMap(\.coordinate) {
                            let p = point(coordinate, size: size, extent: extent)
                            context.fill(Path(ellipseIn: CGRect(x: p.x-3, y: p.y-3, width: 6, height: 6)), with: .color(.blue))
                        }
                        for tower in towers {
                            let p = point(tower.coordinate, size: size, extent: extent)
                            var triangle = Path()
                            triangle.move(to: CGPoint(x: p.x, y: p.y - 5)); triangle.addLine(to: CGPoint(x: p.x - 5, y: p.y + 4)); triangle.addLine(to: CGPoint(x: p.x + 5, y: p.y + 4)); triangle.closeSubpath()
                            context.fill(triangle, with: .color(.orange))
                        }
                    }.accessibilityHidden(true)
                    ForEach(towers.prefix(50)) { tower in
                        let p = point(tower.coordinate, size: geometry.size, extent: extent)
                        VStack(spacing: 2) {
                            Image(systemName: "triangle.fill").foregroundStyle(.orange)
                            Text(tower.name).font(.caption2).padding(2).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 3))
                        }.position(p).help("\(tower.name): \(tower.latitude), \(tower.longitude). User supplied tower.")
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel("User supplied tower \(tower.name), latitude \(tower.latitude), longitude \(tower.longitude), bands \(tower.bands)")
                    }
                    if coordinates.isEmpty { Text("Add tower pins or a measurement location to plot your local data.").foregroundStyle(.secondary).padding(16) }
                    Text("N ↑").font(.caption.bold()).padding(8)
                }
                .background(.quaternary.opacity(0.25)).clipped()
                .gesture(DragGesture().onChanged { value in offset = CGSize(width: dragStart.width + value.translation.width, height: dragStart.height + value.translation.height) }.onEnded { _ in dragStart = offset })
                .accessibilityLabel("Offline coordinate map. Use Zoom in, Zoom out and Fit all. Tower coordinates are listed below.")
            }.frame(height: 260)
            Text("Center \(bounds.lat.formatted(.number.precision(.fractionLength(4))))° latitude, \(bounds.lon.formatted(.number.precision(.fractionLength(4))))° longitude. Latitude increases upward; longitude increases rightward. Coordinate plot, without streets or terrain.")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }
    private func point(_ coordinate: TMobileMapCoordinate, size: CGSize, extent: (lat: Double, lon: Double, latSpan: Double, lonSpan: Double)) -> CGPoint {
        CGPoint(x: size.width * (0.5 + (coordinate.longitude - extent.lon) / extent.lonSpan * zoom) + offset.width,
                y: size.height * (0.5 - (coordinate.latitude - extent.lat) / extent.latSpan * zoom) + offset.height)
    }
}
