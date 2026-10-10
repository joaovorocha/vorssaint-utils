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

    init(id: UUID = UUID(), title: String, provenance: String, publishedAt: Date? = nil,
         polygons: [[[TMobileMapCoordinate]]]) {
        self.id = id; self.title = title; self.provenance = provenance
        self.publishedAt = publishedAt; self.polygons = polygons
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
            HStack {
                Label("Apple Maps", systemImage: "map")
                    .font(.caption.weight(.semibold))
                Spacer()
                Text(displayMode == .samples
                     ? "\(drawingCount) of \(located.count) located readings drawn"
                     : "\(drawingCount) of \(allBins.count) measured bins drawn")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Fit all") { fitRequest += 1 }
                    .help("Fit recorded locations and saved tower references")
            }
            TMobileCoverageNativeMap(observations: observations, towers: towers,
                                     referenceOverlays: referenceOverlays, metric: metric,
                                     displayMode: displayMode, fitRequest: fitRequest,
                                     selectedObservationID: $selectedObservationID)
                .frame(minHeight: 300)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay {
                    if located.isEmpty && towers.isEmpty && referenceOverlays.isEmpty {
                        VStack(spacing: 6) {
                            Image(systemName: "location.slash").font(.title2)
                            Text(metric == .speed ? "No mapped speed tests" : "No saved locations").font(.headline)
                            Text(metric == .speed
                                 ? "A speed test appears here when it has fresh, precise recorded positions and a stable location context."
                                 : "Record with Mac Location Services or correct a saved reading’s location.")
                                .font(.caption).multilineTextAlignment(.center)
                        }
                        .padding(18).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                        .padding(24).allowsHitTesting(false)
                    }
                }
            HStack(spacing: 12) {
                legend("Good", color: .green, symbol: "checkmark.circle.fill")
                legend("Fair", color: .yellow, symbol: "minus.circle.fill")
                legend("Poor", color: .red, symbol: "exclamationmark.circle.fill")
                if displayMode == .samples { legend("No value", color: .secondary, symbol: "circle") }
            }.font(.caption)
            Text(displayMode == .heat
                 ? "Each colored bin contains actual readings and shows their median in an approximately 50 m grid. Unvisited bins have no measured coverage; this layer does not interpolate."
                 : "Points show saved locations. Gray points have no value for this metric. Select a point or use the readings list.")
                .font(.caption).foregroundStyle(.secondary)
            Text("Colors are app guidance for the selected metric, not carrier ratings or predicted coverage.")
                .font(.caption2).foregroundStyle(.secondary)
            Text("Stale or imprecise reported positions are omitted. Manual corrections remain explicit. Speed uses the test’s recorded location and appears only when its location context is valid.")
                .font(.caption2).foregroundStyle(.secondary)
            if selectedObservationID != nil {
                Text("Dashed ring: recorded position accuracy, not a cellular coverage radius. Dashed connector: manual correction, not a traveled route.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            if !towers.isEmpty || !referenceOverlays.isEmpty {
                Text("Tower pins are source references with unverified locations. Purple boundaries are imported modeled coverage, separate from your measurements.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func legend(_ title: String, color: Color, symbol: String) -> some View {
        Label { Text(title) } icon: { Image(systemName: symbol).foregroundStyle(color) }
    }
}

enum TMobileCoverageMapDrawing {
    static let maximumSamples = 2_000
    static let maximumBins = 2_000
    static let gridMetres = 50.0

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
        case .fair: return .systemYellow
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

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }
    func makeNSView(context: Context) -> MKMapView {
        let map = MKMapView(frame: .zero)
        map.delegate = context.coordinator
        map.mapType = .standard
        map.showsCompass = true
        map.showsScale = true
        map.showsUserLocation = false
        map.pointOfInterestFilter = .excludingAll
        map.setAccessibilityLabel("Recorded coverage map. Use the readings list to select a reading with the keyboard.")
        return map
    }
    func updateNSView(_ map: MKMapView, context: Context) {
        context.coordinator.update(parent: self, map: map)
    }

    final class Coordinator: NSObject, MKMapViewDelegate {
        var parent: TMobileCoverageNativeMap
        private var previousObservations: [TMobileCoverageObservation] = []
        private var previousTowers: [TMobileTowerPin] = []
        private var previousReferences: [TMobileCoverageMapReferenceOverlay] = []
        private var previousMetric: TMobileCoverageMetric?
        private var previousMode: TMobileCoverageMapMode?
        private var previousSelection: UUID?
        private var lastFitRequest = -1
        private var didFitData = false
        private var updating = false
        private var accuracyCircles = Set<ObjectIdentifier>()

        init(parent: TMobileCoverageNativeMap) { self.parent = parent }

        func update(parent: TMobileCoverageNativeMap, map: MKMapView) {
            self.parent = parent
            let selectionChanged = previousSelection != parent.selectedObservationID
            let changed = previousObservations != parent.observations || previousTowers != parent.towers
                || previousReferences != parent.referenceOverlays || previousMetric != parent.metric
                || previousMode != parent.displayMode || previousSelection != parent.selectedObservationID
            if changed {
                updating = true
                map.removeAnnotations(map.annotations)
                map.removeOverlays(map.overlays)
                accuracyCircles.removeAll()
                addReferenceLayers(to: map)
                let located = TMobileCoverageMapDrawing.positionedObservations(parent.observations, metric: parent.metric,
                                                                               selectedID: parent.selectedObservationID)
                if parent.displayMode == .samples {
                    map.addAnnotations(TMobileCoverageMapDrawing.selectedSamples(located, selectedID: parent.selectedObservationID)
                        .map { ReadingAnnotation(observation: $0, metric: parent.metric) })
                } else {
                    let bins = TMobileCoverageMapDrawing.bins(observations: located, metric: parent.metric)
                    for bin in TMobileCoverageMapDrawing.drawnBins(bins, selectedID: parent.selectedObservationID) {
                        map.addOverlay(MeasuredBinOverlay(bin: bin, metric: parent.metric), level: .aboveRoads)
                        map.addAnnotation(BinAnnotation(bin: bin, metric: parent.metric))
                    }
                }
                map.addAnnotations(parent.towers.filter(\.isValid).map(TowerAnnotation.init))
                addSelectedLocation(to: map)
                previousObservations = parent.observations; previousTowers = parent.towers
                previousReferences = parent.referenceOverlays; previousMetric = parent.metric
                previousMode = parent.displayMode; previousSelection = parent.selectedObservationID
                updating = false
            }
            let hasData = !map.annotations.isEmpty || !map.overlays.isEmpty
            if parent.fitRequest != lastFitRequest || (!didFitData && hasData) {
                lastFitRequest = parent.fitRequest
                if hasData { fitAll(map); didFitData = true }
            }
            if let selectedID = parent.selectedObservationID,
               let annotation = map.annotations.first(where: { ($0 as? ReadingAnnotation)?.observationID == selectedID }) {
                if selectionChanged, !map.visibleMapRect.contains(MKMapPoint(annotation.coordinate)) {
                    map.setCenter(annotation.coordinate, animated: false)
                }
                if !map.selectedAnnotations.contains(where: { $0 === annotation }) {
                    updating = true; map.selectAnnotation(annotation, animated: false); updating = false
                }
            }
        }

        private func addReferenceLayers(to map: MKMapView) {
            for layer in parent.referenceOverlays {
                for rings in layer.polygons {
                    guard let outer = rings.first, outer.count >= 4, outer.allSatisfy(\.isValid) else { continue }
                    let holes = rings.dropFirst().filter { $0.count >= 4 && $0.allSatisfy(\.isValid) }.map { ring in
                        var coordinates = ring.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
                        return MKPolygon(coordinates: &coordinates, count: coordinates.count)
                    }
                    var coordinates = outer.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
                    let polygon = MKPolygon(coordinates: &coordinates, count: coordinates.count, interiorPolygons: holes)
                    polygon.title = layer.title
                    polygon.subtitle = layer.provenance
                    map.addOverlay(polygon, level: .aboveRoads)
                }
            }
        }

        private func addSelectedLocation(to map: MKMapView) {
            guard let observation = parent.observations.first(where: { $0.id == parent.selectedObservationID }),
                  let coordinate = TMobileCoverageMapDrawing.coordinate(for: observation, metric: parent.metric), coordinate.isValid else { return }
            if parent.displayMode == .heat {
                map.addAnnotation(ReadingAnnotation(observation: observation, metric: parent.metric))
            }
            let accuracyFix = parent.metric == .speed ? observation.speedTest?.endLocation : observation.location
            if let fix = accuracyFix, fix.coordinate.isValid,
               fix.horizontalAccuracy.isFinite, fix.horizontalAccuracy > 0 {
                let circle = MKCircle(center: CLLocationCoordinate2D(latitude: fix.coordinate.latitude, longitude: fix.coordinate.longitude),
                                      radius: fix.horizontalAccuracy)
                accuracyCircles.insert(ObjectIdentifier(circle)); map.addOverlay(circle, level: .aboveLabels)
            }
            if parent.metric != .speed, observation.correction != nil, let original = observation.location?.coordinate, original.isValid,
               original != coordinate {
                var points = [CLLocationCoordinate2D(latitude: original.latitude, longitude: original.longitude),
                              CLLocationCoordinate2D(latitude: coordinate.latitude, longitude: coordinate.longitude)]
                let line = MKPolyline(coordinates: &points, count: 2)
                map.addOverlay(line, level: .aboveLabels)
                map.addAnnotation(OriginalLocationAnnotation(coordinate: points[0]))
            }
        }

        private func fitAll(_ map: MKMapView) {
            var rect = MKMapRect.null
            for annotation in map.annotations {
                let point = MKMapPoint(annotation.coordinate)
                rect = rect.union(MKMapRect(x: point.x, y: point.y, width: 1, height: 1))
            }
            for overlay in map.overlays where !accuracyCircles.contains(ObjectIdentifier(overlay as AnyObject)) {
                rect = rect.union(overlay.boundingMapRect)
            }
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
            view.displayPriority = .defaultLow
            if let reading = annotation as? ReadingAnnotation {
                view.markerTintColor = TMobileCoverageMapDrawing.color(value: reading.value, metric: parent.metric)
                view.glyphImage = NSImage(systemSymbolName: reading.corrected ? "pencil" : "waveform.path", accessibilityDescription: nil)
                view.displayPriority = reading.observationID == parent.selectedObservationID ? .required : .defaultLow
            } else if annotation is TowerAnnotation {
                view.markerTintColor = .systemBlue
                view.glyphImage = NSImage(systemSymbolName: "antenna.radiowaves.left.and.right", accessibilityDescription: nil)
            } else {
                view.markerTintColor = .secondaryLabelColor
                view.glyphImage = NSImage(systemSymbolName: "location", accessibilityDescription: nil)
            }
            view.setAccessibilityLabel("\((annotation.title ?? nil) ?? "Location"). \((annotation.subtitle ?? nil) ?? "")")
            return view
        }

        func mapView(_ mapView: MKMapView, didSelect view: MKAnnotationView) {
            guard !updating else { return }
            let id = (view.annotation as? ReadingAnnotation)?.observationID ?? (view.annotation as? BinAnnotation)?.representativeID
            if let id, id != parent.selectedObservationID {
                DispatchQueue.main.async { self.parent.selectedObservationID = id }
            }
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let bin = overlay as? MeasuredBinOverlay { return MeasuredBinRenderer(overlay: bin) }
            if let polygon = overlay as? MKPolygon {
                let renderer = MKPolygonRenderer(polygon: polygon)
                renderer.fillColor = NSColor.systemPurple.withAlphaComponent(0.10)
                renderer.strokeColor = NSColor.systemPurple.withAlphaComponent(0.75)
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
    let observationID: UUID
    let coordinate: CLLocationCoordinate2D
    let title: String?
    let subtitle: String?
    let value: Double?
    let corrected: Bool
    init(observation: TMobileCoverageObservation, metric: TMobileCoverageMetric) {
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
    let coordinate: CLLocationCoordinate2D
    let title: String?
    let subtitle: String?
    init(pin: TMobileTowerPin) {
        coordinate = CLLocationCoordinate2D(latitude: pin.latitude, longitude: pin.longitude)
        title = pin.name
        subtitle = "Location unverified · \(pin.provenance ?? "Local reference; source unspecified")"
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
        context.setFillColor(bin.color.withAlphaComponent(0.44).cgColor)
        context.fill(rectangle)
        context.setStrokeColor(bin.color.withAlphaComponent(0.85).cgColor)
        context.setLineWidth(1 / zoomScale)
        context.stroke(rectangle)
    }
}
