// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

@main struct TMobileCoverageStoreHarness {
    @MainActor static func main() throws {
        var checks = 0; var failures: [String] = []
        func expect(_ condition: Bool, _ message: String) {
            checks += 1; if !condition { failures.append(message) }
        }
        TMobileCoverageRecordingStartupTests.run(expect)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("coverage-fixture-\(UUID())")
        defer { try? FileManager.default.removeItem(at: folder) }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let coordinate = TMobileMapCoordinate(latitude: 40, longitude: -100)
        let fix = TMobileCoverageLocationFix(coordinate: coordinate, timestamp: now, horizontalAccuracy: 12, source: .mac)
        let snapshot = try TMobileGatewaySupport.parse(Data(#"{"signal":{"generic":{"registration":"registered"},"5g":{"bands":["n41"],"rsrp":-100,"sinr":10}}}"#.utf8))
        let store = TMobileCoverageStore(folder: folder)
        expect(store.sessions.isEmpty && store.currentSessionID == nil, "new archive defaults to no recording")
        expect(!FileManager.default.fileExists(atPath: folder.path), "constructing archive creates no files")
        expect(store.record(snapshot: snapshot, at: now, location: fix) == nil, "record requires explicit session")
        let session = store.beginSession(name: "Synthetic session", at: now)!
        expect(store.beginSession(name: "Different session", at: now) == nil && store.currentSessionID == session,
               "starting an existing active archive never silently reuses its identity")
        let id = store.record(snapshot: snapshot, at: now, location: fix)!
        expect(store.record(snapshot: snapshot, at: now, location: fix) == id && store.observations.count == 1, "duplicate timestamp/snapshot/fix is idempotent")
        expect(store.observations[0].connectionScore == nil && store.observations[0].downloadMbps == nil, "untested sample has neither speed nor complete score")
        let test = TMobileCoverageSpeedResult(startedAt: now, endedAt: now.addingTimeInterval(10), startLocation: fix,
                                              endLocation: .init(coordinate: coordinate, timestamp: now.addingTimeInterval(10), horizontalAccuracy: 12, source: .mac),
                                              downloadMbps: 75, uploadMbps: 15, latencyMilliseconds: 20)
        expect(store.recordSpeedTest(test, for: id), "paired timed speed result saves")
        expect(abs((store.observations[0].connectionScore ?? -1) - 50) < 0.0001, "equal normalized components produce custom score 50")
        expect(store.recordSpeedTest(test, for: id), "identical speed retry is idempotent")
        let different = TMobileCoverageSpeedResult(startedAt: now, endedAt: now, startLocation: fix, endLocation: fix, downloadMbps: 10)
        expect(!store.recordSpeedTest(different, for: id), "existing speed measurement cannot silently be replaced")
        store.addGap(reason: .sleep, from: now.addingTimeInterval(20))
        let gapID = store.gaps[0].id
        store.addGap(reason: .sleep, from: now.addingTimeInterval(20), to: now.addingTimeInterval(80))
        expect(store.gaps.count == 1 && store.gaps[0].id == gapID && store.gaps[0].endedAt != nil, "closing gap preserves stable identity")
        expect(store.noteTestedStop(location: fix, at: now), "automatic attempt can persist before network starts")
        let corrected = TMobileMapCoordinate(latitude: 40.0001, longitude: -100)
        expect(store.correctLocation(observationID: id, coordinate: corrected, at: now.addingTimeInterval(30)), "manual correction saves")
        expect(store.observations[0].location == fix && store.observations[0].effectiveCoordinate == corrected,
               "manual correction preserves raw fix and changes effective coordinate")
        expect(store.observations[0].corrections.count == 1 && store.observations[0].effectiveLocation?.source == .manual,
               "correction revision records manual provenance")
        expect(!store.deleteSession(session), "active session must stop before explicit deletion")
        let selectedFolder = folder.appendingPathComponent(session.uuidString)
        let events = try FileManager.default.contentsOfDirectory(at: selectedFolder, includingPropertiesForKeys: nil)
        expect(events.count == 7, "one bounded event per successful mutation without rewrite")
        expect(events.allSatisfy { ((try? FileManager.default.attributesOfItem(atPath: $0.path)[.posixPermissions]) as? NSNumber)?.intValue == 0o600 },
               "event files are owner only")
        expect(((try FileManager.default.attributesOfItem(atPath: selectedFolder.path)[.posixPermissions]) as? NSNumber)?.intValue == 0o700,
               "session directories are owner only")
        let bytesBefore = try events.map { try Data(contentsOf: $0) }
        store.endSession(at: now.addingTimeInterval(100))
        expect(store.currentSessionID == nil && store.sessions[0].endedAt != nil, "ending session is durable and stops recording")
        expect(try events.enumerated().allSatisfy { try Data(contentsOf: $0.element) == bytesBefore[$0.offset] }, "ending does not rewrite existing event files")
        let restored = TMobileCoverageStore(folder: folder)
        expect(restored.currentSessionID == nil && restored.sessions.count == 1, "app relaunch never resumes recording implicitly")
        expect(restored.observations == store.observations && restored.gaps == store.gaps, "raw fixes corrections and gaps round-trip")
        expect(restored.testedStops.count == 1 && restored.testedStops[0].testedAt == now, "attempted stops survive app relaunch")
        expect(restored.sessions[0].observationCount == 1 && restored.sessions[0].speedTestCount == 1 && restored.sessions[0].gapCount == 1,
               "session summaries reflect replayed records")
        let first = try restored.pendingSyncEnvelope(for: session, limit: 3)
        let repeated = try restored.pendingSyncEnvelope(for: session, limit: 3)
        let second = try restored.pendingSyncEnvelope(for: session, afterSequence: first.nextSequence!, limit: 3)
        expect(first == repeated, "same immutable sync window has stable batch identity")
        expect(!first.syncEnabled && !restored.syncEnabled && first.hasMore, "future sync envelope stays disabled")
        expect(first.events.count == 3 && first.events.last!.sequence < second.events.first!.sequence,
               "bounded sync export resumes after durable event sequence")
        expect(Set(first.events.map(\.id)).isDisjoint(with: Set(second.events.map(\.id))), "resumed batches do not repeat event IDs")
        let export = try restored.exportSession(session)
        expect(String(data: export, encoding: .utf8)?.contains("balanced-v1") == true, "export contains formula version and event lineage")
        expect(!String(data: export, encoding: .utf8)!.contains("password") && !String(data: export, encoding: .utf8)!.contains("token"),
               "export contract has no credential fields")
        let oldSession = restored.beginSession(name: "No automatic retention", at: now.addingTimeInterval(-86400 * 365))!
        expect(restored.record(snapshot: snapshot, at: now.addingTimeInterval(-86400 * 365), location: nil) != nil,
               "old but valid measurements are retained without rolling expiry")
        restored.endSession(at: now.addingTimeInterval(-86400 * 365 + 1))
        let again = TMobileCoverageStore(folder: folder)
        expect(again.sessions.count == 2 && again.sessions.contains(where: { $0.id == oldSession }), "year-old sessions survive reload until explicit deletion")
        expect(again.deleteSession(oldSession) && again.sessions.count == 1, "explicit deletion removes only selected session")
        expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent(oldSession.uuidString).path), "deleted session files removed")
        let raw = TMobileCoverageObservation(date: now, snapshot: snapshot, location: fix)
        var invalid = raw
        invalid.speedTest = TMobileCoverageSpeedResult(startedAt: now, endedAt: now, startLocation: fix, endLocation: fix,
                                                      downloadMbps: 100, scoreEligible: false, invalidationReason: "Band changed")
        expect(invalid.downloadMbps == 100 && invalid.connectionScore == nil, "ineligible speed remains visible without complete score")
        invalid.speedTest = TMobileCoverageSpeedResult(startedAt: now.addingTimeInterval(1000), endedAt: now.addingTimeInterval(1000),
                                                      startLocation: fix, endLocation: fix, downloadMbps: 100)
        expect(invalid.connectionScore == nil, "stale speed cannot complete score")
        invalid.speedTest = .init(startedAt: now, endedAt: now, startLocation: fix,
                                  endLocation: .init(coordinate: .init(latitude: 41, longitude: -100), timestamp: now, horizontalAccuracy: 12, source: .mac), downloadMbps: 100)
        expect(invalid.connectionScore == nil, "moving speed test cannot complete stationary score")
        expect(!TMobileCoverageLocationFix(coordinate: coordinate, timestamp: now, horizontalAccuracy: -1, source: .mac).isValid,
               "invalid accuracy is never treated as a good fix")
        expect(!fix.isUsable(at: now.addingTimeInterval(61)), "old fix remains archived but is not usable")
        invalid = raw
        invalid.speedTest = test
        invalid.corrections = [.init(coordinate: .init(latitude: 40.00135, longitude: -100), correctedAt: now)]
        let shiftedEnd = TMobileCoverageLocationFix(coordinate: .init(latitude: 39.9995, longitude: -100),
                                                    timestamp: now, horizontalAccuracy: 12, source: .mac)
        invalid.speedTest = .init(startedAt: now, endedAt: now, startLocation: fix, endLocation: shiftedEnd, downloadMbps: 75)
        expect(invalid.connectionScore == nil, "manual correction must be near both test endpoints")
        let broadFix = TMobileCoverageLocationFix(coordinate: coordinate, timestamp: now, horizontalAccuracy: 101, source: .mac)
        var broadObservation = TMobileCoverageObservation(date: now, snapshot: snapshot, location: broadFix)
        broadObservation.speedTest = test
        expect(broadFix.isUsable(at: now) && broadObservation.connectionScore == nil,
               "complete score applies stricter precision than archival route helper")
        expect(!TMobileCoverageSpeedResult(startedAt: now, endedAt: now, startLocation: fix, endLocation: fix, downloadMbps: .nan).isValid,
               "nonfinite test result rejects")
        let corruptFile = selectedFolder.appendingPathComponent("99999999999999999999-bad.json")
        try Data("corrupt-fixture".utf8).write(to: corruptFile)
        let corrupt = TMobileCoverageStore(folder: folder)
        expect(corrupt.errorMessage != nil && corrupt.observations.count == 1, "corrupt trailing event surfaces error and preserves valid prefix")
        expect((try? corrupt.exportSession(session)) == nil, "partial archive cannot be exported as complete")
        expect(!corrupt.correctLocation(observationID: id, coordinate: coordinate, at: now.addingTimeInterval(200)),
               "corrupt session is protected from appended mutations")
        expect(FileManager.default.fileExists(atPath: corruptFile.path), "corruption is preserved for recovery")
        let blocked = folder.appendingPathComponent("blocked")
        try Data("not-a-directory".utf8).write(to: blocked)
        let failing = TMobileCoverageStore(folder: blocked)
        expect(failing.beginSession(at: now) == nil && failing.errorMessage != nil && failing.sessions.isEmpty,
               "persist failure surfaces without publishing unsaved session")
        expect(try Data(contentsOf: blocked) == Data("not-a-directory".utf8), "persist failure does not overwrite unrelated file")
        let concurrentFolder = folder.appendingPathComponent(".concurrent")
        let writerA = TMobileCoverageStore(folder: concurrentFolder)
        let concurrentID = writerA.beginSession(at: now)!
        let concurrentObservationID = writerA.record(snapshot: snapshot, at: now, location: fix)!
        let writerB = TMobileCoverageStore(folder: concurrentFolder)
        expect(writerB.correctLocation(observationID: concurrentObservationID, coordinate: corrected, at: now.addingTimeInterval(1)),
               "second writer can append a legitimate archived correction")
        expect(writerA.record(snapshot: snapshot, at: now.addingTimeInterval(2), location: fix) == nil && writerA.errorMessage != nil,
               "stale writer cannot overwrite or duplicate a committed sequence")
        writerA.endSession(at: now.addingTimeInterval(2))
        expect(writerA.currentSessionID == concurrentID && writerA.errorMessage != nil, "failed durable end remains an unfinished session")
        expect(writerA.beginSession(name: "Must be a new session", at: now.addingTimeInterval(3)) == nil
               && writerA.currentSessionID == concurrentID && writerA.sessions.count == 1
               && writerA.errorMessage?.contains("still open") == true,
               "starting after failed close is rejected explicitly rather than resuming prior archive")
        let concurrentReplay = TMobileCoverageStore(folder: concurrentFolder)
        expect(concurrentReplay.errorMessage == nil && concurrentReplay.observations.count == 1 && concurrentReplay.observations[0].corrections.count == 1,
               "concurrent sequence collision leaves a valid complete archive")
        expect(writerB.deleteSession(concurrentID), "external stopped archive instance can explicitly delete session")
        expect(writerA.record(snapshot: snapshot, at: now.addingTimeInterval(3), location: fix) == nil
               && !FileManager.default.fileExists(atPath: concurrentFolder.appendingPathComponent(concurrentID.uuidString).path),
               "late stale write never recreates a deleted session")
        if failures.isEmpty { print("PASS: \(checks) local coverage archive checks; synthetic data, no live location/router/network access") }
        else { failures.forEach { print("FAIL: \($0)") }; exit(1) }
    }
}
