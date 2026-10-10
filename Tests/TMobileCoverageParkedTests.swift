// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

enum TMobileCoverageParkedTests {
    static func run(_ suite: TestSuite) {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        func fix(_ seconds: Double, latitude: Double = 40, accuracy: Double = 20,
                 source: TMobileCoverageLocationSource = .mac) -> TMobileCoverageLocationFix {
            .init(coordinate: .init(latitude: latitude, longitude: -100),
                  timestamp: start.addingTimeInterval(seconds), horizontalAccuracy: accuracy, source: source)
        }
        func drive(_ detector: inout TMobileCoverageParkedDetector, from: Int = 0, through: Int = 120,
                   latitude: Double = 40,
                   stops: [TMobileCoverageParkedDetector.TestedStop] = []) -> TMobileCoverageLocationFix? {
            var candidate: TMobileCoverageLocationFix?
            for seconds in stride(from: from, through: through, by: 10) {
                candidate = detector.update(fix: fix(Double(seconds), latitude: latitude),
                    at: start.addingTimeInterval(Double(seconds)), testedStops: stops)
            }
            return candidate
        }

        var stationary = TMobileCoverageParkedDetector()
        suite.expect(drive(&stationary, through: 110) == nil, "a parked stop never tests before two minutes")
        suite.expect(stationary.update(fix: fix(120), at: start.addingTimeInterval(120), testedStops: []) != nil,
                     "two uninterrupted minutes of fresh accurate fixes qualify a stop")
        stationary.markAttempted()
        suite.expect(stationary.update(fix: fix(130), at: start.addingTimeInterval(130), testedStops: []) == nil,
                     "one test attempt is allowed per stationary stop")

        var interrupted = TMobileCoverageParkedDetector()
        _ = interrupted.update(fix: fix(0), at: start, testedStops: [])
        suite.expect(interrupted.update(fix: fix(120), at: start.addingTimeInterval(120), testedStops: []) == nil,
                     "a long observation gap does not count as parked dwell")
        suite.expect(drive(&interrupted, from: 130, through: 240) != nil, "continuous fresh dwell can restart after a gap")
        interrupted.reset()
        suite.expect(interrupted.update(fix: fix(250), at: start.addingTimeInterval(250), testedStops: []) == nil,
                     "wake/reset requires new dwell rather than using a pre-sleep anchor")

        var moving = TMobileCoverageParkedDetector()
        _ = drive(&moving, through: 110)
        suite.expect(moving.update(fix: fix(120, latitude: 40.002), at: start.addingTimeInterval(120), testedStops: []) == nil,
                     "movement beyond the stability radius resets a pending parked test")

        for bad in [fix(0, accuracy: 101), fix(0, accuracy: -1), fix(0, latitude: 91), fix(0, source: .manual)] {
            var detector = TMobileCoverageParkedDetector()
            suite.expect(detector.update(fix: bad, at: start, testedStops: []) == nil && detector.state == .waitingForLocation,
                         "invalid, imprecise and manually corrected positions cannot trigger an automatic test")
        }
        var stale = TMobileCoverageParkedDetector()
        suite.expect(stale.update(fix: fix(0), at: start.addingTimeInterval(31), testedStops: []) == nil,
                     "a fix older than 30 seconds cannot trigger parked testing")
        suite.expect(stale.update(fix: fix(1), at: start, testedStops: []) == nil,
                     "a future timestamp is not treated as a fresh fix")
        suite.expect(stale.update(fix: nil, at: start, testedStops: []) == nil,
                     "missing location pauses dwell detection")

        let previous = TMobileCoverageParkedDetector.TestedStop(location: fix(-1000), testedAt: start.addingTimeInterval(-1000))
        var relaunched = TMobileCoverageParkedDetector()
        suite.expect(drive(&relaunched, stops: [previous]) == nil && relaunched.state == .alreadyTestedHere,
                     "a persisted stop prevents an automatic retry after relaunch")
        var near = TMobileCoverageParkedDetector()
        suite.expect(drive(&near, latitude: 40.002, stops: [previous]) == nil,
                     "a stop less than 250 metres away is not a new place")
        let uncertain = TMobileCoverageParkedDetector.TestedStop(location: fix(-1000, accuracy: 100), testedAt: start.addingTimeInterval(-1000))
        var uncertainPlace = TMobileCoverageParkedDetector()
        suite.expect(drive(&uncertainPlace, latitude: 40.003, stops: [uncertain]) == nil,
                     "new-place distance subtracts both reported location uncertainty radii")
        var newPlace = TMobileCoverageParkedDetector()
        suite.expect(drive(&newPlace, latitude: 40.004, stops: [previous]) != nil,
                     "a sufficiently distant stop qualifies after the persisted cooldown")
        let recent = TMobileCoverageParkedDetector.TestedStop(location: fix(0), testedAt: start)
        var cooldown = TMobileCoverageParkedDetector()
        suite.expect(drive(&cooldown, latitude: 40.004, stops: [recent]) == nil,
                     "a new stop cannot bypass the 15-minute data-use cooldown")
        suite.expect(drive(&cooldown, from: 780, through: 900, latitude: 40.004, stops: [recent]) != nil,
                     "a new stop qualifies after cooldown and a fresh complete dwell")
        let otherPlace = TMobileCoverageParkedDetector.TestedStop(location: fix(-1000, latitude: 40.004), testedAt: start.addingTimeInterval(-1000))
        var returnVisit = TMobileCoverageParkedDetector()
        let olderVisit = TMobileCoverageParkedDetector.TestedStop(location: fix(-2000), testedAt: start.addingTimeInterval(-2000))
        suite.expect(drive(&returnVisit, stops: [olderVisit, otherPlace]) != nil,
                     "a later return visit can be measured after testing a different stop")

        func snapshot(_ bands: [String] = ["n41"], rsrp: Double = -95, cell: UInt64 = 12) -> TMobileGatewaySnapshot {
            .init(model: nil, firmware: nil, uptime: nil, registration: "Registered", roaming: nil, lte: nil,
                  fiveG: .init(bars: 4, bands: bands, rsrp: rsrp, rsrq: -10, rssi: -65, sinr: 15, cellID: cell))
        }
        var valid = TMobileCoverageSpeedContext(startedAt: start, startLocation: fix(0), snapshot: snapshot())
        valid.validate(location: fix(10), snapshot: snapshot(rsrp: -100), snapshotDate: start.addingTimeInterval(10), at: start.addingTimeInterval(10))
        suite.expect(valid.invalidationReason == nil, "changing signal measurements retains the same serving-radio speed context")
        var bandChanged = valid
        bandChanged.validate(location: fix(20), snapshot: snapshot(["n25"]), snapshotDate: start.addingTimeInterval(20), at: start.addingTimeInterval(20))
        suite.expect(bandChanged.invalidationReason != nil, "a band change excludes a speed result from the combined score")
        bandChanged.validate(location: fix(21), snapshot: snapshot(), snapshotDate: start.addingTimeInterval(21), at: start.addingTimeInterval(21))
        suite.expect(bandChanged.invalidationReason != nil, "returning to the original band does not erase a mid-test context change")
        var cellChanged = valid
        cellChanged.validate(location: fix(20), snapshot: snapshot(cell: 13), snapshotDate: start.addingTimeInterval(20), at: start.addingTimeInterval(20))
        suite.expect(cellChanged.invalidationReason != nil, "a serving-cell change excludes a speed result from the combined score")
        var moved = valid
        moved.validate(location: fix(20, latitude: 40.002), snapshot: snapshot(), snapshotDate: start.addingTimeInterval(20), at: start.addingTimeInterval(20))
        suite.expect(moved.invalidationReason != nil, "a moving speed test is retained without a point Connection Score")
        var missingFix = valid
        missingFix.validate(location: nil, snapshot: snapshot(), snapshotDate: start.addingTimeInterval(20), at: start.addingTimeInterval(20))
        suite.expect(missingFix.invalidationReason != nil, "lost location excludes a speed result from the combined score")
        var oldRadio = valid
        oldRadio.validate(location: fix(40), snapshot: snapshot(), snapshotDate: start, at: start.addingTimeInterval(40))
        suite.expect(oldRadio.invalidationReason != nil, "a cached radio snapshot cannot score a later speed test")
        let unlocated = TMobileCoverageSpeedContext(startedAt: start, startLocation: nil, snapshot: snapshot())
        suite.expect(unlocated.invalidationReason != nil, "a manually started test without location has no combined score")
        suite.expect(TMobileCoverageRadioIdentity(snapshot: snapshot(["n41", "n25"])) == TMobileCoverageRadioIdentity(snapshot: snapshot(["n25", "n41"])),
                     "band ordering alone does not imply a serving-radio change")
        func withAnchor(_ bands: [String]) -> TMobileGatewaySnapshot {
            let base = snapshot()
            return .init(model: nil, firmware: nil, uptime: nil, registration: "Registered", roaming: nil,
                         lte: .init(bars: 4, bands: bands, rsrp: -90, rsrq: -10, rssi: -60, sinr: 10), fiveG: base.fiveG)
        }
        var changedAnchor = TMobileCoverageSpeedContext(startedAt: start, startLocation: fix(0), snapshot: withAnchor(["b2"]))
        changedAnchor.validate(location: fix(10), snapshot: withAnchor(["b66"]), snapshotDate: start.addingTimeInterval(10), at: start.addingTimeInterval(10))
        suite.expect(changedAnchor.invalidationReason != nil, "an LTE anchor band change also invalidates the 5G test context")
    }
}
