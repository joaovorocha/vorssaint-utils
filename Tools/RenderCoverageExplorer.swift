// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import Foundation
import MapKit
import SwiftUI

/// Native production-view previews with synthetic fixtures only. No app stores,
/// preferences, gateway, credentials or FCC service are instantiated. MapKit may
/// fetch its public Sacramento basemap; user location is never requested.
@main @MainActor enum RenderCoverageExplorer {
    static func main() {
        setbuf(stdout, nil)
        do { try run() } catch {
            fputs("FAIL synthetic preview: \(String(describing: error))\n", stderr)
            exit(1)
        }
    }

    private static func run() throws {
        guard CommandLine.arguments.count == 2 else {
            print("Usage: RenderCoverageExplorer.sh OUTPUT_DIRECTORY")
            exit(2)
        }
        NSSetUncaughtExceptionHandler { exception in
            fputs("FAIL: uncaught AppKit exception \(exception.name.rawValue)\n", stderr)
            exit(1)
        }
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        NSApp.finishLaunching()
        let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let fixture = ExplorerFixture()
        guard fixture.observations.allSatisfy(\.isValid), fixture.towers.allSatisfy(\.isValid) else {
            throw PreviewFailure.invalidFixture
        }
        let bins = TMobileCoverageMapDrawing.bins(observations: fixture.observations, metric: .rsrp)
        let qualities = Set(bins.map { TMobileCoverageMapDrawing.quality(value: $0.median, metric: .rsrp) })
        guard qualities.contains(.good), qualities.contains(.fair), qualities.contains(.poor),
              fixture.overlay.polygons[1].count == 2,
              fixture.overlay.modeledSignalDBm == [-115, -100, -85] else { throw PreviewFailure.invalidFixture }
        var manifest = ["A capture PASS covers bounds/PNG generation/native map assertions; it does not override an AX UNVERIFIED result.","Synthetic fixtures only; no production app state or account access.",
                        "Production Explorer, map renderer and tower inspector; surrounding chrome is a fixture.",
                        "\(fixture.observations.count) synthetic readings; \(bins.count) actual 50 m bins; \(fixture.towers.count) synthetic references."]
        for size in [NSSize(width: 860, height: 700), NSSize(width: 1180, height: 820)] {
            for dark in [false, true] {
                for variant in PreviewVariant.allCases {
                    let name = "coverage-explorer-\(variant.rawValue)-\(Int(size.width))x\(Int(size.height))-\(dark ? "dark" : "light").png"
                    let onScreen = variant == .towerNR && size.width == 860 && !dark
                    let result = try render(fixture: fixture, variant: variant, size: size, dark: dark,
                                             onScreen: onScreen, output: output.appendingPathComponent(name))
                    manifest.append("PASS \(name): exact host bounds; map within host; \(result.axCount) native AX nodes read (\(result.axStatus)); \(result.mapSummary); native AppKit capture completed.\(onScreen ? " One bounded nonactivating on-screen capture attempt." : " Offscreen capture.")")
                    print("PASS \(name): \(result.mapSummary); AX \(result.axStatus) (\(result.axCount) nodes)")
                }
            }
        }
        manifest.append("LIMITATION: Native cacheDisplay can omit MapKit GPU-rendered tiles, overlays and annotations. PNG generation and AX traversal do not establish that these pixels were captured; inspect rendered images separately.")
        try (manifest.joined(separator: "\n") + "\n").write(
            to: output.appendingPathComponent("preview-manifest.txt"), atomically: true, encoding: .utf8)
        print("PASS \(PreviewVariant.allCases.count * 4) production Explorer captures and native map assertions; consult manifest for AX availability; no uncaught AppKit exception")
    }

    private static func render(fixture: ExplorerFixture, variant: PreviewVariant,
                               size: NSSize, dark: Bool, onScreen: Bool, output: URL) throws -> (axCount: Int, axStatus: String, mapSummary: String) {
        let content = ExplorerPreviewChrome(fixture: fixture, variant: variant)
            .frame(width: size.width, height: size.height)
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, dark ? .dark : .light)
        let host = NSHostingView(rootView: content)
        let origin = onScreen ? NSPoint(x: 40, y: 80) : NSPoint(x: -10_000, y: -10_000)
        let window = NSWindow(contentRect: NSRect(origin: origin, size: size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = host
        window.orderFrontRegardless()
        defer { window.orderOut(nil); window.close() }
        host.layoutSubtreeIfNeeded()
        // Give the native map's asynchronous region/layout and public tiles a
        // bounded run-loop opportunity. This is not a live-data fetch workflow.
        RunLoop.main.run(until: Date().addingTimeInterval(onScreen ? 5 : 1.5))
        host.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        guard abs(host.bounds.width - size.width) < 0.5,
              abs(host.bounds.height - size.height) < 0.5,
              abs(host.fittingSize.width - size.width) < 0.5,
              abs(host.fittingSize.height - size.height) < 0.5 else { throw PreviewFailure.invalidBounds }
        let maps = descendants(host).compactMap { $0 as? MKMapView }
        guard maps.count == 1 else { throw PreviewFailure.invalidBounds }
        for map in maps {
            let bounds = host.convert(map.bounds, from: map)
            guard bounds.width.isFinite, bounds.height.isFinite, bounds.width > 0, bounds.height >= 220,
                  host.bounds.contains(bounds.insetBy(dx: 0.5, dy: 0.5)) else { throw PreviewFailure.invalidBounds }
        }
        let mapSummary = try validateNativeMap(maps[0], fixture: fixture, variant: variant)
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw PreviewFailure.invalidRender }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { throw PreviewFailure.invalidRender }
        try png.write(to: output, options: .atomic)
        let accessibility = try readAccessibility(host)
        try accessibility.lines.joined(separator: "\n").write(
            to: output.deletingPathExtension().appendingPathExtension("ax.txt"), atomically: true, encoding: .utf8)
        let axStatus = try validateAccessibility(accessibility.lines, count: accessibility.count, variant: variant)
        return (accessibility.count, axStatus, mapSummary)
    }

    private static func descendants(_ view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants($0) }
    }
    /// Read only the native AX tree of our own synthetic host. A separate queue
    /// watchdog also fails the process if an accessibility getter recurses/hangs.
    private static func readAccessibility(_ host: NSView) throws -> (count: Int, lines: [String]) {
        let watchdog = DispatchSource.makeTimerSource(queue: .global(qos: .userInitiated))
        watchdog.schedule(deadline: .now() + 5)
        watchdog.setEventHandler { fputs("FAIL: synthetic native AX traversal exceeded 5 seconds\n", stderr); exit(1) }
        watchdog.resume()
        defer { watchdog.cancel() }
        var pending: [(NSObject, Int)] = [(host, 0)], visited = Set<ObjectIdentifier>(), lines: [String] = []
        let started = ProcessInfo.processInfo.systemUptime
        func value(_ object: NSObject, _ name: String) -> Any? {
            let selector = NSSelectorFromString(name)
            guard object.responds(to: selector) else { return nil }
            return object.perform(selector)?.takeUnretainedValue()
        }
        func text(_ value: Any?) -> String {
            if let string = value as? String { return String(string.prefix(4_096)).replacingOccurrences(of: "\n", with: " ") }
            if let number = value as? NSNumber { return number.stringValue }
            return ""
        }
        while !pending.isEmpty {
            guard visited.count < 2_000, ProcessInfo.processInfo.systemUptime - started < 5 else { throw PreviewFailure.invalidAccessibility }
            let (object, depth) = pending.removeLast()
            guard visited.insert(ObjectIdentifier(object)).inserted else { continue }
            guard depth <= 32 else { throw PreviewFailure.invalidAccessibility }
            let role = text(value(object, "accessibilityRole"))
            let label = text(value(object, "accessibilityLabel"))
            let scalar = text(value(object, "accessibilityValue"))
            let roleDescription = text(value(object, "accessibilityRoleDescription"))
            let placeholder = text(value(object, "accessibilityPlaceholderValue"))
            // AXDescription was the former recursion trigger. Query it only
            // when this own-process element exposes the legacy object getter.
            let legacy = NSSelectorFromString("accessibilityAttributeValue:")
            let description = object.responds(to: legacy)
                ? text(object.perform(legacy, with: "AXDescription")?.takeUnretainedValue()) : ""
            lines.append("\(depth) | \(role) | \(label) | \(scalar) | \(roleDescription) | \(description) | \(placeholder)")
            let direct = value(object, "accessibilityChildren") as? [Any] ?? []
            let children = direct.isEmpty
                ? value(object, "accessibilityChildrenInNavigationOrder") as? [Any] ?? [] : direct
            guard children.count <= 512 else { throw PreviewFailure.invalidAccessibility }
            for child in children.reversed() {
                if let child = child as? NSObject { pending.append((child, depth + 1)) }
            }
        }
        return (visited.count, lines)
    }

    private static func validateAccessibility(_ lines: [String], count: Int, variant: PreviewVariant) throws -> String {
        let all = lines.joined(separator: "\n")
        guard count > 1 else {
            return "UNVERIFIED: native own-process host exposed no AX children; inspector recursion check unavailable"
        }
        guard all.contains("SYNTHETIC PREVIEW") else { throw PreviewFailure.invalidAccessibility }
        let expected: [String]
        switch variant {
        case .towerNR, .towerLTE, .community: expected = ["Latitude", "Longitude", "Technology"]
        case .measurement: expected = ["Signal strength", "Recorded location"]
        case .empty: expected = ["No saved readings"]
        case .many: expected = []
        }
        let missing = expected.filter { !all.contains($0) }
        guard missing.isEmpty else {
            print("FAIL AX: missing expected labels \(missing.joined(separator: ", "))")
            throw PreviewFailure.invalidAccessibility
        }
        if variant == .many {
            return "PASS bounded native traversal; search present=\(all.localizedCaseInsensitiveContains("search")); paging present=\(all.localizedCaseInsensitiveContains("show next")) (lazy offscreen controls may be unavailable)"
        }
        return "PASS bounded native traversal and expected inspector labels"
    }

    private static func validateNativeMap(_ map: MKMapView, fixture: ExplorerFixture,
                                          variant: PreviewVariant) throws -> String {
        let polygons = map.overlays.compactMap { $0 as? MKPolygon }
        let circles = map.overlays.compactMap { $0 as? MKCircle }
        let measured = map.overlays.filter { String(describing: type(of: $0)) == "MeasuredBinOverlay" }
        let bins = TMobileCoverageMapDrawing.bins(observations: fixture.observations, metric: .rsrp)
        let towerCount = variant == .many ? fixture.manyTowers.count : fixture.towers.count
        // Explorer hides the reading selection when a tower inspector is open.
        let readingSelectionCount = variant == .measurement ? 1 : 0
        if variant == .empty {
            guard map.overlays.isEmpty, map.annotations.isEmpty else { throw PreviewFailure.invalidNativeMap }
            return "0 native overlays / 0 annotations"
        }
        guard polygons.count == 3, measured.count == bins.count, circles.count == readingSelectionCount,
              map.overlays.count == 3 + bins.count + readingSelectionCount,
              map.annotations.count == bins.count + towerCount + readingSelectionCount,
              polygons.filter({ ($0.interiorPolygons ?? []).count == 1 }).count == 1 else {
            print("FAIL native map: polygons=\(polygons.count), bins=\(measured.count), circles=\(circles.count), annotations=\(map.annotations.count)")
            throw PreviewFailure.invalidNativeMap
        }
        var ready = 0, colorsChecked = 0
        for (index, polygon) in polygons.enumerated() {
            let native = map.renderer(for: polygon)
            if native != nil { ready += 1 }
            let renderer = native ?? map.delegate?.mapView?(map, rendererFor: polygon)
            guard let renderer = renderer as? MKPolygonRenderer,
                  let color = renderer.fillColor?.usingColorSpace(.sRGB),
                  let expected = TMobileCoverageMapDrawing.referenceColor(modeledSignalDBm: fixture.overlay.modeledSignalDBm?[index]).usingColorSpace(.sRGB),
                  abs(color.redComponent - expected.redComponent) < 0.0001,
                  abs(color.greenComponent - expected.greenComponent) < 0.0001,
                  abs(color.blueComponent - expected.blueComponent) < 0.0001,
                  abs(color.alphaComponent - expected.alphaComponent) < 0.0001 else {
                print("FAIL native model color at component \(index): renderer ready=\(native != nil)")
                throw PreviewFailure.invalidNativeMap
            }
            colorsChecked += 1
        }
        let readyBins = measured.filter { map.renderer(for: $0) != nil }.count
        return "\(polygons.count) model polygons (1 hole), \(measured.count) measured overlays, \(towerCount) tower + \(bins.count + readingSelectionCount) measurement annotations; \(colorsChecked) model colors checked; native renderers ready \(ready)/3 model + \(readyBins)/\(bins.count) measured"
    }
    private enum PreviewFailure: Error { case invalidFixture, invalidBounds, invalidRender, invalidAccessibility, invalidNativeMap }
}

private enum PreviewVariant: String, CaseIterable {
    case towerNR = "tower-nr", towerLTE = "tower-lte", community, measurement, empty, many = "many-references"
}

/// Only the center content is production UI. This bounded fixture recreates the
/// workspace's three toolbar rows and footer without touching its live stores.
private struct ExplorerPreviewChrome: View {
    let fixture: ExplorerFixture
    let variant: PreviewVariant
    @State private var metric = TMobileCoverageMetric.rsrp
    @State private var mode = TMobileCoverageMapMode.heat
    @State private var selectedObservationID: UUID?
    @State private var selectedTowerID: UUID?
    @State private var showsMeasurements = true
    @State private var showTowers = true
    @State private var showFCC = true

    init(fixture: ExplorerFixture, variant: PreviewVariant) {
        self.fixture = fixture; self.variant = variant
        _selectedObservationID = State(initialValue: variant == .empty ? nil : fixture.observations[5].id)
        let tower: UUID?
        switch variant {
        case .towerNR: tower = fixture.towers[0].id
        case .towerLTE: tower = fixture.towers[1].id
        case .community: tower = fixture.towers[2].id
        case .many: tower = fixture.manyTowers.last?.id
        case .measurement, .empty: tower = nil
        }
        _selectedTowerID = State(initialValue: tower)
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label("Coverage", systemImage: "map").font(.title2.bold())
                    Text("SYNTHETIC PREVIEW").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Spacer()
                    Button("Start recording") {}.buttonStyle(.borderedProminent).disabled(true)
                    Button("Done") {}.disabled(true)
                }
                HStack {
                    Text("Session").font(.callout)
                    Text("Sacramento · synthetic fixtures").font(.callout).padding(.horizontal, 8)
                        .frame(width: 250, height: 24, alignment: .leading).background(.quaternary, in: RoundedRectangle(cornerRadius: 5))
                    Text("Entire session").font(.callout).frame(width: 150, height: 24)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 5))
                    Spacer()
                }
                HStack {
                    Picker("View", selection: .constant("Map")) {
                        Text("Map").tag("Map"); Text("Readings & charts").tag("Readings & charts")
                        Text("Data & settings").tag("Data & settings")
                    }.labelsHidden().pickerStyle(.segmented).frame(width: 350)
                    Spacer(minLength: 8)
                    Label("Recording paused", systemImage: "pause.circle").foregroundStyle(.secondary)
                    Text("\(variant == .empty ? 0 : fixture.observations.count) fixture readings").foregroundStyle(.secondary)
                }.font(.caption)
            }.padding(16)
            Divider()
            TMobileCoverageExplorerView(
                observations: variant == .empty ? [] : fixture.observations,
                towers: variant == .empty ? [] : variant == .many ? fixture.manyTowers : fixture.towers,
                referenceOverlays: variant == .empty ? [] : [fixture.overlay],
                metric: $metric, displayMode: $mode,
                selectedObservationID: $selectedObservationID, selectedTowerID: $selectedTowerID,
                showsMeasurements: $showsMeasurements, showTowers: $showTowers, showFCC: $showFCC,
                initialRegion: fixture.region)
            Divider()
            HStack {
                Label("Fixture chrome · MapKit GPU pixels unverified", systemImage: "internaldrive")
                Spacer()
                Label("No production stores connected", systemImage: "network.slash")
            }.font(.caption).foregroundStyle(.secondary).padding(12)
        }
    }
}

private struct ExplorerFixture {
    let observations: [TMobileCoverageObservation]
    let towers: [TMobileTowerPin]
    let overlay: TMobileCoverageMapReferenceOverlay
    let region = MKCoordinateRegion(center: .init(latitude: 38.581, longitude: -121.4905),
                                    span: .init(latitudeDelta: 0.017, longitudeDelta: 0.026))
    var manyTowers: [TMobileTowerPin] {
        towers + (0..<15).map { index in
            TMobileTowerPin(id: Self.id(50 + index), name: "Synthetic additional reference \(index + 4)",
                latitude: 38.5768 + Double(index / 5) * 0.0005, longitude: -121.499 + Double(index % 5) * 0.0015,
                bands: index.isMultiple(of: 2) ? "b2, b66" : "n41", cellID: nil,
                radio: index.isMultiple(of: 2) ? .lte : .nr, provenance: "Synthetic paging fixture · not a real site")
        }
    }

    init() {
        let epoch = Date(timeIntervalSince1970: 1_791_662_400)
        let groups: [(Double, Double, Double, Double, Double)] = [
            (38.5798, -121.4855, -92, 18, 190), (38.5784, -121.4921, -101, 6, 62),
            (38.5825, -121.4974, -118, -3, 7)
        ]
        observations = groups.enumerated().flatMap { group, value in
            (0..<12).map { index in
                let date = epoch.addingTimeInterval(Double(group * 12 + index) * 30)
                let coordinate = TMobileMapCoordinate(latitude: value.0 + Double(index / 4) * 0.00055,
                                                       longitude: value.1 + Double(index % 4) * 0.00070)
                let fix = TMobileCoverageLocationFix(coordinate: coordinate, timestamp: date, horizontalAccuracy: 18, source: .mac)
                let start = TMobileCoverageLocationFix(coordinate: coordinate, timestamp: date.addingTimeInterval(-12),
                                                       horizontalAccuracy: 18, source: .mac)
                let radio = TMobileRadioSignal(bars: group == 0 ? 4 : group == 1 ? 2 : 1,
                    bands: ["n41"], rsrp: value.2, rsrq: -12, rssi: nil, sinr: value.3)
                let snapshot = TMobileGatewaySnapshot(model: nil, firmware: nil, uptime: nil,
                    registration: "registered", roaming: false, lte: nil, fiveG: radio)
                let speed = TMobileCoverageSpeedResult(id: Self.id(200 + group * 12 + index),
                    startedAt: start.timestamp, endedAt: date, startLocation: start, endLocation: fix,
                    downloadMbps: value.4, uploadMbps: 12, latencyMilliseconds: 28, provider: "Synthetic fixture")
                return TMobileCoverageObservation(id: Self.id(100 + group * 12 + index), date: date,
                    snapshot: snapshot, location: fix, speedTest: speed)
            }
        }
        towers = [
            .init(id: Self.id(1), name: "Synthetic NR reference", latitude: 38.5834, longitude: -121.4848,
                  bands: "n41, n71", cellID: nil, radio: .nr, provenance: "Synthetic local reference · not a real site"),
            .init(id: Self.id(2), name: "Synthetic LTE reference", latitude: 38.5832, longitude: -121.4990,
                  bands: "b2, b66", cellID: nil, radio: .lte, provenance: "Synthetic local reference · not a real site"),
            .init(id: Self.id(3), name: "Synthetic community cell", latitude: 38.5778, longitude: -121.4886,
                  bands: "", cellID: nil, radio: .nr, provenance: "OpenCelliD · synthetic fixture, not an actual database result")
        ]
        func ring(_ west: Double, _ south: Double, _ east: Double, _ north: Double) -> [TMobileMapCoordinate] {
            [(west, south), (east, south), (east, north), (west, north), (west, south)]
                .map { .init(latitude: $0.1, longitude: $0.0) }
        }
        overlay = .init(id: Self.id(10), title: "Synthetic FCC model · 5G-NR 35/3 Mbps",
            provenance: "Synthetic polygons only · modeled outdoor coverage example · no actual FCC file loaded",
            polygons: [[ring(-121.501, 38.576, -121.494, 38.586)],
                       [ring(-121.494, 38.576, -121.487, 38.586), ring(-121.492, 38.580, -121.489, 38.583)],
                       [ring(-121.487, 38.576, -121.480, 38.586)]],
            modeledSignalDBm: [-115, -100, -85])
    }

    private static func id(_ value: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", value))!
    }
}
