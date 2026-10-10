// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

enum TMobileCoverageLocationSource: String, Codable, CaseIterable {
    case mac, manual, shadow, gateway
    var title: String {
        switch self {
        case .mac: return "Mac Location Services"
        case .manual: return "Manual correction"
        case .shadow: return "Shadow GPS"
        case .gateway: return "Gateway GPS"
        }
    }
}

struct TMobileCoverageLocationFix: Codable, Equatable {
    let coordinate: TMobileMapCoordinate
    let timestamp: Date
    let horizontalAccuracy: Double
    let source: TMobileCoverageLocationSource

    var isValid: Bool {
        coordinate.isValid && TMobileCoverageSupport.validDate(timestamp)
            && horizontalAccuracy.isFinite && (0...100_000).contains(horizontalAccuracy)
    }

    /// A valid archived fix can still be too stale or imprecise to paint a route.
    func isUsable(at date: Date) -> Bool {
        isValid && TMobileCoverageSupport.validDate(date) && horizontalAccuracy <= 200
            && (-5...60).contains(date.timeIntervalSince(timestamp))
    }

    func distance(to other: TMobileCoverageLocationFix) -> Double {
        TMobileCoverageSupport.distance(coordinate, other.coordinate)
    }
}

struct TMobileCoverageLocationCorrection: Codable, Equatable, Identifiable {
    let id: UUID
    let coordinate: TMobileMapCoordinate
    let correctedAt: Date
    init(id: UUID = UUID(), coordinate: TMobileMapCoordinate, correctedAt: Date = Date()) {
        self.id = id; self.coordinate = coordinate; self.correctedAt = correctedAt
    }
    var isValid: Bool { coordinate.isValid && TMobileCoverageSupport.validDate(correctedAt) }
}

struct TMobileCoverageSpeedResult: Codable, Equatable, Identifiable {
    let id: UUID
    let startedAt: Date
    let endedAt: Date
    let startLocation: TMobileCoverageLocationFix?
    let endLocation: TMobileCoverageLocationFix?
    let downloadMbps: Double
    let uploadMbps: Double?
    let latencyMilliseconds: Double?
    let provider: String
    let scoreEligible: Bool
    let invalidationReason: String?

    init(id: UUID = UUID(), startedAt: Date, endedAt: Date,
         startLocation: TMobileCoverageLocationFix?, endLocation: TMobileCoverageLocationFix?,
         downloadMbps: Double, uploadMbps: Double? = nil, latencyMilliseconds: Double? = nil,
         provider: String = "Cloudflare", scoreEligible: Bool = true, invalidationReason: String? = nil) {
        self.id = id; self.startedAt = startedAt; self.endedAt = endedAt
        self.startLocation = startLocation; self.endLocation = endLocation
        self.downloadMbps = downloadMbps; self.uploadMbps = uploadMbps
        self.latencyMilliseconds = latencyMilliseconds; self.provider = provider
        self.scoreEligible = scoreEligible; self.invalidationReason = invalidationReason
    }

    var isValid: Bool {
        TMobileCoverageSupport.validDate(startedAt) && TMobileCoverageSupport.validDate(endedAt)
            && (0...600).contains(endedAt.timeIntervalSince(startedAt))
            && downloadMbps.isFinite && (0...100_000).contains(downloadMbps)
            && (uploadMbps.map { $0.isFinite && (0...100_000).contains($0) } ?? true)
            && (latencyMilliseconds.map { $0.isFinite && (0...120_000).contains($0) } ?? true)
            && (startLocation?.isValid ?? true) && (endLocation?.isValid ?? true)
            && TMobileCoverageSupport.validText(provider, maximum: 80, allowEmpty: false)
            && (invalidationReason.map { TMobileCoverageSupport.validText($0, maximum: 240) } ?? true)
    }
}

struct TMobileCoverageObservation: Codable, Equatable, Identifiable {
    let id: UUID
    let date: Date
    let snapshot: TMobileGatewaySnapshot
    let location: TMobileCoverageLocationFix?
    var corrections: [TMobileCoverageLocationCorrection]
    var speedTest: TMobileCoverageSpeedResult?
    // A versioned custom score, not a carrier or industry coverage measure.
    let scoreFormulaVersion: String

    init(id: UUID = UUID(), date: Date, snapshot: TMobileGatewaySnapshot,
         location: TMobileCoverageLocationFix?, corrections: [TMobileCoverageLocationCorrection] = [],
         speedTest: TMobileCoverageSpeedResult? = nil, scoreFormulaVersion: String = TMobileCoverageSupport.scoreFormulaVersion) {
        self.id = id; self.date = date; self.snapshot = snapshot; self.location = location
        self.corrections = corrections; self.speedTest = speedTest; self.scoreFormulaVersion = scoreFormulaVersion
    }

    var observedAt: Date { date }
    var correction: TMobileCoverageLocationCorrection? { corrections.last }
    var effectiveCoordinate: TMobileMapCoordinate? { correction?.coordinate ?? location?.coordinate }
    var coordinate: TMobileMapCoordinate? { effectiveCoordinate }
    var effectiveLocation: TMobileCoverageLocationFix? {
        if let correction {
            // Zero is a manual marker, not a claim of measured GPS accuracy.
            return .init(coordinate: correction.coordinate, timestamp: date, horizontalAccuracy: 0, source: .manual)
        }
        return location
    }
    var primaryRadio: TMobileRadioSignal? { TMobileGatewayConnectedRadioSupport.select(from: snapshot)?.radio }
    var rsrp: Double? { primaryRadio?.rsrp }
    var sinr: Double? { primaryRadio?.sinr }
    var downloadMbps: Double? { speedTest?.downloadMbps }
    var connectionScore: Double? { TMobileCoverageSupport.connectionScore(for: self) }
    var isValid: Bool {
        TMobileCoverageSupport.validDate(date) && TMobileGatewaySupport.isValidSnapshot(snapshot)
            && (location?.isValid ?? true) && corrections.count <= 10_000
            && corrections.allSatisfy(\.isValid)
            && Set(corrections.map(\.id)).count == corrections.count
            && (speedTest?.isValid ?? true) && scoreFormulaVersion == TMobileCoverageSupport.scoreFormulaVersion
    }
}

enum TMobileCoverageMetric: String, Codable, CaseIterable, Identifiable {
    case rsrp, sinr, speed, score
    var id: String { rawValue }
    var title: String {
        switch self { case .rsrp: return "Signal strength"; case .sinr: return "Signal quality"
        case .speed: return "Tested download"; case .score: return "Connection Score" }
    }
    var unit: String {
        switch self { case .rsrp: return "dBm"; case .sinr: return "dB"; case .speed: return "Mbps"; case .score: return "/100" }
    }
    func value(in observation: TMobileCoverageObservation) -> Double? {
        switch self { case .rsrp: return observation.rsrp; case .sinr: return observation.sinr
        case .speed: return observation.downloadMbps; case .score: return observation.connectionScore }
    }
}

enum TMobileCoverageGapReason: String, Codable, CaseIterable {
    case sleep, wake, gatewayUnavailable, locationUnavailable, appClosed, recordingPaused
    var title: String {
        switch self { case .sleep: return "Mac asleep"; case .wake: return "Recording resumed after sleep"
        case .gatewayUnavailable: return "Gateway unavailable"; case .locationUnavailable: return "Location unavailable"
        case .appClosed: return "App closed"; case .recordingPaused: return "Recording paused" }
    }
}

struct TMobileCoverageGap: Codable, Equatable, Identifiable {
    let id: UUID
    let startedAt: Date
    let endedAt: Date?
    let reason: TMobileCoverageGapReason
    init(id: UUID = UUID(), startedAt: Date, endedAt: Date? = nil, reason: TMobileCoverageGapReason) {
        self.id = id; self.startedAt = startedAt; self.endedAt = endedAt; self.reason = reason
    }
    var isValid: Bool {
        TMobileCoverageSupport.validDate(startedAt)
            && (endedAt.map { TMobileCoverageSupport.validDate($0) && $0 >= startedAt } ?? true)
    }
}

struct TMobileCoverageTestedStop: Codable, Equatable, Identifiable {
    let id: UUID
    let location: TMobileCoverageLocationFix
    let testedAt: Date
    init(id: UUID = UUID(), location: TMobileCoverageLocationFix, testedAt: Date = Date()) {
        self.id = id; self.location = location; self.testedAt = testedAt
    }
    var isValid: Bool { location.isUsable(at: testedAt) && TMobileCoverageSupport.validDate(testedAt) }
}

struct TMobileCoverageSession: Codable, Equatable, Identifiable {
    let id: UUID
    let name: String
    let startedAt: Date
    var endedAt: Date?
    var observationCount: Int
    var speedTestCount: Int
    var gapCount: Int
    init(id: UUID = UUID(), name: String, startedAt: Date, endedAt: Date? = nil,
         observationCount: Int = 0, speedTestCount: Int = 0, gapCount: Int = 0) {
        self.id = id; self.name = name; self.startedAt = startedAt; self.endedAt = endedAt
        self.observationCount = observationCount; self.speedTestCount = speedTestCount; self.gapCount = gapCount
    }
    var isValid: Bool {
        TMobileCoverageSupport.validText(name, maximum: 100, allowEmpty: false)
            && TMobileCoverageSupport.validDate(startedAt)
            && (endedAt.map { TMobileCoverageSupport.validDate($0) && $0 >= startedAt } ?? true)
            && observationCount >= 0 && speedTestCount >= 0 && gapCount >= 0
    }
}

/// Serialization contract only. There is deliberately no endpoint, token or uploader.
/// A later tailnet connector must acknowledge immutable event IDs; acknowledgment
/// never permits it to delete this Mac's retained archive automatically.
struct TMobileCoverageSyncEnvelope: Codable, Equatable {
    let schemaVersion: Int
    let batchID: UUID
    let sessionID: UUID
    let events: [TMobileCoverageJournalEvent]
    let hasMore: Bool
    let nextSequence: UInt64?
    let syncEnabled: Bool
}

struct TMobileCoverageJournalEvent: Codable, Equatable, Identifiable {
    let schemaVersion: Int
    let id: UUID
    let sessionID: UUID
    let sequence: UInt64
    let createdAt: Date
    let payload: Payload
    enum Payload: Codable, Equatable {
        case session(TMobileCoverageSession)
        case observation(TMobileCoverageObservation)
        case speed(observationID: UUID, result: TMobileCoverageSpeedResult)
        case correction(observationID: UUID, correction: TMobileCoverageLocationCorrection)
        case gap(TMobileCoverageGap)
        case testedStop(TMobileCoverageTestedStop)
        case ended(Date)
    }
}

enum TMobileCoverageSupport {
    static let scoreFormulaVersion = "balanced-v1"
    static let maximumEventBytes = 262_144

    static func validDate(_ date: Date) -> Bool {
        date.timeIntervalSince1970.isFinite && (0...32_503_680_000).contains(date.timeIntervalSince1970)
    }
    static func validText(_ text: String, maximum: Int, allowEmpty: Bool = true) -> Bool {
        (allowEmpty || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            && text.count <= maximum && text.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) }
    }
    static func distance(_ first: TMobileMapCoordinate, _ second: TMobileMapCoordinate) -> Double {
        guard first.isValid && second.isValid else { return .infinity }
        let radians = Double.pi / 180
        let deltaLat = (second.latitude - first.latitude) * radians
        let deltaLon = (second.longitude - first.longitude) * radians
        let a = pow(sin(deltaLat / 2), 2) + cos(first.latitude * radians) * cos(second.latitude * radians) * pow(sin(deltaLon / 2), 2)
        return 6_371_000 * 2 * atan2(sqrt(min(1, max(0, a))), sqrt(max(0, 1 - a)))
    }
    static func normalized(_ value: Double, from low: Double, to high: Double) -> Double {
        min(100, max(0, (value - low) / (high - low) * 100))
    }
    static func connectionScore(for observation: TMobileCoverageObservation) -> Double? {
        guard observation.isValid, let rsrp = observation.rsrp, let sinr = observation.sinr,
              let speed = observation.speedTest, speed.scoreEligible,
              let origin = observation.location, origin.isUsable(at: observation.date),
              let start = speed.startLocation, start.isUsable(at: speed.startedAt),
              let end = speed.endLocation, end.isUsable(at: speed.endedAt),
              abs(speed.startedAt.timeIntervalSince(observation.date)) <= 300,
              abs(speed.endedAt.timeIntervalSince(observation.date)) <= 300,
              start.distance(to: end) <= 100, origin.distance(to: start) <= 150,
              origin.distance(to: end) <= 150 else { return nil }
        // A correction relocates the observation, never an unrelated speed test.
        if let correction = observation.correction,
           distance(correction.coordinate, start.coordinate) > 150 { return nil }
        return (normalized(rsrp, from: -120, to: -80)
                + normalized(sinr, from: -5, to: 25)
                + normalized(speed.downloadMbps, from: 0, to: 150)) / 3
    }
}
