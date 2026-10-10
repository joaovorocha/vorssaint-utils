// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import MapKit
import SwiftUI
import UniformTypeIdentifiers

struct TMobileCoverageWorkspaceView<RadioDetails: View>: View {
    @ObservedObject private var store = TMobileCoverageStore.shared
    @ObservedObject private var recorder = TMobileCoverageRecorder.shared
    @ObservedObject private var location = TMobileCoverageLocationService.shared
    @ObservedObject private var pins = TMobileGatewayHistoryStore.shared
    @ObservedObject private var references = TMobileCoverageReferenceStore.shared
    @ObservedObject private var gateway = TMobileGatewayMonitor.shared.service
    let close: () -> Void
    let radioDetails: () -> RadioDetails
    @Environment(\.colorScheme) private var colorScheme
    @State private var metric = TMobileCoverageMetric.sinr
    @State private var mode = TMobileCoverageMapMode.heat
    @State private var selectedID: UUID?
    @State private var sessionName = ""
    @State private var range = "all"
    @State private var latitude = ""
    @State private var longitude = ""
    @State private var importTowers = false
    @State private var importFCC = false
    @State private var editTower = false
    @State private var deletingSession = false
    @State private var fccDate = ""
    @State private var showFCC = true
    @State private var showTowers = true
    @State private var lookupRegion: MKCoordinateRegion?
    @State private var lookupCells: [TMobileTowerPin] = []
    @State private var localMessage: String?

    private var observations: [TMobileCoverageObservation] {
        guard range != "all", let last = store.observations.last?.date else { return store.observations }
        let cutoff = last.addingTimeInterval(range == "hour" ? -3_600 : -86_400)
        return store.observations.filter { $0.date >= cutoff }
    }
    private var selected: TMobileCoverageObservation? {
        observations.first { $0.id == selectedID } ?? observations.last
    }
    private var selection: Binding<UUID?> {
        Binding(get: { selected?.id }, set: { selectedID = $0 })
    }
    private var selectedSession: TMobileCoverageSession? { store.sessions.first { $0.id == store.selectedSessionID } }
    private var testRunning: Bool {
        switch recorder.speedPhase { case .latency, .download, .upload: return true; default: return false }
    }
    private var overlays: [TMobileCoverageMapReferenceOverlay] {
        guard showFCC, let layer = references.layer else { return [] }
        return [.init(id: layer.id, title: layer.title, provenance: "Imported FCC carrier-reported model · source declared by owner", polygons: layer.polygons)]
    }
    private struct MapReferenceKey: Hashable {
        let latitude: Double
        let longitude: Double
        let radio: String?
        let cellID: String?

        init(_ pin: TMobileTowerPin) {
            latitude = pin.latitude; longitude = pin.longitude
            radio = pin.radio?.rawValue; cellID = pin.cellID
        }
    }
    private var mapTowers: [TMobileTowerPin] {
        guard showTowers else { return [] }
        var seen = Set<MapReferenceKey>()
        return (pins.towers + lookupCells).filter { seen.insert(MapReferenceKey($0)).inserted }
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    status
                    mapAndInspector
                    if !observations.isEmpty {
                        TMobileCoverageChartsView(observations: observations, gaps: store.gaps, selectedObservationID: selection)
                    }
                    DisclosureGroup("All radio metrics & administrator readings") {
                        radioDetails().frame(minHeight: 320, idealHeight: 420, maxHeight: 500)
                    }
                    DisclosureGroup("Tower pins & reference coverage") { referenceControls.padding(.top, 8) }
                    DisclosureGroup("OpenCelliD lookup") {
                        TMobileOpenCellIDView(region: lookupRegion, onAreaResults: showOpenCellIDResults,
                                             onSaveResult: saveOpenCellID).padding(.top, 8)
                    }
                    DisclosureGroup("Saved sessions & analysis") { archiveControls.padding(.top, 8) }
                    if let message = localMessage { Text(message).font(.callout).foregroundStyle(.secondary) }
                }.padding(20)
            }
            Divider()
            HStack {
                Label("Saved on this Mac · Keep until deleted", systemImage: "internaldrive")
                Spacer()
                Label("Shadow server not connected", systemImage: "network.slash")
            }.font(.caption).foregroundStyle(.secondary).padding(12)
        }
        .frame(minWidth: 860, minHeight: 700)
        .onDisappear { lookupCells = []; lookupRegion = nil }
        .onChange(of: store.selectedSessionID) { _, _ in selectedID = nil; latitude = ""; longitude = "" }
        .onChange(of: selected?.id) { _, _ in latitude = ""; longitude = "" }
        .fileImporter(isPresented: $importTowers, allowedContentTypes: [.json, .commaSeparatedText]) { result in
            if case .success(let url) = result { pins.importTowers(from: url) }
        }
        .fileImporter(isPresented: $importFCC, allowedContentTypes: [.json, UTType(filenameExtension: "geojson") ?? .json]) { result in
            if case .success(let url) = result { references.importLayer(from: url, publishedDate: fccDate) }
        }
        .sheet(isPresented: $editTower) { TMobileCoordinateEditor(measurement: false) }
        .confirmationDialog("Delete this saved session and its measurements?", isPresented: $deletingSession, titleVisibility: .visible) {
            Button("Delete session", role: .destructive) {
                if let id = store.selectedSessionID { _ = store.deleteSession(id) }
            }
        }
    }

    private var toolbar: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Coverage", systemImage: "map").font(.title2.bold())
                Spacer()
                if recorder.isRecording {
                    Button("Stop recording") { recorder.stop() }.buttonStyle(.borderedProminent)
                } else {
                    TextField("Session name", text: $sessionName).textFieldStyle(.roundedBorder).frame(width: 170)
                    Button("Start recording") { recorder.start(name: sessionName.isEmpty ? "Coverage session" : sessionName) }
                        .buttonStyle(.borderedProminent)
                }
                Button("Done", action: close).keyboardShortcut(.cancelAction)
            }
            HStack {
                if !store.sessions.isEmpty {
                    Picker("Session", selection: Binding(get: { store.selectedSessionID }, set: { store.selectSession($0) })) {
                        ForEach(store.sessions) { session in
                            Text("\(session.name) · \(session.startedAt.formatted(date: .abbreviated, time: .shortened))").tag(Optional(session.id))
                        }
                    }.frame(maxWidth: 330)
                }
                Picker("Range", selection: $range) {
                    Text("Entire session").tag("all"); Text("Last hour").tag("hour"); Text("Last day").tag("day")
                }.frame(width: 180)
                Spacer()
                Picker("Map color", selection: $metric) {
                    ForEach(TMobileCoverageMetric.allCases) { Text($0.title).tag($0) }
                }.frame(width: 230)
            }
        }.padding(16)
    }

    private var status: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                Label(recorder.status, systemImage: recorder.isRecording ? "record.circle" : "pause.circle")
                Spacer()
                Text("\(observations.count) measurements").foregroundStyle(.secondary)
            }.font(.callout)
            HStack {
                Label(location.status, systemImage: "location")
                Spacer()
                Text(recorder.parkingStatus)
            }.font(.caption).foregroundStyle(.secondary)
            HStack {
                Toggle("Test speed automatically at new parked stops", isOn: $recorder.automaticParkedTestsEnabled)
                Spacer()
                Button(testRunning ? "Cancel test" : "Test speed") {
                    if testRunning { recorder.cancelSpeedTest() } else { recorder.runSpeedTest() }
                }.disabled(!recorder.isRecording && !testRunning)
            }.font(.callout)
            Text("Records while this app runs and the Mac is awake. Automatic tests wait for two minutes of stable, fresh location, with a 15-minute cooldown. Each Cloudflare test requests up to 20 MB down and 5 MB up and shares your network address with Cloudflare.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let error = store.errorMessage { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red).font(.callout) }
            if let error = references.errorMessage { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red).font(.callout) }
            if let error = pins.errorMessage { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red).font(.callout) }
        }
    }

    private var mapAndInspector: some View {
        HStack(alignment: .top, spacing: 18) {
            VStack(alignment: .leading, spacing: 10) {
                mapControls
                TMobileCoverageMapView(observations: observations, towers: mapTowers, referenceOverlays: overlays,
                                      metric: metric, displayMode: mode, selectedObservationID: selection,
                                      onRegionChanged: { lookupRegion = $0 })
                    .id(store.selectedSessionID)
                if !lookupCells.isEmpty { lookupAttribution }
                if observations.isEmpty {
                    Text("Start recording to save real readings. Grant Location Services when asked, or correct saved measurements manually.")
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
            inspector.frame(width: 260)
        }
    }

    private var lookupAttribution: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(lookupCells.count) community cell estimates · temporary map references, not confirmed towers")
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Link("OpenCellID", destination: TMobileOpenCellIDSupport.provider)
                Link("CC BY-SA 4.0", destination: TMobileOpenCellIDSupport.license)
            }
        }
        .font(.caption).foregroundStyle(.secondary)
    }

    private var mapControls: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 16) {
                displayControl
                Spacer(minLength: 0)
                referenceToggles
            }
            VStack(alignment: .leading, spacing: 10) {
                displayControl
                referenceToggles
            }
        }
        .font(.caption)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var displayControl: some View {
        HStack(spacing: 8) {
            Text("Display").fixedSize()
            Picker("Display", selection: $mode) {
                Text("Samples").tag(TMobileCoverageMapMode.samples)
                Text("Heat view").tag(TMobileCoverageMapMode.heat)
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(width: 190)
        }
        .fixedSize()
    }

    private var referenceToggles: some View {
        HStack(spacing: 12) {
            Toggle("Tower pins", isOn: $showTowers)
            if references.layer != nil { Toggle("FCC reference", isOn: $showFCC) }
        }
        .fixedSize()
    }

    private var inspector: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let sample = selected {
                Text(sample.date.formatted(date: .abbreviated, time: .standard)).font(.headline)
                if let radio = sample.snapshot.primaryRadioLabel {
                    Text("\(radio) · \(sample.primaryRadio?.bands.joined(separator: ", ") ?? "")").font(.callout).foregroundStyle(.secondary)
                }
                Text("Connection Score").font(.caption).foregroundStyle(.secondary)
                if let score = sample.connectionScore {
                    Text("\(score.formatted(.number.precision(.fractionLength(0)))) / 100").font(.title.bold()).monospacedDigit()
                        .foregroundStyle(TMobileCoverageMapDrawing.quality(value: score, metric: .score).presentationColor(for: colorScheme))
                } else {
                    Text(sample.speedTest == nil ? "Needs a matching speed test" : "Score unavailable: a precise location, matching signal and stable test are required.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                if let radio = sample.primaryRadio {
                    ForEach([TMobileSignalMetric.rsrp, .sinr], id: \.self) { metric in
                        if let row = TMobileGatewayRadioPresentation.measurementRow(radio, metric: metric) {
                            HStack { Text(row.label); Spacer(); Text(row.value).monospacedDigit() }
                                .foregroundStyle(row.quality.presentationColor(for: colorScheme))
                                // Keep the row's summary on its own AX element. A
                                // label inherited by selectable native text can
                                // recursively resolve itself after an update.
                                .accessibilityElement(children: .ignore)
                                .accessibilityLabel(row.accessibilityValue)
                        }
                    }
                }
                if let test = sample.speedTest {
                    LabeledContent("Download", value: "\(test.downloadMbps.formatted(.number.precision(.fractionLength(1)))) Mbps")
                        .foregroundStyle(TMobileCoverageMapDrawing.quality(value: test.downloadMbps, metric: .speed).presentationColor(for: colorScheme))
                    if let upload = test.uploadMbps { LabeledContent("Upload", value: "\(upload.formatted(.number.precision(.fractionLength(1)))) Mbps") }
                    if let latency = test.latencyMilliseconds { LabeledContent("Latency", value: "\(latency.formatted(.number.precision(.fractionLength(0)))) ms") }
                    Text("Tested \(test.endedAt.formatted(date: .omitted, time: .standard)) · \(test.provider)").font(.caption).foregroundStyle(.secondary)
                    if let reason = test.invalidationReason { Text(reason).font(.caption).foregroundStyle(.secondary) }
                }
                Divider()
                if let fix = sample.location {
                    Text("\(fix.source.title) · ±\(fix.horizontalAccuracy.formatted(.number.precision(.fractionLength(0)))) m").font(.caption)
                    Text("Fix age at reading: \(max(0, sample.date.timeIntervalSince(fix.timestamp)).formatted(.number.precision(.fractionLength(0)))) seconds").font(.caption).foregroundStyle(.secondary)
                } else { Text("No automatic location saved").font(.caption).foregroundStyle(.secondary) }
                if !sample.corrections.isEmpty { Text("Manual correction applied · original retained").font(.caption) }
                DisclosureGroup("Correct this location") {
                    VStack(spacing: 8) {
                        TextField("Latitude", text: $latitude)
                        TextField("Longitude", text: $longitude)
                        Button("Save correction") {
                            guard let lat = Double(latitude), let lon = Double(longitude) else { return }
                            _ = store.correctLocation(observationID: sample.id, coordinate: .init(latitude: lat, longitude: lon))
                        }.disabled(Double(latitude).flatMap { lat in Double(longitude).map { TMobileMapCoordinate(latitude: lat, longitude: $0).isValid } } != true)
                    }.textFieldStyle(.roundedBorder)
                }.font(.caption)
                DisclosureGroup("Available radio details") {
                    ForEach(TMobileGatewayRadioPresentation.sections(sample.snapshot)) { section in
                        Text(section.title).font(.headline)
                        ForEach(section.rows) { row in
                            if row.id == .bands || row.id == .supportedBands {
                                TMobileBandDetailRow(row: row,
                                                    bands: row.id == .bands ? section.radio.bands : section.radio.supportedBands ?? [],
                                                    isFiveG: section.id == "fiveG")
                            } else {
                                LabeledContent(row.label, value: row.value)
                                    .foregroundStyle(row.quality.presentationColor(for: colorScheme))
                                    .accessibilityElement(children: .ignore)
                                    .accessibilityLabel(row.accessibilityValue)
                            }
                        }
                    }
                }.font(.caption)
            } else {
                Label("Mac location", systemImage: "location").font(.headline)
                Text(location.status).font(.callout).foregroundStyle(.secondary)
                Button("Use Mac location") { recorder.useMacLocation() }
                if let snapshot = gateway.snapshot {
                    ForEach(TMobileGatewayRadioPresentation.sections(snapshot)) { section in
                        Text(section.title).font(.headline)
                        ForEach(section.rows.filter { [.rsrp, .sinr, .bands].contains($0.id) }) { row in
                            if row.id == .bands {
                                TMobileBandDetailRow(row: row, bands: section.radio.bands,
                                                    isFiveG: section.id == "fiveG")
                            } else {
                                LabeledContent(row.label, value: row.value)
                                    .foregroundStyle(row.quality.presentationColor(for: colorScheme))
                            }
                        }
                    }.font(.callout)
                }
            }
        }.font(.callout).textSelection(.enabled)
    }

    private var referenceControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Button("Import tower file…") { importTowers = true }; Button("Add tower pin…") { editTower = true } }
            Text("Local pins and OpenCelliD cell estimates are references, not proof of the serving tower. OpenCelliD positions remain unverified.")
                .font(.caption).foregroundStyle(.secondary)
            if let removed = pins.removedTower { Button("Undo removal of \(removed.name)") { pins.undoTowerRemoval() } }
            ForEach(pins.towers.prefix(30)) { pin in
                HStack {
                    VStack(alignment: .leading) { Text(pin.name); Text(pin.provenance ?? "Local reference · unverified").font(.caption).foregroundStyle(.secondary) }
                    Spacer(); Button("Remove") { pins.removeTower(pin) }.accessibilityLabel("Remove reference \(pin.name)")
                }
            }
            if pins.towers.count > 30 { Text("Showing 30 of \(pins.towers.count) references; all are saved.").font(.caption) }
            HStack {
                Link("OpenCelliD", destination: TMobileOpenCellIDSupport.provider)
                Link("CC BY-SA 4.0", destination: TMobileOpenCellIDSupport.license)
                Text("Cell positions · geometry unchanged").foregroundStyle(.secondary)
            }.font(.caption)
            Divider()
            Text("FCC reference coverage").font(.headline)
            Text("Import an area’s Polygon/MultiPolygon GeoJSON and enter its publication date. Coverage is a carrier-reported propagation model, separate from your measured signal. The file’s origin is declared by you; the app does not verify it against FCC.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                TextField("Dataset date · YYYY-MM-DD", text: $fccDate).textFieldStyle(.roundedBorder).frame(maxWidth: 240)
                Button("Import FCC GeoJSON…") { importFCC = true }.disabled(!TMobileCoverageReferenceSupport.validDate(fccDate))
                if references.layer != nil { Button("Remove reference") { references.removeLayer() } }
            }
            if let layer = references.layer { Text("\(layer.title) · \(layer.polygons.count) polygons").font(.caption) }
            HStack {
                Link("FCC coverage map", destination: URL(string: "https://broadbandmap.fcc.gov/")!)
                Link("FCC reference map", destination: URL(string: "https://fcc.maps.arcgis.com/apps/webappviewer/index.html?id=6c1b2e73d9d749cdb7bc88a0d1bdd25b")!)
                Link("AntennaSearch", destination: URL(string: "https://www.antennasearch.com/")!)
            }.font(.caption)
        }
    }

    private var archiveControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let session = selectedSession {
                if session.endedAt == nil, session.id != store.currentSessionID {
                    Label("Interrupted session · saved readings retained", systemImage: "exclamationmark.circle")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Text("\(session.observationCount) readings · \(session.speedTestCount) tests · \(session.gapCount) gaps").font(.callout)
                HStack {
                    Button("Export selected session…") { exportSession(session.id) }
                    Button("Delete selected session…", role: .destructive) { deletingSession = true }
                        .disabled(session.id == store.currentSessionID)
                }
                ForEach(store.gaps.suffix(10)) { gap in
                    Text("\(gap.startedAt.formatted(date: .abbreviated, time: .shortened)) · \(gap.reason.title)").font(.caption).foregroundStyle(.secondary)
                }
            }
            Text("Balanced score v1 averages normalized RSRP (−120 to −80 dBm), SINR (−5 to 25 dB), and tested download (0 to 150 Mbps). Values are capped at 0–100 before averaging. This is a custom comparison score; all raw readings remain available. No complete score is calculated without a matching test.")
                .font(.caption).foregroundStyle(.secondary)
            Text("Sessions stay until you delete them. Export contains locations and radio identifiers. The versioned export is ready for a future Shadow API; there is no uploader or configured server connection.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func showOpenCellIDResults(_ results: [TMobileOpenCellIDResult]) {
        if !results.isEmpty { showTowers = true }
        var seen = Set<MapReferenceKey>()
        lookupCells = results.map { result in
            TMobileTowerPin(name: "OpenCellID \(result.identity.radio.rawValue) cell estimate", latitude: result.latitude,
                           longitude: result.longitude, bands: "", cellID: String(result.identity.cellID),
                           radio: result.identity.radio == .nr ? .nr : .lte,
                           provenance: "OpenCellID CC BY-SA 4.0 · community cell estimate · not a confirmed tower")
        }.filter { $0.isValid && seen.insert(MapReferenceKey($0)).inserted }
    }

    private func saveOpenCellID(_ result: TMobileOpenCellIDResult) {
        var source = "OpenCelliD CC BY-SA 4.0 · \(Date().formatted(.iso8601.year().month().day())) · MCC \(result.identity.mcc) MNC \(result.identity.mnc) TAC \(result.identity.tac)"
        if let range = result.rangeMeters { source += " · estimated range \(String(format: "%.3g", range))m" }
        if let samples = result.samples { source += " · \(samples) samples" }
        let pin = TMobileTowerPin(name: "OpenCelliD \(result.identity.radio.rawValue) cell estimate", latitude: result.latitude,
                                 longitude: result.longitude, bands: "", cellID: String(result.identity.cellID),
                                 radio: result.identity.radio == .nr ? .nr : .lte, provenance: source)
        pins.addTower(pin)
        localMessage = pins.errorMessage ?? "OpenCelliD estimate saved to this Mac’s reference map."
    }

    private func exportSession(_ id: UUID) {
        do {
            let data = try store.exportSession(id)
            let panel = NSSavePanel(); panel.allowedContentTypes = [.json]; panel.nameFieldStringValue = "coverage-session.json"
            guard panel.runModal() == .OK, let url = panel.url else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            localMessage = "Session exported. Local measurements are retained."
        } catch { localMessage = "The session could not be exported. Check the chosen destination." }
    }
}
