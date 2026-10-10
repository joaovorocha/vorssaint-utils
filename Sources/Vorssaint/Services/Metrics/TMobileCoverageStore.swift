// SPDX-License-Identifier: GPL-3.0-or-later
import Combine
import CryptoKit
import Darwin
import Foundation

/// Durable, local-only archive. Each mutation commits one bounded immutable
/// event before published state changes. No retention timer or network client.
@MainActor final class TMobileCoverageStore: ObservableObject {
    static let shared = TMobileCoverageStore()
    @Published private(set) var sessions: [TMobileCoverageSession] = []
    @Published private(set) var observations: [TMobileCoverageObservation] = []
    @Published private(set) var gaps: [TMobileCoverageGap] = []
    @Published private(set) var selectedSessionID: UUID?
    @Published private(set) var currentSessionID: UUID?
    @Published private(set) var testedStops: [TMobileCoverageTestedStop] = []
    @Published private(set) var errorMessage: String?
    let syncEnabled = false

    private let folder: URL
    private var active: State?
    private var archiveWarning: String?

    private struct State {
        var session: TMobileCoverageSession
        var observations: [TMobileCoverageObservation] = []
        var gaps: [TMobileCoverageGap] = []
        var testedStops: [TMobileCoverageTestedStop] = []
        var events: [TMobileCoverageJournalEvent] = []
        var writable = true
        mutating func refreshCounts() {
            session.observationCount = observations.count
            session.speedTestCount = observations.filter { $0.speedTest != nil }.count
            session.gapCount = gaps.count
        }
    }

    enum ArchiveError: LocalizedError {
        case invalidRecord, corruptArchive, missingSession, persistence
        var errorDescription: String? {
            switch self {
            case .invalidRecord: return "The measurement contains invalid or unreasonable values and was not saved."
            case .corruptArchive: return "Some saved coverage data could not be read. The original files were preserved; this session cannot accept more records."
            case .missingSession: return "The selected coverage session is unavailable."
            case .persistence: return "Coverage data could not be saved on this Mac. Recording has not advanced. Check available storage and folder permissions."
            }
        }
    }

    init(folder: URL? = nil) {
        self.folder = folder ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "io.github.joaovorocha.shadowutils", isDirectory: true)
            .appendingPathComponent("T-Mobile/Coverage", isDirectory: true)
        loadSummaries()
        // Recording never restarts merely because the app was relaunched.
        if let latest = sessions.first { selectSession(latest.id) }
    }

    @discardableResult func beginSession(name: String = "Coverage session", at date: Date = Date()) -> UUID? {
        guard currentSessionID == nil else { return currentSessionID }
        let session = TMobileCoverageSession(name: name, startedAt: date)
        guard session.isValid else { fail(.invalidRecord); return nil }
        var state = State(session: session)
        guard commit(.session(session), at: date, to: &state) else { return nil }
        active = state; currentSessionID = session.id; selectedSessionID = session.id
        publish(state); return session.id
    }

    func endSession(at date: Date = Date()) {
        guard var state = active else { return }
        guard TMobileCoverageSupport.validDate(date), date >= state.session.startedAt,
              date >= (state.observations.last?.date ?? state.session.startedAt)
        else { fail(.invalidRecord); return }
        guard commit(.ended(date), at: date, to: &state) else { return }
        publish(state); active = nil; currentSessionID = nil
    }

    @discardableResult func record(snapshot: TMobileGatewaySnapshot, at date: Date = Date(),
                                   location: TMobileCoverageLocationFix?) -> UUID? {
        guard var state = active else { return nil }
        let observation = TMobileCoverageObservation(date: date, snapshot: snapshot, location: location)
        guard observation.isValid, date >= state.session.startedAt,
              date >= (state.observations.last?.date ?? state.session.startedAt)
        else { fail(.invalidRecord); return nil }
        if let last = state.observations.last, last.date == date,
           last.snapshot == snapshot, last.location == location { return last.id }
        guard commit(.observation(observation), at: date, to: &state) else { return nil }
        active = state; publish(state); return observation.id
    }

    @discardableResult func recordSpeedTest(_ result: TMobileCoverageSpeedResult, for observationID: UUID) -> Bool {
        guard var state = active, result.isValid,
              let observation = state.observations.first(where: { $0.id == observationID })
        else { fail(.invalidRecord); return false }
        if observation.speedTest == result { return true }
        // Preserve an immutable result instead of silently overwriting it.
        guard observation.speedTest == nil else { fail(.invalidRecord); return false }
        guard commit(.speed(observationID: observationID, result: result), at: result.endedAt, to: &state) else { return false }
        active = state; publish(state); return true
    }

    /// Closing a gap repeats its reason/start time; its stable ID is retained.
    func addGap(reason: TMobileCoverageGapReason, from start: Date, to end: Date? = nil) {
        guard var state = active else { return }
        let existing = state.gaps.first { $0.reason == reason && $0.startedAt == start }
        let gap = TMobileCoverageGap(id: existing?.id ?? UUID(), startedAt: start, endedAt: end, reason: reason)
        guard gap.isValid, start >= state.session.startedAt else { fail(.invalidRecord); return }
        if existing == gap { return }
        guard commit(.gap(gap), at: end ?? start, to: &state) else { return }
        active = state; publish(state)
    }

    @discardableResult func noteTestedStop(location: TMobileCoverageLocationFix, at date: Date = Date()) -> Bool {
        guard var state = active else { return false }
        let stop = TMobileCoverageTestedStop(location: location, testedAt: date)
        guard stop.isValid, date >= state.session.startedAt else { fail(.invalidRecord); return false }
        guard commit(.testedStop(stop), at: date, to: &state) else { return false }
        active = state; testedStops.append(stop); publish(state); return true
    }

    func selectSession(_ id: UUID?) {
        guard let id else { selectedSessionID = nil; observations = []; gaps = []; return }
        do {
            let state: State
            if active?.session.id == id { state = active! } else { state = try loadSession(id) }
            selectedSessionID = id; observations = state.observations; gaps = state.gaps
            if !state.writable { warn(.corruptArchive) }
        } catch { fail(error) }
    }

    @discardableResult func correctLocation(observationID: UUID, coordinate: TMobileMapCoordinate,
                                           at date: Date = Date()) -> Bool {
        guard let id = selectedSessionID else { fail(.missingSession); return false }
        do {
            var state = active?.session.id == id ? active! : try loadSession(id)
            guard let observation = state.observations.first(where: { $0.id == observationID }),
                  observation.corrections.count < 10_000 else { throw ArchiveError.invalidRecord }
            let correction = TMobileCoverageLocationCorrection(coordinate: coordinate, correctedAt: date)
            guard correction.isValid, date >= observation.date else { throw ArchiveError.invalidRecord }
            guard commit(.correction(observationID: observationID, correction: correction), at: date, to: &state) else { return false }
            if currentSessionID == id { active = state }; publish(state); return true
        } catch { fail(error); return false }
    }

    @discardableResult func deleteSession(_ id: UUID) -> Bool {
        // Stop recording first so a late speed result cannot recreate a deleted session.
        guard currentSessionID != id else {
            errorMessage = "Stop recording before deleting this coverage session."; return false
        }
        do {
            let directory = sessionFolder(id)
            try requireDirectory(directory)
            try FileManager.default.removeItem(at: directory)
            sessions.removeAll { $0.id == id }
            loadTestedStops()
            if selectedSessionID == id {
                selectedSessionID = nil; observations = []; gaps = []
                if let next = sessions.first { selectSession(next.id) }
            }
            errorMessage = archiveWarning; return true
        } catch { fail(.persistence); return false }
    }

    /// Full local export contains original fixes and correction revisions.
    func exportSession(_ id: UUID) throws -> Data {
        let state = active?.session.id == id ? active! : try loadSession(id)
        guard state.writable else { throw ArchiveError.corruptArchive }
        struct Export: Codable {
            let schemaVersion: Int; let session: TMobileCoverageSession
            let observations: [TMobileCoverageObservation]; let gaps: [TMobileCoverageGap]
            let testedStops: [TMobileCoverageTestedStop]; let events: [TMobileCoverageJournalEvent]
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(Export(schemaVersion: 1, session: state.session,
                                         observations: state.observations, gaps: state.gaps,
                                         testedStops: state.testedStops, events: state.events))
    }

    /// Builds a bounded, resumable contract for a future connector. This method
    /// performs no network operation, tracks no credentials and enables no sync.
    func pendingSyncEnvelope(for id: UUID, afterSequence: UInt64 = 0, limit: Int = 100) throws -> TMobileCoverageSyncEnvelope {
        guard (1...500).contains(limit) else { throw ArchiveError.invalidRecord }
        let state = active?.session.id == id ? active! : try loadSession(id)
        guard state.writable else { throw ArchiveError.corruptArchive }
        let pending = state.events.filter { $0.sequence > afterSequence }
        let batch = Array(pending.prefix(limit))
        let identity = ([id.uuidString, String(afterSequence), String(limit)] + batch.map { $0.id.uuidString }).joined(separator: ":")
        let digest = SHA256.hash(data: Data(identity.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
        let indices = [8, 12, 16, 20]
        var uuidText = digest
        for index in indices.reversed() { uuidText.insert("-", at: uuidText.index(uuidText.startIndex, offsetBy: index)) }
        let batchID = UUID(uuidString: uuidText)!
        return .init(schemaVersion: 1, batchID: batchID, sessionID: id, events: batch,
                     hasMore: pending.count > batch.count, nextSequence: batch.last?.sequence, syncEnabled: false)
    }

    func dismissError() { errorMessage = archiveWarning }

    private func publish(_ state: State) {
        sessions.removeAll { $0.id == state.session.id }; sessions.append(state.session)
        sessions.sort { $0.startedAt > $1.startedAt }
        if selectedSessionID == state.session.id { observations = state.observations; gaps = state.gaps }
    }

    private func commit(_ payload: TMobileCoverageJournalEvent.Payload, at date: Date, to state: inout State) -> Bool {
        guard state.writable else { fail(.corruptArchive); return false }
        let event = TMobileCoverageJournalEvent(schemaVersion: 1, id: UUID(), sessionID: state.session.id,
                                                sequence: UInt64(state.events.count) + 1, createdAt: date, payload: payload)
        var candidate = state
        do {
            try apply(event, to: &candidate)
            let data = try JSONEncoder().encode(event)
            guard data.count <= TMobileCoverageSupport.maximumEventBytes else { throw ArchiveError.invalidRecord }
            try write(data, event: event)
            state = candidate; errorMessage = archiveWarning; return true
        } catch let error as ArchiveError { fail(error); return false }
        catch { fail(.persistence); return false }
    }

    private func apply(_ event: TMobileCoverageJournalEvent, to state: inout State) throws {
        guard event.schemaVersion == 1, event.sessionID == state.session.id,
              event.sequence == UInt64(state.events.count) + 1,
              TMobileCoverageSupport.validDate(event.createdAt),
              !state.events.contains(where: { $0.id == event.id }) else { throw ArchiveError.corruptArchive }
        switch event.payload {
        case let .session(session):
            guard state.events.isEmpty, session == state.session, session.isValid,
                  session.observationCount == 0, session.speedTestCount == 0, session.gapCount == 0,
                  session.endedAt == nil else { throw ArchiveError.corruptArchive }
        case let .observation(observation):
            guard state.session.endedAt == nil, observation.isValid, observation.corrections.isEmpty,
                  observation.speedTest == nil, observation.date >= state.session.startedAt,
                  observation.date >= (state.observations.last?.date ?? state.session.startedAt),
                  !state.observations.contains(where: { $0.id == observation.id }) else { throw ArchiveError.corruptArchive }
            state.observations.append(observation)
        case let .speed(id, result):
            guard state.session.endedAt == nil, result.isValid,
                  let index = state.observations.firstIndex(where: { $0.id == id }),
                  state.observations[index].speedTest == nil,
                  !state.observations.contains(where: { $0.speedTest?.id == result.id }) else { throw ArchiveError.corruptArchive }
            state.observations[index].speedTest = result
        case let .correction(id, correction):
            guard correction.isValid, let index = state.observations.firstIndex(where: { $0.id == id }),
                  correction.correctedAt >= (state.observations[index].corrections.last?.correctedAt ?? state.observations[index].date),
                  state.observations[index].corrections.count < 10_000,
                  !state.observations[index].corrections.contains(where: { $0.id == correction.id }) else { throw ArchiveError.corruptArchive }
            state.observations[index].corrections.append(correction)
        case let .gap(gap):
            guard state.session.endedAt == nil, gap.isValid, gap.startedAt >= state.session.startedAt else { throw ArchiveError.corruptArchive }
            if let index = state.gaps.firstIndex(where: { $0.id == gap.id }) {
                guard state.gaps[index].startedAt == gap.startedAt, state.gaps[index].reason == gap.reason,
                      state.gaps[index].endedAt == nil || state.gaps[index].endedAt == gap.endedAt else { throw ArchiveError.corruptArchive }
                state.gaps[index] = gap
            } else { state.gaps.append(gap) }
        case let .testedStop(stop):
            guard state.session.endedAt == nil, stop.isValid, stop.testedAt >= state.session.startedAt,
                  !state.testedStops.contains(where: { $0.id == stop.id }) else { throw ArchiveError.corruptArchive }
            state.testedStops.append(stop)
        case let .ended(date):
            guard state.session.endedAt == nil, TMobileCoverageSupport.validDate(date), date >= state.session.startedAt,
                  date >= (state.observations.last?.date ?? state.session.startedAt) else { throw ArchiveError.corruptArchive }
            state.session.endedAt = date
        }
        state.events.append(event); state.refreshCounts()
    }

    private func loadSummaries() {
        guard FileManager.default.fileExists(atPath: folder.path) else { return }
        do {
            try requireDirectory(folder)
            for url in try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) {
                guard !url.lastPathComponent.hasPrefix(".") else { continue }
                guard let id = UUID(uuidString: url.lastPathComponent) else { warn(.corruptArchive); continue }
                do {
                    let state = try loadSession(id); sessions.append(state.session); testedStops += state.testedStops
                    if !state.writable { warn(.corruptArchive) }
                } catch { warn(.corruptArchive) }
            }
            sessions.sort { $0.startedAt > $1.startedAt }
        } catch { warn(.corruptArchive) }
    }

    private func loadTestedStops() {
        testedStops = []
        for session in sessions {
            if let state = try? loadSession(session.id) { testedStops += state.testedStops }
        }
    }

    private func loadSession(_ id: UUID) throws -> State {
        let directory = sessionFolder(id); try requireDirectory(directory)
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { !$0.lastPathComponent.hasPrefix(".") }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        var state: State?
        for file in files {
            do {
                let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
                guard attributes[.type] as? FileAttributeType == .typeRegular,
                      let size = attributes[.size] as? NSNumber, size.intValue <= TMobileCoverageSupport.maximumEventBytes,
                      file.pathExtension == "json" else { throw ArchiveError.corruptArchive }
                let event = try JSONDecoder().decode(TMobileCoverageJournalEvent.self, from: Data(contentsOf: file))
                guard file.lastPathComponent == eventFilename(event), event.sessionID == id else { throw ArchiveError.corruptArchive }
                if state == nil {
                    guard case let .session(session) = event.payload else { throw ArchiveError.corruptArchive }
                    state = State(session: session)
                }
                try apply(event, to: &state!)
            } catch {
                guard state != nil else { throw ArchiveError.corruptArchive }
                state!.writable = false; break
            }
        }
        guard let state, !state.events.isEmpty else { throw ArchiveError.corruptArchive }
        return state
    }

    private func sessionFolder(_ id: UUID) -> URL { folder.appendingPathComponent(id.uuidString, isDirectory: true) }
    private func eventFilename(_ event: TMobileCoverageJournalEvent) -> String {
        String(format: "%020llu", event.sequence) + ".json"
    }
    private func requireDirectory(_ url: URL) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeDirectory else { throw ArchiveError.persistence }
    }
    private func prepareDirectory(_ url: URL) throws {
        if !FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        try requireDirectory(url)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }

    private func write(_ data: Data, event: TMobileCoverageJournalEvent) throws {
        try prepareDirectory(folder)
        let directory = sessionFolder(event.sessionID)
        if event.sequence == 1 { try prepareDirectory(directory) }
        else { try requireDirectory(directory) }
        let temporary = directory.appendingPathComponent(".event-\(UUID().uuidString).tmp")
        let destination = directory.appendingPathComponent(eventFilename(event))
        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw ArchiveError.persistence }
        var closed = false
        defer { if !closed { close(descriptor) }; unlink(temporary.path) }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw ArchiveError.persistence }
                offset += count
            }
        }
        guard fsync(descriptor) == 0 else { throw ArchiveError.persistence }
        guard close(descriptor) == 0 else { closed = true; throw ArchiveError.persistence }; closed = true
        // link creates a new destination atomically and cannot overwrite one.
        guard link(temporary.path, destination.path) == 0 else { throw ArchiveError.persistence }
        let directoryDescriptor = open(directory.path, O_RDONLY | O_NOFOLLOW)
        if directoryDescriptor >= 0 { _ = fsync(directoryDescriptor); close(directoryDescriptor) }
    }

    private func warn(_ error: ArchiveError) { archiveWarning = error.localizedDescription; errorMessage = archiveWarning }
    private func fail(_ error: ArchiveError) { errorMessage = error.localizedDescription }
    private func fail(_ error: Error) { errorMessage = (error as? ArchiveError)?.localizedDescription ?? ArchiveError.persistence.localizedDescription }
}
