// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import MapKit
import SwiftUI

enum TMobileCoverageMapChartsTests {
    static func run(_ suite: TestSuite) {
        let epoch = Date(timeIntervalSince1970: 1_780_000_000)
        let coordinate = TMobileMapCoordinate(latitude: 40, longitude: -100)
        func observation(_ offset: Double, rsrp: Double? = -95, sinr: Double? = 13,
                         coordinate: TMobileMapCoordinate? = coordinate,
                         speed: TMobileCoverageSpeedResult? = nil,
                         corrections: [TMobileCoverageLocationCorrection] = []) -> TMobileCoverageObservation {
            let date = epoch.addingTimeInterval(offset)
            let radio = TMobileRadioSignal(bars: nil, bands: ["n41"], rsrp: rsrp, rsrq: nil, rssi: nil, sinr: sinr)
            let snapshot = TMobileGatewaySnapshot(model: nil, firmware: nil, uptime: nil,
                                                  registration: "registered", roaming: nil, lte: nil, fiveG: radio)
            let location = coordinate.map { TMobileCoverageLocationFix(coordinate: $0, timestamp: date, horizontalAccuracy: 20, source: .mac) }
            return TMobileCoverageObservation(date: date, snapshot: snapshot, location: location,
                                               corrections: corrections, speedTest: speed)
        }
        let first = observation(0, rsrp: -110)
        let second = observation(60, rsrp: -90)
        let bins = TMobileCoverageMapDrawing.bins(observations: [first, second], metric: .rsrp)
        suite.expect(bins.count == 1 && bins.first?.count == 2, "co-located real readings share one measured bin")
        suite.expectClose(bins.first?.median ?? .nan, -100, "bin uses median instead of best signal")
        suite.expect(bins.first?.mapRect.contains(MKMapPoint(CLLocationCoordinate2D(latitude: coordinate.latitude, longitude: coordinate.longitude))) == true,
                     "measured bin contains the actual recorded position")
        let distant = observation(120, coordinate: .init(latitude: 41, longitude: -101))
        let expanded = TMobileCoverageMapDrawing.bins(observations: [first, second, distant], metric: .rsrp)
        let originalRect = bins[0].mapRect
        suite.expect(expanded.contains { $0.mapRect.origin.x == originalRect.origin.x && $0.mapRect.origin.y == originalRect.origin.y
            && $0.mapRect.size.width == originalRect.size.width && $0.mapRect.size.height == originalRect.size.height },
                     "bin boundaries stay fixed when a distant reading is added")
        suite.expect(expanded.count == 2, "unvisited space between readings is never interpolated")
        suite.expect(TMobileCoverageMapDrawing.bins(observations: [observation(0, coordinate: nil)], metric: .rsrp).isEmpty,
                     "location-free readings do not become map coordinates")
        suite.expect(TMobileCoverageMapDrawing.bins(observations: [first], metric: .speed).isEmpty,
                     "missing speed does not create a zero-speed heat bin")
        suite.expect(TMobileCoverageMapDrawing.bins(observations: [first], metric: .score).isEmpty,
                     "incomplete score does not create a heat bin")
        let staleFix = TMobileCoverageLocationFix(coordinate: coordinate, timestamp: epoch.addingTimeInterval(-600), horizontalAccuracy: 20, source: .mac)
        let stale = TMobileCoverageObservation(date: epoch, snapshot: first.snapshot, location: staleFix)
        suite.expect(TMobileCoverageMapDrawing.coordinate(for: stale, metric: .rsrp) == nil,
                     "stale reported position does not paint radio measurements on the map")
        let impreciseFix = TMobileCoverageLocationFix(coordinate: coordinate, timestamp: epoch, horizontalAccuracy: 500, source: .mac)
        let imprecise = TMobileCoverageObservation(date: epoch, snapshot: first.snapshot, location: impreciseFix)
        suite.expect(TMobileCoverageMapDrawing.coordinate(for: imprecise, metric: .rsrp) == nil,
                     "imprecise reported position remains in history without painting map coverage")

        let corrected = observation(0, coordinate: coordinate,
                                    corrections: [.init(coordinate: .init(latitude: 41, longitude: -101), correctedAt: epoch)])
        let correctedBin = TMobileCoverageMapDrawing.bins(observations: [corrected], metric: .rsrp).first
        let moved = MKMapPoint(CLLocationCoordinate2D(latitude: 41, longitude: -101))
        suite.expect(correctedBin?.mapRect.contains(moved) == true && corrected.location?.coordinate == coordinate,
                     "map uses correction while preserving the original fix")

        let many = (0..<5_000).map { observation(Double($0) * 60) }
        let selectedID = many[2_501].id
        let drawn = TMobileCoverageMapDrawing.selectedSamples(many, selectedID: selectedID)
        suite.expect(drawn.count == TMobileCoverageMapDrawing.maximumSamples && drawn.contains { $0.id == selectedID },
                     "map drawing is bounded and retains the selected reading")
        suite.expect(many.count == 5_000, "map drawing never prunes the retained archive")

        let uninterrupted = TMobileCoverageChartDrawing.points(observations: [first, second], gaps: [], metric: .rsrp)
        suite.expect(uninterrupted.count == 2 && uninterrupted[0].segment == uninterrupted[1].segment,
                     "adjacent valid radio values form one continuous chart segment")
        let missing = observation(30, rsrp: nil)
        let sparse = TMobileCoverageChartDrawing.points(observations: [first, missing, second], gaps: [], metric: .rsrp)
        suite.expect(sparse.count == 2 && sparse[0].segment != sparse[1].segment,
                     "a missing radio value breaks the line instead of becoming zero")
        let gap = TMobileCoverageGap(startedAt: epoch.addingTimeInterval(10), endedAt: epoch.addingTimeInterval(50), reason: .sleep)
        let asleep = TMobileCoverageChartDrawing.points(observations: [first, second], gaps: [gap], metric: .rsrp)
        suite.expect(asleep.count == 2 && asleep[0].segment != asleep[1].segment,
                     "sleep gap breaks a line even when surrounding observations are close")
        let timed = TMobileCoverageChartDrawing.points(observations: [first, observation(600)], gaps: [], metric: .rsrp)
        suite.expect(timed[0].segment != timed[1].segment, "long unrecorded intervals never get a continuous radio line")

        let fix = TMobileCoverageLocationFix(coordinate: coordinate, timestamp: epoch, horizontalAccuracy: 20, source: .mac)
        let test = TMobileCoverageSpeedResult(startedAt: epoch, endedAt: epoch.addingTimeInterval(20),
                                              startLocation: fix, endLocation: fix, downloadMbps: 75)
        let speedReadings = [observation(30, speed: test), observation(60, speed: test)]
        let speedPoints = TMobileCoverageChartDrawing.points(observations: speedReadings, gaps: [], metric: .speed)
        suite.expect(speedPoints.count == 1 && speedPoints.first?.date == test.endedAt && speedPoints.first?.value == 75,
                     "reused speed result is plotted once at the actual test end time")
        let distinctTest = TMobileCoverageSpeedResult(startedAt: epoch, endedAt: test.endedAt,
                                                      startLocation: fix, endLocation: fix, downloadMbps: 100)
        suite.expect(TMobileCoverageChartDrawing.points(observations: [observation(30, speed: test), observation(60, speed: distinctTest)], gaps: [], metric: .speed).count == 2,
                     "distinct speed test identities are retained even if their timestamps coincide")
        let speedBins = TMobileCoverageMapDrawing.bins(observations: speedReadings, metric: .speed)
        suite.expect(speedBins.count == 1 && speedBins.first?.count == 1,
                     "reused speed test contributes only one measured speed bin value")
        let selectedSpeed = TMobileCoverageMapDrawing.positionedObservations(speedReadings, metric: .speed, selectedID: speedReadings[1].id)
        suite.expect(selectedSpeed.count == 1 && selectedSpeed.first?.id == speedReadings[1].id,
                     "deduplicated speed map keeps the selected owning observation")
        let ineligible = TMobileCoverageSpeedResult(startedAt: epoch, endedAt: epoch.addingTimeInterval(20),
                                                    startLocation: fix, endLocation: fix, downloadMbps: 75,
                                                    scoreEligible: false, invalidationReason: "Moved during test")
        let movedTest = observation(30, speed: ineligible)
        suite.expect(TMobileCoverageChartDrawing.points(observations: [movedTest], gaps: [], metric: .speed).count == 1
                     && TMobileCoverageChartDrawing.points(observations: [movedTest], gaps: [], metric: .score).isEmpty,
                     "actual ineligible speed remains visible without manufacturing a complete score")
        suite.expect(TMobileCoverageMapDrawing.coordinate(for: movedTest, metric: .speed) == nil,
                     "test invalidated during motion never paints map speed coverage")
        let relocatedSpeed = observation(30, speed: test, corrections: [.init(coordinate: .init(latitude: 41, longitude: -101), correctedAt: epoch)])
        suite.expect(TMobileCoverageMapDrawing.coordinate(for: relocatedSpeed, metric: .speed) == nil,
                     "manual correction to an unrelated place cannot relocate a speed test")
        let slightCorrection = observation(30, speed: test, corrections: [.init(coordinate: .init(latitude: 40.0001, longitude: -100), correctedAt: epoch)])
        suite.expect(TMobileCoverageMapDrawing.coordinate(for: slightCorrection, metric: .speed) == fix.coordinate,
                     "speed map preserves test coordinates even after a nearby observation correction")
        let preciseEnd = TMobileCoverageLocationFix(coordinate: coordinate, timestamp: test.endedAt,
                                                    horizontalAccuracy: 20, source: .mac)
        let oldEnd = TMobileCoverageLocationFix(coordinate: coordinate, timestamp: test.endedAt.addingTimeInterval(-31),
                                                horizontalAccuracy: 20, source: .mac)
        let staleSpeed = TMobileCoverageSpeedResult(startedAt: epoch, endedAt: test.endedAt,
                                                    startLocation: fix, endLocation: oldEnd, downloadMbps: 75)
        suite.expect(TMobileCoverageMapDrawing.coordinate(for: observation(30, speed: staleSpeed), metric: .speed) == nil,
                     "speed map rejects an endpoint fix older than 30 seconds even within radio-map tolerance")
        let coarseEnd = TMobileCoverageLocationFix(coordinate: coordinate, timestamp: test.endedAt,
                                                   horizontalAccuracy: 101, source: .mac)
        let coarseSpeed = TMobileCoverageSpeedResult(startedAt: epoch, endedAt: test.endedAt,
                                                     startLocation: fix, endLocation: coarseEnd, downloadMbps: 75)
        suite.expect(TMobileCoverageMapDrawing.coordinate(for: observation(30, speed: coarseSpeed), metric: .speed) == nil,
                     "speed map rejects accuracy worse than 100 metres even within radio-map tolerance")
        let boundaryStart = TMobileCoverageLocationFix(coordinate: coordinate, timestamp: epoch.addingTimeInterval(-30),
                                                        horizontalAccuracy: 100, source: .mac)
        let boundarySpeed = TMobileCoverageSpeedResult(startedAt: epoch, endedAt: test.endedAt,
                                                       startLocation: boundaryStart, endLocation: preciseEnd, downloadMbps: 75)
        suite.expect(TMobileCoverageMapDrawing.coordinate(for: observation(30, speed: boundarySpeed), metric: .speed) == coordinate,
                     "speed map accepts the documented 100 metre / 30 second location boundary")

        let series = TMobileCoverageChartDrawing.points(observations: many, gaps: [gap], metric: .rsrp)
        let decimated = TMobileCoverageChartDrawing.drawnPoints(series, selectedID: selectedID)
        suite.expect(decimated.count <= TMobileCoverageChartDrawing.maximumPoints + 1
                     && decimated.contains { $0.observationID == selectedID },
                     "chart drawing is bounded and retains the selected value")
        suite.expect(decimated.allSatisfy { point in series.contains { $0.id == point.id && $0.segment == point.segment } },
                     "chart decimation preserves source values and interruption segment IDs")
        let varied = [TMobileCoverageChartDrawing.Point(observationID: UUID(), date: epoch, value: -100, segment: 0),
                      .init(observationID: UUID(), date: epoch.addingTimeInterval(1), value: -155, segment: 0)]
        suite.expect(TMobileCoverageChartDrawing.domain(varied, metric: .rsrp).lowerBound <= -155,
                     "chart scale includes real outliers without clipping them")
        for (metric, value, expected) in [(TMobileCoverageMetric.rsrp, -95.0, TMobileSignalQuality.good),
                                           (.rsrp, -105, .fair), (.rsrp, -106, .poor),
                                           (.sinr, 13, .good), (.sinr, 0, .fair), (.sinr, -1, .poor)] {
            suite.expect(TMobileCoverageMapDrawing.quality(value: value, metric: metric) == expected,
                         "map and charts keep existing radio quality threshold at \(metric.rawValue) \(value)")
        }
        suite.expect(TMobileCoverageMapDrawing.quality(value: nil, metric: .score) == .unknown
                     && TMobileCoverageMapDrawing.quality(value: .nan, metric: .speed) == .unknown,
                     "unavailable values remain neutral")

        // SwiftUI value construction does not create a native map or fetch a basemap.
        let oldCaller = TMobileCoverageMapView(observations: [], towers: [], metric: .rsrp,
                                               displayMode: .heat, selectedObservationID: .constant(nil),
                                               onRegionChanged: { _ in })
        suite.expect(oldCaller.showsMeasurements && oldCaller.showsHeader && oldCaller.showsExplanations
                     && oldCaller.canvasHeight == 320 && oldCaller.selectedTowerID == nil,
                     "existing map callers retain default visible layers and layout")
        let towerID = UUID()
        let compact = TMobileCoverageMapView(observations: [], towers: [], metric: .rsrp,
                                             displayMode: .heat, selectedObservationID: .constant(nil),
                                             selectedTowerID: towerID, onTowerSelected: { _ in }, showsMeasurements: false,
                                             canvasHeight: 460, showsExplanations: false, showsHeader: false)
        suite.expect(!compact.showsMeasurements && !compact.showsHeader && !compact.showsExplanations
                     && compact.canvasHeight == 460 && compact.selectedTowerID == towerID && compact.onTowerSelected != nil,
                     "explorer can control tower selection and compact map chrome independently")

        typealias Target = TMobileCoverageMapDrawing.SelectionTarget
        func target(_ priorReading: UUID?, _ priorTower: UUID?, _ reading: UUID?, _ tower: UUID?,
                    _ current: Target?) -> Target? {
            TMobileCoverageMapDrawing.selectionTarget(previousReading: priorReading, previousTower: priorTower,
                                                       reading: reading, tower: tower, current: current)
        }
        suite.expect(target(nil, nil, first.id, towerID, nil) == .tower(towerID),
                     "explicit tower selection has priority when both controlled IDs change")
        let otherTowerID = UUID()
        suite.expect(target(first.id, towerID, first.id, otherTowerID, .tower(towerID)) == .tower(otherTowerID),
                     "choosing another tower produces explicit selection navigation to that tower")
        suite.expect(target(first.id, towerID, first.id, towerID, .tower(towerID)) == .tower(towerID),
                     "periodic observations preserve the active tower without requesting camera selection")
        suite.expect(target(first.id, towerID, first.id, towerID, .reading(second.id)) == .reading(second.id),
                     "unchanged controlled IDs preserve a newly clicked native reading")
        suite.expect(target(first.id, towerID, second.id, towerID, .tower(towerID)) == .reading(second.id),
                     "explicit reading selection can replace a tower callout")
        suite.expect(target(first.id, towerID, first.id, nil, .tower(towerID)) == nil,
                     "forgetting controlled tower selection clears its active pin")
        suite.expect(target(first.id, towerID, first.id, nil, .reading(first.id)) == .reading(first.id),
                     "clearing an inactive tower does not clear the active reading")
        suite.expect(target(first.id, nil, nil, nil, .reading(first.id)) == nil,
                     "clearing a controlled reading clears its active pin")

        let tower = TMobileTowerPin(id: towerID, name: "Synthetic community estimate", latitude: 40, longitude: -100,
                                    bands: "n41", cellID: nil, radio: .nr, provenance: "Synthetic OpenCellID reference")
        let towerText = TMobileCoverageMapDrawing.TowerPresentation(pin: tower)
        suite.expect(towerText.title == "5G NR · Synthetic community estimate" && !towerText.title.contains("UC"),
                     "tower technology label reports NR without inferring Ultra Capacity")
        suite.expect(towerText.subtitle.contains("Reference") && towerText.subtitle.contains("unverified")
                     && towerText.detail.contains("Synthetic OpenCellID reference")
                     && towerText.detail.contains("40.00000, -100.00000"),
                     "tower callout distinguishes its source and reported coordinates from measurements")
        let unspecified = TMobileTowerPin(name: "Synthetic unknown radio", latitude: 40, longitude: -100, bands: "n41", cellID: nil)
        suite.expect(TMobileCoverageMapDrawing.TowerPresentation(pin: unspecified).title.hasPrefix("Radio unspecified")
                     && TMobileCoverageMapDrawing.TowerPresentation(pin: unspecified).detail.contains("source unspecified"),
                     "tower labels do not infer radio technology or provenance from bands")
        let lte = TMobileTowerPin(name: "Synthetic LTE reference", latitude: 40, longitude: -100, bands: "B2", cellID: nil, radio: .lte)
        suite.expect(TMobileCoverageMapDrawing.TowerPresentation(pin: lte).title.hasPrefix("LTE ·"),
                     "LTE reference pins have an explicit technology label")
        let restoredRegion = MKCoordinateRegion(center: .init(latitude: 40, longitude: -100),
                                                span: .init(latitudeDelta: 0.2, longitudeDelta: 0.3))
        suite.expect(TMobileCoverageMapDrawing.validInitialRegion(restoredRegion), "a retained map area can be restored on recreation")
        suite.expect(!TMobileCoverageMapDrawing.validInitialRegion(nil)
                     && !TMobileCoverageMapDrawing.validInitialRegion(.init(center: .init(latitude: .nan, longitude: -100), span: restoredRegion.span))
                     && !TMobileCoverageMapDrawing.validInitialRegion(.init(center: restoredRegion.center, span: .init(latitudeDelta: 0, longitudeDelta: 0.3)))
                     && !TMobileCoverageMapDrawing.validInitialRegion(.init(center: restoredRegion.center, span: .init(latitudeDelta: 0.2, longitudeDelta: 361))),
                     "invalid retained regions cannot become native camera coordinates")

        let outer: [TMobileMapCoordinate] = [.init(latitude: 39, longitude: -101), .init(latitude: 39, longitude: -99),
                                            .init(latitude: 41, longitude: -99), .init(latitude: 41, longitude: -101),
                                            .init(latitude: 39, longitude: -101)]
        let hole: [TMobileMapCoordinate] = [.init(latitude: 39.5, longitude: -100.5), .init(latitude: 39.5, longitude: -99.5),
                                           .init(latitude: 40.5, longitude: -99.5), .init(latitude: 40.5, longitude: -100.5),
                                           .init(latitude: 39.5, longitude: -100.5)]
        let layer = TMobileCoverageMapReferenceOverlay(title: "Synthetic FCC model", provenance: "Synthetic local import",
                                                       polygons: [[outer, hole], [outer]], modeledSignalDBm: [-110, -70])
        let cache = TMobileCoverageMapDrawing.ReferenceGeometryCache()
        suite.expect(cache.update([layer]) && cache.polygons.count == 2, "modeled components each retain their own polygon")
        let originalPolygon = cache.polygons[0]
        suite.expect(originalPolygon.pointCount == outer.count && originalPolygon.interiorPolygons?.count == 1
                     && originalPolygon.interiorPolygons?.first?.pointCount == hole.count,
                     "FCC modeled polygon keeps its complete outer ring and interior hole")
        var retained = [CLLocationCoordinate2D](repeating: .init(), count: outer.count)
        originalPolygon.getCoordinates(&retained, range: NSRange(location: 0, length: retained.count))
        suite.expect(zip(retained, outer).allSatisfy { abs($0.latitude - $1.latitude) < 0.0000001
            && abs($0.longitude - $1.longitude) < 0.0000001 },
                     "FCC geometry keeps every original vertex without interpolation or clipping")
        var retainedHole = [CLLocationCoordinate2D](repeating: .init(), count: hole.count)
        originalPolygon.interiorPolygons?.first?.getCoordinates(&retainedHole, range: NSRange(location: 0, length: retainedHole.count))
        suite.expect(zip(retainedHole, hole).allSatisfy { abs($0.latitude - $1.latitude) < 0.0000001
            && abs($0.longitude - $1.longitude) < 0.0000001 }, "FCC geometry keeps every interior hole vertex")
        suite.expect(cache.signal(for: originalPolygon) == -110 && cache.signal(for: cache.polygons[1]) == -70,
                     "modeled minsignal values remain aligned with their source polygon components")
        suite.expect(!cache.update([layer]) && cache.polygons[0] === originalPolygon,
                     "unchanged references reuse exact native polygon objects across reading and selection updates")
        suite.expect(originalPolygon.title == layer.title && originalPolygon.subtitle == layer.provenance,
                     "cached modeled geometry retains local source labels")
        let legacy = TMobileCoverageMapReferenceOverlay(title: "Legacy footprint", provenance: "Synthetic source", polygons: [[outer, hole]])
        suite.expect(cache.update([legacy]) && cache.signal(for: cache.polygons[0]) == nil
                     && cache.polygons[0].interiorPolygons?.count == 1,
                     "legacy footprint layers retain holes without inventing a model signal value")
        let misaligned = TMobileCoverageMapReferenceOverlay(title: "Misaligned values", provenance: "Synthetic source",
                                                            polygons: [[outer], [outer]], modeledSignalDBm: [-90])
        cache.update([misaligned])
        suite.expect(cache.polygons.allSatisfy { cache.signal(for: $0) == nil },
                     "misaligned model values fall back to plain footprint blue instead of labeling the wrong component")
        let invalidValues = TMobileCoverageMapReferenceOverlay(title: "Invalid values", provenance: "Synthetic source",
                                                               polygons: [[outer], [outer], [outer]], modeledSignalDBm: [.nan, -121, -49])
        cache.update([invalidValues])
        suite.expect(cache.polygons.allSatisfy { cache.signal(for: $0) == nil },
                     "nonfinite and out-of-range source model signal values are never drawn as signal strength")
        suite.expect(cache.update([]) && cache.polygons.isEmpty, "removing reference layers removes their cached geometry")
        let weakBlue = TMobileCoverageMapDrawing.referenceColor(modeledSignalDBm: -120).usingColorSpace(.sRGB)!
        let strongBlue = TMobileCoverageMapDrawing.referenceColor(modeledSignalDBm: -50).usingColorSpace(.sRGB)!
        suite.expect(weakBlue.blueComponent > weakBlue.greenComponent && strongBlue.blueComponent > strongBlue.greenComponent
                     && weakBlue.greenComponent > strongBlue.greenComponent && weakBlue.redComponent > strongBlue.redComponent,
                     "weak to strong model gradient stays blue and becomes darker with stronger source signal")
        suite.expect((0.20...0.30).contains(weakBlue.alphaComponent) && (0.20...0.30).contains(strongBlue.alphaComponent)
                     && (0.20...0.30).contains(TMobileCoverageMapDrawing.referenceColor(modeledSignalDBm: nil).alphaComponent),
                     "modeled signal and footprint fills stay visibly translucent")
        suite.expect(TMobileCoverageMapDrawing.referenceColor(modeledSignalDBm: .infinity)
                     == TMobileCoverageMapDrawing.referenceColor(modeledSignalDBm: nil),
                     "invalid model strength uses the same blue fallback as an unknown value")
        suite.expect(TMobileCoverageMapDrawing.color(value: -95, metric: .rsrp) == .systemGreen
                     && TMobileCoverageMapDrawing.color(value: -105, metric: .rsrp) == .systemOrange
                     && TMobileCoverageMapDrawing.color(value: -106, metric: .rsrp) == .systemRed,
                     "measured quality colors remain distinct from the modeled blue gradient")
        let referenceRect = originalPolygon.boundingMapRect
        let positionPoint = MKMapPoint(CLLocationCoordinate2D(latitude: coordinate.latitude, longitude: coordinate.longitude))
        let localFit = TMobileCoverageMapDrawing.fitRect(positions: [coordinate], measuredRects: [bins[0].mapRect],
                                                        referenceRects: [referenceRect], includesAllLayers: false)
        suite.expect(localFit.contains(positionPoint) && localFit.width < referenceRect.width / 100,
                     "initial camera prefers actual measured locations over large complete modeled polygons")
        let towerOnlyFit = TMobileCoverageMapDrawing.fitRect(positions: [tower.coordinate], measuredRects: [],
                                                            referenceRects: [referenceRect], includesAllLayers: false)
        suite.expect(towerOnlyFit.contains(positionPoint) && towerOnlyFit.width < referenceRect.width / 100,
                     "initial camera prefers tower reference coordinates when there are no measurements")
        let fullFit = TMobileCoverageMapDrawing.fitRect(positions: [coordinate], measuredRects: [bins[0].mapRect],
                                                       referenceRects: [referenceRect], includesAllLayers: true)
        suite.expect(fullFit.contains(referenceRect) && fullFit.contains(bins[0].mapRect),
                     "explicit Fit all includes every visible modeled and measured extent")
        let modelOnlyFit = TMobileCoverageMapDrawing.fitRect(positions: [], measuredRects: [],
                                                            referenceRects: [referenceRect], includesAllLayers: false)
        suite.expect(modelOnlyFit.contains(referenceRect), "model-only map initially fits its complete source geometry")
        suite.expect(TMobileCoverageMapDrawing.fitRect(positions: [.init(latitude: .nan, longitude: 0)],
                                                       measuredRects: [], referenceRects: [], includesAllLayers: false).isNull,
                     "empty or invalid positions never invent camera geometry")
    }
}
