// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import AppKit
import MapKit

enum TMobileCoverageMapMode: String, CaseIterable, Identifiable {
    case samples, heat
    var id: String { rawValue }
    var title: String { self == .samples ? "Samples" : "Measured bins" }
}

/// A locally imported reference layer. Rings are outer boundary followed by holes.
/// The map does not fetch or infer coverage, source dates, or carrier identities.
struct TMobileCoverageMapReferenceOverlay: Identifiable, Equatable {
    let id: UUID
    let title: String
    let provenance: String
    let publishedAt: Date?
    let polygons: [[[TMobileMapCoordinate]]]
    /// Optional source minsignal values, aligned with complete polygon components.
    /// A missing value is a modeled footprint, not a measured signal value.
    let modeledSignalDBm: [Double?]?

    init(id: UUID = UUID(), title: String, provenance: String, publishedAt: Date? = nil,
         polygons: [[[TMobileMapCoordinate]]], modeledSignalDBm: [Double?]? = nil) {
        self.id = id; self.title = title; self.provenance = provenance
        self.publishedAt = publishedAt; self.polygons = polygons
        self.modeledSignalDBm = modeledSignalDBm
    }
}

/// Apple Maps is the basemap; only recorded positions receive a point or a bin.
/// A bin is a 50 m map grid summary, never an interpolated coverage prediction.
struct TMobileCoverageMapView: View {
    let observations: [TMobileCoverageObservation]
    let towers: [TMobileTowerPin]
    var referenceOverlays: [TMobileCoverageMapReferenceOverlay] = []
    let metric: TMobileCoverageMetric
    let displayMode: TMobileCoverageMapMode
    @Binding var selectedObservationID: UUID?
    var selectedTowerID: UUID? = nil
    var onTowerSelected: ((UUID) -> Void)? = nil
    var showsMeasurements: Bool = true
    var canvasHeight: CGFloat = 320
    var showsExplanations: Bool = true
    var showsHeader: Bool = true
    var initialRegion: MKCoordinateRegion? = nil
    var onRegionChanged: ((MKCoordinateRegion) -> Void)? = nil
    @State private var fitRequest = 0

    private var located: [TMobileCoverageObservation] {
        TMobileCoverageMapDrawing.positionedObservations(observations, metric: metric, selectedID: selectedObservationID)
    }
    private var allBins: [TMobileCoverageMapDrawing.Bin] {
        TMobileCoverageMapDrawing.bins(observations: located, metric: metric)
    }
    private var drawingCount: Int {
        displayMode == .samples
            ? min(located.count, TMobileCoverageMapDrawing.maximumSamples)
            : min(allBins.count, TMobileCoverageMapDrawing.maximumBins)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if showsHeader { mapHeader }
            TMobileCoverageNativeMap(observations: observations, towers: towers,
                                     referenceOverlays: referenceOverlays, metric: metric,
                                     displayMode: displayMode, fitRequest: fitRequest,
                                     selectedObservationID: $selectedObservationID,
                                     selectedTowerID: selectedTowerID, onTowerSelected: onTowerSelected,
                                     showsMeasurements: showsMeasurements,
                                     initialRegion: initialRegion,
                                     onRegionChanged: onRegionChanged)
                // Bound only the canvas. The header and explanations must
                // contribute their full height to the surrounding ScrollView.
                .frame(height: canvasHeight.isFinite && canvasHeight > 0 ? canvasHeight : 320)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay {
                    if (!showsMeasurements || located.isEmpty) && towers.isEmpty && referenceOverlays.isEmpty {
                        VStack(spacing: 6) {
                            Image(systemName: "location.slash").font(.title2)
                            Text(!showsMeasurements ? "No reference layers" : metric == .speed ? "No mapped speed tests" : "No saved locations").font(.headline)
                            Text(!showsMeasurements ? "Show measured readings, add tower references, or import FCC modeled coverage."
                                 : metric == .speed
                                 ? "A speed test appears here when it has fresh, precise recorded positions and a stable location context."
                                 : "Record with Mac Location Services or correct a saved reading’s location.")
                                .font(.caption).multilineTextAlignment(.center)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(18).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                        .padding(24).allowsHitTesting(false)
                    }
                }
            if showsExplanations {
                if showsMeasurements {
                    HStack(spacing: 12) {
                        legend("Good", color: .green, symbol: "checkmark.circle.fill")
                        legend("Fair", color: .orange, symbol: "minus.circle.fill")
                        legend("Poor", color: .red, symbol: "exclamationmark.circle.fill")
                        if displayMode == .samples { legend("No value", color: .secondary, symbol: "circle") }
                    }.font(.caption).fixedSize(horizontal: false, vertical: true)
                    Text(displayMode == .heat
                         ? "Each colored bin contains actual readings and shows their median in an approximately 50 m grid. Unvisited bins have no measured coverage; this layer does not interpolate."
                         : "Points show saved locations. Gray points have no value for this metric. Select a point or use the readings list.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Colors are app guidance for the selected metric, not carrier ratings or predicted coverage.")
                        .font(.caption2).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Stale or imprecise reported positions are omitted. Manual corrections remain explicit. Speed uses the test’s recorded location and appears only when its location context is valid.")
                        .font(.caption2).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if selectedObservationID != nil {
                        Text("Dashed ring: recorded position accuracy, not a cellular coverage radius. Dashed connector: manual correction, not a traveled route.")
                            .font(.caption2).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if !towers.isEmpty || !referenceOverlays.isEmpty {
                    Text("Antenna pins are source references with unverified locations. Blue filled areas are imported FCC modeled coverage, separate from measured readings.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var mapHeader: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                mapTitle
                Spacer(minLength: 0)
                drawingSummary
                fitButton
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    mapTitle
                    Spacer(minLength: 0)
                    fitButton
                }
                drawingSummary
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var mapTitle: some View {
        Label("Apple Maps", systemImage: "map")
            .font(.caption.weight(.semibold))
            .fixedSize()
    }

    private var drawingSummary: some View {
        Text(!showsMeasurements ? "Reference layers"
             : displayMode == .samples
             ? "\(drawingCount) of \(located.count) located readings drawn"
             : "\(drawingCount) of \(allBins.count) measured bins drawn")
            .font(.caption).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var fitButton: some View {
        Button("Fit all") { fitRequest += 1 }
            .help("Fit visible readings, tower references, and modeled coverage")
            .fixedSize()
    }

    private func legend(_ title: String, color: Color, symbol: String) -> some View {
        Label { Text(title) } icon: { Image(systemName: symbol).foregroundStyle(color) }
    }
}

enum TMobileCoverageMapDrawing {
    static let maximumSamples = 2_000
    static let maximumBins = 2_000
    static let gridMetres = 50.0

    static func validInitialRegion(_ region: MKCoordinateRegion?) -> Bool {
        guard let region else { return false }
        return region.center.latitude.isFinite && (-90...90).contains(region.center.latitude)
            && region.center.longitude.isFinite && (-180...180).contains(region.center.longitude)
            && region.span.latitudeDelta.isFinite && region.span.latitudeDelta > 0 && region.span.latitudeDelta <= 180
            && region.span.longitudeDelta.isFinite && region.span.longitudeDelta > 0 && region.span.longitudeDelta <= 360
    }

    static func fitRect(positions: [TMobileMapCoordinate], measuredRects: [MKMapRect], referenceRects: [MKMapRect],
                        includesAllLayers: Bool) -> MKMapRect {
        var rect = MKMapRect.null
        for coordinate in positions where coordinate.isValid {
            let point = MKMapPoint(CLLocationCoordinate2D(latitude: coordinate.latitude, longitude: coordinate.longitude))
            rect = rect.union(MKMapRect(x: point.x, y: point.y, width: 1, height: 1))
        }
        for measured in measuredRects { rect = rect.union(measured) }
        // Complete FCC components can extend well beyond the imported area.
        // Start near actual positions, then let an explicit Fit all include them.
        if includesAllLayers || rect.isNull {
            for reference in referenceRects { rect = rect.union(reference) }
        }
        return rect
    }

    enum SelectionTarget: Equatable {
        case reading(UUID), tower(UUID)
    }

    /// Unchanged controlled IDs must not steal a native selection or move the camera
    /// when a new reading arrives. Explicit changes choose the corresponding pin.
    static func selectionTarget(previousReading: UUID?, previousTower: UUID?, reading: UUID?, tower: UUID?,
                                current: SelectionTarget?) -> SelectionTarget? {
        if tower != previousTower, let tower { return .tower(tower) }
        if reading != previousReading, let reading { return .reading(reading) }
        if case .tower(let id) = current, tower != previousTower, tower != id { return nil }
        if case .reading(let id) = current, reading != previousReading, reading != id { return nil }
        return current
    }

    struct TowerPresentation {
        let title: String
        let subtitle: String
        let detail: String

        init(pin: TMobileTowerPin) {
            let technology = pin.radio == .nr ? "5G NR" : pin.radio == .lte ? "LTE" : "Radio unspecified"
            title = "\(technology) · \(pin.name)"
            subtitle = "Reference · Location unverified"
            let coordinates = String(format: "%.5f, %.5f", locale: Locale(identifier: "en_US_POSIX"),
                                     pin.latitude, pin.longitude)
            detail = "\(pin.provenance ?? "Local reference; source unspecified")\nReported coordinates: \(coordinates)"
        }
    }

    static func referenceColor(modeledSignalDBm value: Double?) -> NSColor {
        guard let value, value.isFinite, (-120 ... -50).contains(value) else {
            return NSColor.systemBlue.withAlphaComponent(0.24)
        }
        let strength = (value + 120) / 70
        // Source model values use only blue. Measured quality uses green/amber/red.
        return NSColor(srgbRed: 0.30 - 0.26 * strength, green: 0.65 - 0.38 * strength,
                       blue: 1.0 - 0.15 * strength, alpha: 0.26)
    }

    final class ReferenceGeometryCache {
        private var layers: [TMobileCoverageMapReferenceOverlay] = []
        private(set) var polygons: [MKPolygon] = []
        private var signalByPolygon: [ObjectIdentifier: Double] = [:]

        func signal(for polygon: MKPolygon) -> Double? { signalByPolygon[ObjectIdentifier(polygon)] }

        /// Reference geometry is independent of metric, readings, and selection.
        /// Keeping the same MKPolygon objects avoids rebuilding all their vertices.
        @discardableResult func update(_ newLayers: [TMobileCoverageMapReferenceOverlay]) -> Bool {
            guard layers != newLayers else { return false }
            layers = newLayers
            polygons.removeAll(keepingCapacity: true)
            signalByPolygon.removeAll(keepingCapacity: true)
            for layer in newLayers {
                let signals = layer.modeledSignalDBm?.count == layer.polygons.count ? layer.modeledSignalDBm : nil
                for (index, rings) in layer.polygons.enumerated() {
                    guard let outer = rings.first, outer.count >= 4, outer.allSatisfy(\.isValid) else { continue }
                    let holes = rings.dropFirst().filter { $0.count >= 4 && $0.allSatisfy(\.isValid) }.map { ring in
                        var coordinates = ring.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
                        return MKPolygon(coordinates: &coordinates, count: coordinates.count)
                    }
                    var coordinates = outer.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
                    let polygon = MKPolygon(coordinates: &coordinates, count: coordinates.count, interiorPolygons: holes)
                    polygon.title = layer.title; polygon.subtitle = layer.provenance
                    polygons.append(polygon)
                    if let value = signals?[index], value.isFinite, (-120 ... -50).contains(value) {
                        signalByPolygon[ObjectIdentifier(polygon)] = value
                    }
                }
            }
            return true
        }
    }

    struct Bin {
        let mapRect: MKMapRect
        let count: Int
        let median: Double
        let representativeID: UUID
    }

    static func coordinate(for observation: TMobileCoverageObservation, metric: TMobileCoverageMetric) -> TMobileMapCoordinate? {
        if metric == .speed {
            guard let speed = observation.speedTest, speed.isValid, speed.scoreEligible,
                  let start = speed.startLocation, speedLocationUsable(start, at: speed.startedAt),
                  let end = speed.endLocation, speedLocationUsable(end, at: speed.endedAt),
                  start.distance(to: end) <= 100,
                  abs(speed.endedAt.timeIntervalSince(observation.date)) <= 300 else { return nil }
            if let correction = observation.correction,
               TMobileCoverageSupport.distance(correction.coordinate, start.coordinate) > 150
                || TMobileCoverageSupport.distance(correction.coordinate, end.coordinate) > 150 { return nil }
            return end.coordinate
        }
        if let correction = observation.correction, correction.isValid { return correction.coordinate }
        guard let fix = observation.location, fix.isUsable(at: observation.date) else { return nil }
        return fix.coordinate
    }

    private static func speedLocationUsable(_ fix: TMobileCoverageLocationFix, at date: Date) -> Bool {
        fix.isUsable(at: date) && fix.horizontalAccuracy <= 100
            && (-5...30).contains(date.timeIntervalSince(fix.timestamp))
    }

    static func positionedObservations(_ observations: [TMobileCoverageObservation], metric: TMobileCoverageMetric,
                                       selectedID: UUID? = nil) -> [TMobileCoverageObservation] {
        var speedIDs = Set<UUID>()
        // A reused test is still one measured test. Prefer its selected owning
        // observation so map, list, and chart selection remain linked.
        let ordered: [TMobileCoverageObservation]
        if metric == .speed, let selected = observations.first(where: { $0.id == selectedID }) {
            ordered = [selected] + observations.filter { $0.id != selected.id }
        } else { ordered = observations }
        return ordered.filter { observation in
            guard coordinate(for: observation, metric: metric)?.isValid == true else { return false }
            if metric == .speed, let speedID = observation.speedTest?.id { return speedIDs.insert(speedID).inserted }
            return true
        }
    }

    static func selectedSamples(_ observations: [TMobileCoverageObservation], selectedID: UUID?) -> [TMobileCoverageObservation] {
        guard observations.count > maximumSamples else { return observations }
        let stride = Double(observations.count - 1) / Double(maximumSamples - 1)
        var result = (0..<maximumSamples).map { observations[Int((Double($0) * stride).rounded())] }
        if let selectedID, !result.contains(where: { $0.id == selectedID }),
           let selected = observations.first(where: { $0.id == selectedID }) {
            result[result.count / 2] = selected
        }
        return result
    }

    static func bins(observations: [TMobileCoverageObservation], metric: TMobileCoverageMetric) -> [Bin] {
        struct Key: Hashable { let x: Int; let y: Int }
        // Earth-fixed latitude rows avoid moving bin boundaries when a session
        // or date filter changes. Longitude spacing follows each row's latitude.
        let metresPerDegree = 111_320.0
        let latitudeStep = gridMetres / metresPerDegree
        var values: [Key: [(Double, UUID)]] = [:]
        for observation in positionedObservations(observations, metric: metric) {
            guard let coordinate = coordinate(for: observation, metric: metric), coordinate.isValid,
                  let value = metric.value(in: observation), value.isFinite else { continue }
            let row = Int(floor((coordinate.latitude + 90) / latitudeStep))
            let centerLatitude = min(89.999, max(-89.999, (Double(row) + 0.5) * latitudeStep - 90))
            let longitudeStep = gridMetres / (metresPerDegree * cos(centerLatitude * .pi / 180))
            let key = Key(x: Int(floor((coordinate.longitude + 180) / longitudeStep)), y: row)
            values[key, default: []].append((value, observation.id))
        }
        return values.sorted { $0.key.x == $1.key.x ? $0.key.y < $1.key.y : $0.key.x < $1.key.x }.map { key, entries in
            let sorted = entries.sorted { $0.0 < $1.0 }
            let middle = sorted.count / 2
            let median = sorted.count.isMultiple(of: 2) ? (sorted[middle - 1].0 + sorted[middle].0) / 2 : sorted[middle].0
            let south = max(-90, Double(key.y) * latitudeStep - 90)
            let north = min(90, south + latitudeStep)
            let centerLatitude = min(89.999, max(-89.999, (south + north) / 2))
            let longitudeStep = gridMetres / (metresPerDegree * cos(centerLatitude * .pi / 180))
            let west = max(-180, Double(key.x) * longitudeStep - 180)
            let east = min(180, west + longitudeStep)
            let topLeft = MKMapPoint(CLLocationCoordinate2D(latitude: north, longitude: west))
            let bottomRight = MKMapPoint(CLLocationCoordinate2D(latitude: south, longitude: east))
            return Bin(mapRect: MKMapRect(x: topLeft.x, y: topLeft.y, width: bottomRight.x - topLeft.x, height: bottomRight.y - topLeft.y),
                       count: entries.count, median: median, representativeID: sorted[middle].1)
        }
    }

    static func drawnBins(_ bins: [Bin], selectedID: UUID?) -> [Bin] {
        guard bins.count > maximumBins else { return bins }
        let step = Double(bins.count - 1) / Double(maximumBins - 1)
        var result = (0..<maximumBins).map { bins[Int((Double($0) * step).rounded())] }
        if let selectedID, let selected = bins.first(where: { $0.representativeID == selectedID }),
           !result.contains(where: { $0.representativeID == selectedID }) {
            result[result.count / 2] = selected
        }
        return result
    }

    static func quality(value: Double?, metric: TMobileCoverageMetric) -> TMobileSignalQuality {
        guard let value, value.isFinite else { return .unknown }
        let good: Double, fair: Double
        switch metric {
        case .rsrp: return TMobileGatewayDiagnostics.quality(for: value, metric: .rsrp)
        case .sinr: return TMobileGatewayDiagnostics.quality(for: value, metric: .sinr)
        case .speed: good = 100; fair = 25
        case .score: good = 70; fair = 40
        }
        return value >= good ? .good : value >= fair ? .fair : .poor
    }

    static func color(value: Double?, metric: TMobileCoverageMetric) -> NSColor {
        switch quality(value: value, metric: metric) {
        case .good, .excellent: return .systemGreen
        case .fair: return .systemOrange
        case .poor: return .systemRed
        case .unknown: return .secondaryLabelColor
        }
    }

    static func valueText(_ value: Double?, metric: TMobileCoverageMetric) -> String {
        guard let value, value.isFinite else { return "No \(metric.title) value" }
        return "\(value.formatted(.number.precision(.fractionLength(0...1)))) \(metric.unit)"
    }
}

private struct TMobileCoverageNativeMap: NSViewRepresentable {
    let observations: [TMobileCoverageObservation]
    let towers: [TMobileTowerPin]
    let referenceOverlays: [TMobileCoverageMapReferenceOverlay]
    let metric: TMobileCoverageMetric
    let displayMode: TMobileCoverageMapMode
    let fitRequest: Int
    @Binding var selectedObservationID: UUID?
    let selectedTowerID: UUID?
    let onTowerSelected: ((UUID) -> Void)?
    let showsMeasurements: Bool
    let initialRegion: MKCoordinateRegion?
    let onRegionChanged: ((MKCoordinateRegion) -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }
    func makeNSView(context: Context) -> MKMapView {
        let map = MKMapView(frame: .zero)
        map.delegate = context.coordinator
        map.mapType = .standard
        map.showsCompass = true
        map.showsScale = true
        map.showsUserLocation = false
        map.pointOfInterestFilter = .excludingAll
        if TMobileCoverageMapDrawing.validInitialRegion(initialRegion), let initialRegion {
            map.setRegion(initialRegion, animated: false)
        }
        map.setAccessibilityLabel("Coverage map with measured readings, tower references, and modeled coverage. Use the readings and tower lists to select a location with the keyboard.")
        return map
    }
    func updateNSView(_ map: MKMapView, context: Context) {
        context.coordinator.update(parent: self, map: map)
    }

    final class Coordinator: NSObject, MKMapViewDelegate {
        var parent: TMobileCoverageNativeMap
        private var previousObservations: [TMobileCoverageObservation] = []
        private var previousTowers: [TMobileTowerPin] = []
        private let referenceCache = TMobileCoverageMapDrawing.ReferenceGeometryCache()
        private var previousMetric: TMobileCoverageMetric?
        private var previousMode: TMobileCoverageMapMode?
        private var previousSelection: UUID?
        private var previousTowerSelection: UUID?
        private var previousShowsMeasurements: Bool?
        private var previousSelectedObservation: TMobileCoverageObservation?
        private var activeSelection: TMobileCoverageMapDrawing.SelectionTarget?
        private var measurementAnnotations: [MKAnnotation] = []
        private var measurementOverlays: [MKOverlay] = []
        private var towerAnnotations: [TowerAnnotation] = []
        private var selectionAnnotations: [MKAnnotation] = []
        private var selectionOverlays: [MKOverlay] = []
        private var lastFitRequest = -1
        private var didFitData = false
        private var hasUpdated = false
        private var updating = false
        private var pendingRegion: MKCoordinateRegion?
        private var lastDeliveredRegion: MKCoordinateRegion?
        private var regionDeliveryScheduled = false

        init(parent: TMobileCoverageNativeMap) {
            self.parent = parent
            if TMobileCoverageMapDrawing.validInitialRegion(parent.initialRegion) {
                didFitData = true
                lastFitRequest = parent.fitRequest
            }
        }

        func update(parent: TMobileCoverageNativeMap, map: MKMapView) {
            self.parent = parent
            let restoringRegion = !hasUpdated && TMobileCoverageMapDrawing.validInitialRegion(parent.initialRegion)
            hasUpdated = true
            let nextSelection = TMobileCoverageMapDrawing.selectionTarget(
                previousReading: previousSelection, previousTower: previousTowerSelection,
                reading: parent.selectedObservationID, tower: parent.selectedTowerID, current: activeSelection)
            let targetChanged = nextSelection != activeSelection
            activeSelection = nextSelection
            let readingSelectionChanged = previousSelection != parent.selectedObservationID
            let controlledSelectionChanged = readingSelectionChanged || previousTowerSelection != parent.selectedTowerID
            let metricOrModeChanged = previousMetric != parent.metric || previousMode != parent.displayMode
                || previousShowsMeasurements != parent.showsMeasurements
            updating = true
            let oldReferences = referenceCache.polygons
            if referenceCache.update(parent.referenceOverlays) {
                map.removeOverlays(oldReferences)
                map.addOverlays(referenceCache.polygons, level: .aboveRoads)
            }
            if previousObservations != parent.observations || metricOrModeChanged || readingSelectionChanged {
                var annotations: [MKAnnotation] = []
                map.removeOverlays(measurementOverlays)
                measurementOverlays.removeAll(keepingCapacity: true)
                if parent.showsMeasurements {
                    let located = TMobileCoverageMapDrawing.positionedObservations(parent.observations, metric: parent.metric,
                                                                                   selectedID: parent.selectedObservationID)
                    if parent.displayMode == .samples {
                        let reusable = Dictionary(measurementAnnotations.compactMap { $0 as? ReadingAnnotation }
                            .map { ($0.observationID, $0) }, uniquingKeysWith: { first, _ in first })
                        annotations = TMobileCoverageMapDrawing.selectedSamples(located, selectedID: parent.selectedObservationID).map {
                            if let existing = reusable[$0.id], existing.observation == $0, existing.metric == parent.metric { return existing }
                            return ReadingAnnotation(observation: $0, metric: parent.metric)
                        }
                    } else {
                        let bins = TMobileCoverageMapDrawing.bins(observations: located, metric: parent.metric)
                        for bin in TMobileCoverageMapDrawing.drawnBins(bins, selectedID: parent.selectedObservationID) {
                            measurementOverlays.append(MeasuredBinOverlay(bin: bin, metric: parent.metric))
                            annotations.append(BinAnnotation(bin: bin, metric: parent.metric))
                        }
                    }
                }
                replaceAnnotations(measurementAnnotations, with: annotations, on: map)
                measurementAnnotations = annotations
                // Keep measured cells above every modeled polygon, including after a reference refresh.
                map.addOverlays(measurementOverlays, level: .aboveLabels)
            }
            if previousTowers != parent.towers {
                let reusable = Dictionary(towerAnnotations.map { ($0.towerID, $0) }, uniquingKeysWith: { first, _ in first })
                let annotations = parent.towers.filter(\.isValid).map { pin in
                    if let existing = reusable[pin.id], existing.pin == pin { return existing }
                    return TowerAnnotation(pin: pin)
                }
                replaceAnnotations(towerAnnotations, with: annotations, on: map)
                towerAnnotations = annotations
            }
            let selectedObservation = parent.showsMeasurements
                ? parent.observations.first(where: { $0.id == parent.selectedObservationID }) : nil
            if previousSelectedObservation != selectedObservation || metricOrModeChanged || readingSelectionChanged {
                map.removeAnnotations(selectionAnnotations); selectionAnnotations.removeAll()
                map.removeOverlays(selectionOverlays); selectionOverlays.removeAll()
                addSelectedLocation(to: map)
            }
            previousObservations = parent.observations; previousTowers = parent.towers
            previousMetric = parent.metric; previousMode = parent.displayMode
            previousSelection = parent.selectedObservationID; previousTowerSelection = parent.selectedTowerID
            previousShowsMeasurements = parent.showsMeasurements; previousSelectedObservation = selectedObservation
            if targetChanged || controlledSelectionChanged || metricOrModeChanged { refreshMarkerSelection(on: map) }
            updating = false
            let hasData = !map.annotations.isEmpty || !map.overlays.isEmpty
            if parent.fitRequest != lastFitRequest || (!didFitData && hasData) {
                let includesAllLayers = didFitData && parent.fitRequest != lastFitRequest
                lastFitRequest = parent.fitRequest
                if hasData { fit(map, includesAllLayers: includesAllLayers); didFitData = true }
            }
            // Selecting an annotation may pan its callout into view. Only explicit
            // controlled selection changes can do this, never periodic data updates.
            if (targetChanged || controlledSelectionChanged) && !restoringRegion {
                let annotation: MKAnnotation? = map.annotations.first { annotation in
                    switch activeSelection {
                    case .reading(let id): return (annotation as? ReadingAnnotation)?.observationID == id
                    case .tower(let id): return (annotation as? TowerAnnotation)?.towerID == id
                    case nil: return false
                    }
                }
                updating = true
                for selected in map.selectedAnnotations where selected !== annotation { map.deselectAnnotation(selected, animated: false) }
                if let annotation {
                    if !map.visibleMapRect.contains(MKMapPoint(annotation.coordinate)) {
                        map.setCenter(annotation.coordinate, animated: false)
                    }
                    if !map.selectedAnnotations.contains(where: { $0 === annotation }) { map.selectAnnotation(annotation, animated: false) }
                }
                updating = false
            }
            publishRegion(map.region)
        }

        private func replaceAnnotations(_ old: [MKAnnotation], with new: [MKAnnotation], on map: MKMapView) {
            let oldIDs = Set(old.map { ObjectIdentifier($0 as AnyObject) })
            let newIDs = Set(new.map { ObjectIdentifier($0 as AnyObject) })
            map.removeAnnotations(old.filter { !newIDs.contains(ObjectIdentifier($0 as AnyObject)) })
            map.addAnnotations(new.filter { !oldIDs.contains(ObjectIdentifier($0 as AnyObject)) })
        }

        private func refreshMarkerSelection(on map: MKMapView) {
            for annotation in map.annotations {
                guard let view = map.view(for: annotation) as? MKMarkerAnnotationView else { continue }
                configureMarker(view, annotation: annotation)
            }
        }

        func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
            publishRegion(mapView.region)
        }

        private func publishRegion(_ region: MKCoordinateRegion) {
            guard parent.onRegionChanged != nil else { return }
            pendingRegion = region
            guard !regionDeliveryScheduled else { return }
            regionDeliveryScheduled = true
            // A delegate can fire during updateNSView. Coalesce camera events
            // and deliver outside that update, without changing the camera.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.regionDeliveryScheduled = false
                guard let latest = self.pendingRegion else { return }
                self.pendingRegion = nil
                if let previous = self.lastDeliveredRegion,
                   Self.sameRegion(previous, latest) { return }
                self.lastDeliveredRegion = latest
                self.parent.onRegionChanged?(latest)
            }
        }

        private static func sameRegion(_ lhs: MKCoordinateRegion, _ rhs: MKCoordinateRegion) -> Bool {
            let tolerance = 0.0000001
            return abs(lhs.center.latitude - rhs.center.latitude) < tolerance
                && abs(lhs.center.longitude - rhs.center.longitude) < tolerance
                && abs(lhs.span.latitudeDelta - rhs.span.latitudeDelta) < tolerance
                && abs(lhs.span.longitudeDelta - rhs.span.longitudeDelta) < tolerance
        }

        private func addSelectedLocation(to map: MKMapView) {
            guard parent.showsMeasurements,
                  let observation = parent.observations.first(where: { $0.id == parent.selectedObservationID }),
                  let coordinate = TMobileCoverageMapDrawing.coordinate(for: observation, metric: parent.metric), coordinate.isValid else { return }
            if parent.displayMode == .heat {
                selectionAnnotations.append(ReadingAnnotation(observation: observation, metric: parent.metric))
            }
            let accuracyFix = parent.metric == .speed ? observation.speedTest?.endLocation : observation.location
            if let fix = accuracyFix, fix.coordinate.isValid,
               fix.horizontalAccuracy.isFinite, fix.horizontalAccuracy > 0 {
                let circle = MKCircle(center: CLLocationCoordinate2D(latitude: fix.coordinate.latitude, longitude: fix.coordinate.longitude),
                                      radius: fix.horizontalAccuracy)
                selectionOverlays.append(circle)
            }
            if parent.metric != .speed, observation.correction != nil, let original = observation.location?.coordinate, original.isValid,
               original != coordinate {
                var points = [CLLocationCoordinate2D(latitude: original.latitude, longitude: original.longitude),
                              CLLocationCoordinate2D(latitude: coordinate.latitude, longitude: coordinate.longitude)]
                let line = MKPolyline(coordinates: &points, count: 2)
                selectionOverlays.append(line)
                selectionAnnotations.append(OriginalLocationAnnotation(coordinate: points[0]))
            }
            map.addAnnotations(selectionAnnotations)
            map.addOverlays(selectionOverlays, level: .aboveLabels)
        }

        private func fit(_ map: MKMapView, includesAllLayers: Bool) {
            var rect = TMobileCoverageMapDrawing.fitRect(
                positions: map.annotations.map { .init(latitude: $0.coordinate.latitude, longitude: $0.coordinate.longitude) },
                measuredRects: measurementOverlays.map(\.boundingMapRect),
                referenceRects: referenceCache.polygons.map(\.boundingMapRect), includesAllLayers: includesAllLayers)
            guard !rect.isNull else { return }
            let padding = max(200 * MKMapPointsPerMeterAtLatitude(map.centerCoordinate.latitude), max(rect.width, rect.height) * 0.08)
            rect = rect.insetBy(dx: -padding, dy: -padding)
            map.setVisibleMapRect(rect, edgePadding: NSEdgeInsets(top: 35, left: 35, bottom: 35, right: 35), animated: false)
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            if let bin = annotation as? BinAnnotation {
                let view = mapView.dequeueReusableAnnotationView(withIdentifier: "coverage-bin") ?? MKAnnotationView(annotation: annotation, reuseIdentifier: "coverage-bin")
                view.annotation = annotation; view.canShowCallout = true
                let binColor = TMobileCoverageMapDrawing.color(value: bin.value, metric: parent.metric)
                view.image = NSImage(size: NSSize(width: 6, height: 6), flipped: false) { rect in
                    binColor.setFill()
                    NSBezierPath(rect: rect).fill()
                    return true
                }
                view.setAccessibilityLabel("\(bin.title ?? "Measured bin"). \(bin.subtitle ?? "")")
                return view
            }
            let view = mapView.dequeueReusableAnnotationView(withIdentifier: "coverage-marker") as? MKMarkerAnnotationView
                ?? MKMarkerAnnotationView(annotation: annotation, reuseIdentifier: "coverage-marker")
            view.annotation = annotation; view.canShowCallout = true; view.clusteringIdentifier = nil
            configureMarker(view, annotation: annotation)
            return view
        }

        private func configureMarker(_ view: MKMarkerAnnotationView, annotation: MKAnnotation) {
            view.displayPriority = .defaultLow
            view.titleVisibility = .adaptive; view.subtitleVisibility = .hidden
            view.detailCalloutAccessoryView = nil
            view.glyphText = nil
            if let reading = annotation as? ReadingAnnotation {
                view.markerTintColor = TMobileCoverageMapDrawing.color(value: reading.value, metric: parent.metric)
                view.glyphImage = NSImage(systemSymbolName: reading.corrected ? "pencil" : "waveform.path", accessibilityDescription: nil)
                view.displayPriority = activeSelection == .reading(reading.observationID) ? .required : .defaultLow
            } else if let tower = annotation as? TowerAnnotation {
                let selected = activeSelection == .tower(tower.towerID)
                view.markerTintColor = selected ? .systemPurple : .systemIndigo
                view.glyphImage = NSImage(systemSymbolName: "antenna.radiowaves.left.and.right", accessibilityDescription: nil)
                view.titleVisibility = .visible
                view.displayPriority = selected ? .required : .defaultHigh
                let detail = NSTextField(wrappingLabelWithString: tower.detail)
                detail.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
                detail.textColor = .secondaryLabelColor
                detail.preferredMaxLayoutWidth = 240
                view.detailCalloutAccessoryView = detail
            } else {
                view.markerTintColor = .secondaryLabelColor
                view.glyphImage = NSImage(systemSymbolName: "location", accessibilityDescription: nil)
            }
            let detail = (annotation as? TowerAnnotation).map { ". \($0.detail)" } ?? ""
            view.setAccessibilityLabel("\((annotation.title ?? nil) ?? "Location"). \((annotation.subtitle ?? nil) ?? "")\(detail)")
        }

        func mapView(_ mapView: MKMapView, didSelect view: MKAnnotationView) {
            guard !updating else { return }
            if let tower = view.annotation as? TowerAnnotation {
                activeSelection = .tower(tower.towerID)
                refreshMarkerSelection(on: mapView)
                DispatchQueue.main.async { [weak self] in self?.parent.onTowerSelected?(tower.towerID) }
                return
            }
            let id = (view.annotation as? ReadingAnnotation)?.observationID ?? (view.annotation as? BinAnnotation)?.representativeID
            if let id {
                activeSelection = .reading(id)
                refreshMarkerSelection(on: mapView)
                if id != parent.selectedObservationID {
                    DispatchQueue.main.async { [weak self] in self?.parent.selectedObservationID = id }
                }
            }
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let bin = overlay as? MeasuredBinOverlay { return MeasuredBinRenderer(overlay: bin) }
            if let polygon = overlay as? MKPolygon {
                let renderer = MKPolygonRenderer(polygon: polygon)
                let color = TMobileCoverageMapDrawing.referenceColor(modeledSignalDBm: referenceCache.signal(for: polygon))
                renderer.fillColor = color
                renderer.strokeColor = color.withAlphaComponent(0.85)
                renderer.lineWidth = 1.5
                return renderer
            }
            if let circle = overlay as? MKCircle {
                let renderer = MKCircleRenderer(circle: circle)
                renderer.strokeColor = NSColor.secondaryLabelColor.withAlphaComponent(0.8)
                renderer.fillColor = .clear; renderer.lineWidth = 1.5; renderer.lineDashPattern = [4, 4]
                return renderer
            }
            if let line = overlay as? MKPolyline {
                let renderer = MKPolylineRenderer(polyline: line)
                renderer.strokeColor = .secondaryLabelColor; renderer.lineWidth = 1.5; renderer.lineDashPattern = [4, 4]
                return renderer
            }
            return MKOverlayRenderer(overlay: overlay)
        }
    }
}

private final class ReadingAnnotation: NSObject, MKAnnotation {
    let observation: TMobileCoverageObservation
    let metric: TMobileCoverageMetric
    let observationID: UUID
    let coordinate: CLLocationCoordinate2D
    let title: String?
    let subtitle: String?
    let value: Double?
    let corrected: Bool
    init(observation: TMobileCoverageObservation, metric: TMobileCoverageMetric) {
        self.observation = observation; self.metric = metric
        observationID = observation.id
        let position = TMobileCoverageMapDrawing.coordinate(for: observation, metric: metric)!
        coordinate = CLLocationCoordinate2D(latitude: position.latitude, longitude: position.longitude)
        let date = metric == .speed ? observation.speedTest?.endedAt ?? observation.date : observation.date
        title = date.formatted(date: .abbreviated, time: .standard)
        value = metric.value(in: observation); corrected = metric != .speed && observation.correction != nil
        subtitle = TMobileCoverageMapDrawing.valueText(value, metric: metric)
            + " · " + TMobileCoverageMapDrawing.quality(value: value, metric: metric).label
            + (corrected ? " · Manually corrected position" : " · Recorded position")
    }
}

private final class TowerAnnotation: NSObject, MKAnnotation {
    let pin: TMobileTowerPin
    var towerID: UUID { pin.id }
    let coordinate: CLLocationCoordinate2D
    let title: String?
    let subtitle: String?
    let detail: String
    init(pin: TMobileTowerPin) {
        self.pin = pin
        coordinate = CLLocationCoordinate2D(latitude: pin.latitude, longitude: pin.longitude)
        let presentation = TMobileCoverageMapDrawing.TowerPresentation(pin: pin)
        title = presentation.title; subtitle = presentation.subtitle; detail = presentation.detail
    }
}

private final class OriginalLocationAnnotation: NSObject, MKAnnotation {
    let coordinate: CLLocationCoordinate2D
    let title: String? = "Original recorded position"
    let subtitle: String? = "Dashed line shows a manual correction, not a traveled route."
    init(coordinate: CLLocationCoordinate2D) { self.coordinate = coordinate }
}

private final class BinAnnotation: NSObject, MKAnnotation {
    let coordinate: CLLocationCoordinate2D
    let title: String?
    let subtitle: String?
    let representativeID: UUID
    let value: Double
    init(bin: TMobileCoverageMapDrawing.Bin, metric: TMobileCoverageMetric) {
        coordinate = MKMapPoint(x: bin.mapRect.midX, y: bin.mapRect.midY).coordinate
        title = "\(bin.count) measured reading\(bin.count == 1 ? "" : "s") in an approximately 50 m bin"
        subtitle = "Median \(TMobileCoverageMapDrawing.valueText(bin.median, metric: metric)) · \(TMobileCoverageMapDrawing.quality(value: bin.median, metric: metric).label) · Selects a representative reading"
        representativeID = bin.representativeID; value = bin.median
    }
}

private final class MeasuredBinOverlay: NSObject, MKOverlay {
    let boundingMapRect: MKMapRect
    let coordinate: CLLocationCoordinate2D
    let color: NSColor
    init(bin: TMobileCoverageMapDrawing.Bin, metric: TMobileCoverageMetric) {
        boundingMapRect = bin.mapRect
        coordinate = MKMapPoint(x: bin.mapRect.midX, y: bin.mapRect.midY).coordinate
        color = TMobileCoverageMapDrawing.color(value: bin.median, metric: metric)
    }
}

private final class MeasuredBinRenderer: MKOverlayRenderer {
    override func draw(_ mapRect: MKMapRect, zoomScale: MKZoomScale, in context: CGContext) {
        guard let bin = overlay as? MeasuredBinOverlay else { return }
        let rectangle = rect(for: bin.boundingMapRect)
        context.setFillColor(bin.color.withAlphaComponent(0.60).cgColor)
        context.fill(rectangle)
        context.setStrokeColor(bin.color.withAlphaComponent(0.85).cgColor)
        context.setLineWidth(1 / zoomScale)
        context.stroke(rectangle)
    }
}
