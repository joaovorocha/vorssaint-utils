// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Pure dwell detection. Neither the detector nor its tests read location,
/// start network requests, persist state, or assume that the Mac has GPS.
struct TMobileCoverageParkedDetector {
    struct Configuration {
        var dwell: TimeInterval = 120
        var maximumFixAge: TimeInterval = 30
        var maximumAccuracy: Double = 100
        var stabilityRadius: Double = 100
        var newPlaceDistance: Double = 250
        var cooldown: TimeInterval = 15 * 60
    }

    struct TestedStop {
        let location: TMobileCoverageLocationFix
        let testedAt: Date
    }

    enum State: Equatable {
        case waitingForLocation
        case settling(secondsRemaining: Int)
        case alreadyTestedHere
        case cooldown(until: Date)
        case ready
    }

    private(set) var state: State = .waitingForLocation
    private let configuration: Configuration
    private var anchor: TMobileCoverageLocationFix?
    private var settledSince: Date?
    private var lastEvaluation: Date?
    private var attemptedHere = false

    init(configuration: Configuration = .init()) { self.configuration = configuration }

    mutating func reset() {
        anchor = nil
        settledSince = nil
        lastEvaluation = nil
        attemptedHere = false
        state = .waitingForLocation
    }

    mutating func markAttempted() { attemptedHere = true; state = .alreadyTestedHere }

    /// A stop is new only when even the nearest edges of its uncertainty
    /// circles are more than 250 m apart. The last persisted attempt suppresses
    /// retries after a relaunch, including failed and cancelled tests.
    mutating func update(fix: TMobileCoverageLocationFix?, at now: Date,
                         testedStops: [TestedStop]) -> TMobileCoverageLocationFix? {
        guard let fix, Self.usable(fix, at: now, maximumAge: configuration.maximumFixAge,
                                  maximumAccuracy: configuration.maximumAccuracy), fix.source == .mac else {
            reset()
            return nil
        }
        let uninterrupted = lastEvaluation.map {
            now.timeIntervalSince($0) >= 0 && now.timeIntervalSince($0) <= configuration.maximumFixAge
        } ?? false
        let stable = anchor.map {
            $0.distance(to: fix) + max($0.horizontalAccuracy, fix.horizontalAccuracy) <= configuration.stabilityRadius
        } ?? false
        if !uninterrupted || !stable {
            anchor = fix
            settledSince = now
            attemptedHere = false
        }
        lastEvaluation = now

        if attemptedHere { state = .alreadyTestedHere; return nil }
        if let last = testedStops.max(by: { $0.testedAt < $1.testedAt }) {
            let certainDistance = last.location.distance(to: fix)
                - last.location.horizontalAccuracy - fix.horizontalAccuracy
            guard certainDistance > configuration.newPlaceDistance else {
                state = .alreadyTestedHere
                return nil
            }
            let readyAt = last.testedAt.addingTimeInterval(configuration.cooldown)
            guard now >= readyAt else { state = .cooldown(until: readyAt); return nil }
        }
        let elapsed = now.timeIntervalSince(settledSince ?? now)
        guard elapsed >= configuration.dwell else {
            state = .settling(secondsRemaining: Int(ceil(configuration.dwell - elapsed)))
            return nil
        }
        state = .ready
        return fix
    }

    static func usable(_ fix: TMobileCoverageLocationFix, at date: Date,
                       maximumAge: TimeInterval = 30, maximumAccuracy: Double = 100) -> Bool {
        fix.isValid && fix.horizontalAccuracy <= maximumAccuracy
            && date.timeIntervalSince(fix.timestamp) >= 0
            && date.timeIntervalSince(fix.timestamp) <= maximumAge
    }
}

/// Only connection attributes identify the radio context. Changing RSRP or
/// SINR is expected during a test and must not by itself invalidate the result.
struct TMobileCoverageRadioIdentity: Equatable {
    let technology: String
    let bands: [String]
    let cellID: UInt64?
    let nodeID: UInt32?
    let channel: Int?
    let physicalCellID: Int?
    let trackingAreaCode: UInt32?
    let ecgi: String?
    let lteAnchorBands: [String]
    let lteAnchorCellID: UInt64?
    let lteAnchorNodeID: UInt32?
    let lteAnchorChannel: Int?
    let lteAnchorPhysicalCellID: Int?
    let lteAnchorTrackingAreaCode: UInt32?
    let lteAnchorECGI: String?

    init?(snapshot: TMobileGatewaySnapshot) {
        guard let connected = TMobileGatewayConnectedRadioSupport.select(from: snapshot) else { return nil }
        technology = connected.technologyLabel
        let radio = connected.radio
        bands = radio.bands.sorted()
        cellID = radio.cellID
        nodeID = connected.technology == .fiveG ? radio.gNodeBID : radio.eNodeBID
        channel = radio.channel
        physicalCellID = radio.physicalCellID
        trackingAreaCode = radio.trackingAreaCode
        ecgi = radio.ecgi
        let anchor = connected.technology == .fiveG && snapshot.lte?.rsrp != nil ? snapshot.lte : nil
        lteAnchorBands = anchor?.bands.sorted() ?? []
        lteAnchorCellID = anchor?.cellID
        lteAnchorNodeID = anchor?.eNodeBID
        lteAnchorChannel = anchor?.channel
        lteAnchorPhysicalCellID = anchor?.physicalCellID
        lteAnchorTrackingAreaCode = anchor?.trackingAreaCode
        lteAnchorECGI = anchor?.ecgi
    }
}

struct TMobileCoverageSpeedContext {
    let startedAt: Date
    let startLocation: TMobileCoverageLocationFix?
    let identity: TMobileCoverageRadioIdentity?
    private(set) var invalidationReason: String?

    init(startedAt: Date, startLocation: TMobileCoverageLocationFix?, snapshot: TMobileGatewaySnapshot) {
        self.startedAt = startedAt
        self.startLocation = startLocation
        identity = TMobileCoverageRadioIdentity(snapshot: snapshot)
        if startLocation.map({ TMobileCoverageParkedDetector.usable($0, at: startedAt) }) != true {
            invalidationReason = "A fresh, accurate location was unavailable at the start"
        } else if identity == nil {
            invalidationReason = "The serving radio was unavailable at the start"
        }
    }

    mutating func validate(location: TMobileCoverageLocationFix?, snapshot: TMobileGatewaySnapshot?,
                           snapshotDate: Date?, at date: Date) {
        guard invalidationReason == nil else { return }
        guard let location, TMobileCoverageParkedDetector.usable(location, at: date), let startLocation else {
            invalidationReason = "Location became unavailable or stale during the test"
            return
        }
        guard startLocation.distance(to: location) + max(startLocation.horizontalAccuracy, location.horizontalAccuracy) <= 100 else {
            invalidationReason = "The Mac moved during the test"
            return
        }
        guard let snapshot, let snapshotDate, date.timeIntervalSince(snapshotDate) >= 0,
              date.timeIntervalSince(snapshotDate) <= 30 else {
            invalidationReason = "The radio reading became unavailable or stale during the test"
            return
        }
        guard TMobileCoverageRadioIdentity(snapshot: snapshot) == identity else {
            invalidationReason = "The serving radio or band changed during the test"
            return
        }
    }
}
