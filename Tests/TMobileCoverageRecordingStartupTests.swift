// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

enum TMobileCoverageRecordingStartupTests {
    @MainActor static func run(_ expect: (Bool, String) -> Void) {
        var optedOut = TMobileCoverageRecordingStartup()
        expect(!optedOut.shouldStartAfterAppLaunch(enabled: false, networkAvailable: true),
               "launch without an opt-in does not start coverage recording")
        expect(!optedOut.shouldStartAfterAppLaunch(enabled: true, networkAvailable: true),
               "enabling automatic recording after launch waits for the next launch")

        var unavailable = TMobileCoverageRecordingStartup()
        expect(!unavailable.shouldStartAfterAppLaunch(enabled: true, networkAvailable: false),
               "a disabled Network feature prevents automatic recording at launch")
        expect(!unavailable.shouldStartAfterAppLaunch(enabled: true, networkAvailable: true),
               "enabling Network later cannot introduce a delayed automatic start")

        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("coverage-startup-fixture-\(UUID())")
        defer { try? FileManager.default.removeItem(at: folder) }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let firstRun = TMobileCoverageStore(folder: folder)
        expect(firstRun.currentSessionID == nil && !FileManager.default.fileExists(atPath: folder.path),
               "the startup archive has no active session or files until a start is requested")
        guard let previousID = firstRun.beginSession(name: "Previous fixture session", at: now) else {
            expect(false, "the previous synthetic session can be created"); return
        }
        firstRun.endSession(at: now.addingTimeInterval(1))
        let previousFolder = folder.appendingPathComponent(previousID.uuidString)
        let previousFiles = (try? FileManager.default.contentsOfDirectory(at: previousFolder, includingPropertiesForKeys: nil)) ?? []
        let previousBytes = previousFiles.compactMap { try? Data(contentsOf: $0) }

        let relaunched = TMobileCoverageStore(folder: folder)
        expect(relaunched.currentSessionID == nil && relaunched.sessions.count == 1,
               "replaying saved coverage history alone does not restart recording")
        var launch = TMobileCoverageRecordingStartup()
        let shouldStart = launch.shouldStartAfterAppLaunch(enabled: true, networkAvailable: true)
        expect(shouldStart, "a saved opt-in permits one start at actual app launch without a window")
        let newID = shouldStart ? relaunched.beginSession(name: "Automatic fixture session", at: now.addingTimeInterval(2)) : nil
        expect(newID != nil && newID != previousID && relaunched.currentSessionID == newID,
               "automatic launch recording starts a new archive session instead of resuming the old one")
        expect(previousBytes.count == previousFiles.count && previousFiles.enumerated().allSatisfy {
            (try? Data(contentsOf: $0.element)) == previousBytes[$0.offset]
        }, "automatic startup preserves all previous immutable archive events")

        relaunched.endSession(at: now.addingTimeInterval(3))
        expect(relaunched.currentSessionID == nil,
               "stopping an automatic session ends recording durably")
        expect(!launch.shouldStartAfterAppLaunch(enabled: true, networkAvailable: true)
               && relaunched.currentSessionID == nil && relaunched.sessions.count == 2,
               "repeated launch delivery or reopening Coverage cannot restart a stopped session")
        expect(!launch.shouldStartAfterAppLaunch(enabled: false, networkAvailable: true)
               && !launch.shouldStartAfterAppLaunch(enabled: true, networkAvailable: true),
               "changing automatic-start preferences after Stop never restarts the current run")

        var nextLaunch = TMobileCoverageRecordingStartup()
        let startsNextTime = nextLaunch.shouldStartAfterAppLaunch(enabled: true, networkAvailable: true)
        let nextStore = TMobileCoverageStore(folder: folder)
        let nextID = startsNextTime ? nextStore.beginSession(name: "Next launch fixture", at: now.addingTimeInterval(4)) : nil
        expect(nextID != nil && nextID != newID && nextStore.sessions.count == 3,
               "the retained opt-in starts another fresh session at the next app launch")
        nextStore.endSession(at: now.addingTimeInterval(5))
    }
}
