// SPDX-License-Identifier: GPL-3.0-or-later
import Darwin
import Foundation
import Security

/// Narrow coordinate fixture matching the Codable shape and finite WGS84 bounds
/// of TMobileMapCoordinate in TMobileGatewayHistorySupport.swift. Compiling that
/// file would pull in unrelated gateway snapshots and tower-reference parsing.
/// This harness verifies FCC workflows, not the production coordinate type.
struct TMobileMapCoordinate: Codable, Equatable {
    let latitude: Double
    let longitude: Double
    var isValid: Bool {
        latitude.isFinite && longitude.isFinite && (-90...90).contains(latitude) && (-180...180).contains(longitude)
    }
}

/// Synthetic credentials only. All credential operations use mocks. All disk
/// files are under one fresh temporary folder; the only device inspected is
/// /dev/null, which the production reader must reject before reading any bytes.
@main enum TMobileFCCWorkflowHarness {
    private static let service = "io.github.joaovorocha.shadowutils.credentials.fcc-public-api.v1"
    private static let scope = ScopedCredentialScope(service: service, account: "https://broadbandmap.fcc.gov")
    private static let email = "fcc-workflow@example.invalid"
    private static let token = "synthetic-fcc-workflow-token"
    private static let date = "2025-12-31"
    private static let geo = Data(#"{"type":"FeatureCollection","properties":{"private":"excluded-fixture-marker"},"features":[{"type":"Feature","properties":{"private":"excluded-fixture-marker","token":"excluded-fixture-marker"},"geometry":{"type":"Polygon","coordinates":[[[-100,40],[-99,40],[-99,41],[-100,40]]]}}]}"#.utf8)

    @MainActor static func main() {
        if CommandLine.arguments.count == 4, CommandLine.arguments[1] == "--reader-reject",
           let limit = Int(CommandLine.arguments[3]) {
            do {
                _ = try TMobileCoverageReferenceSupport.readLocalFile(at: URL(fileURLWithPath: CommandLine.arguments[2]), maximumBytes: limit)
                exit(2)
            } catch { exit(0) }
        }
        guard CommandLine.arguments.count == 1 else { exit(3) }
        let suite = FCCWorkflowSuite()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("fcc-workflow-fixtures-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            defer { try? FileManager.default.removeItem(at: folder) }
            credentialLifecycle(suite)
            keychainBoundary(suite)
            quietSavedAccess(suite)
            try references(suite, folder: folder)
            try modeledSignals(suite, folder: folder)
            try boundedReader(suite, folder: folder)
        } catch { suite.check(false, "temporary fixture setup and cleanup complete") }
        print("FCC workflow fixtures: \(suite.checks) checks, \(suite.failures) failures; no live Keychain, account, API or coverage archive")
        exit(suite.failures == 0 ? 0 : 1)
    }

    @MainActor private static func credentialLifecycle(_ suite: FCCWorkflowSuite) {
        let store = FCCWorkflowCredentialStore()
        let form = TMobileFCCCredentialForm(store: store)
        suite.check(AppCredentialServices.service("fcc-public-api.v1") == service,
                    "Shadow credential namespace matches the owner-run helper")
        suite.check(store.calls == 0 && form.username.isEmpty && form.token.isEmpty && form.message == nil,
                    "constructing the FCC form performs zero credential operations")
        form.username = email; form.token = token
        suite.check(form.isValid && store.calls == 0, "typing and validation never access stored credentials")
        form.save()
        let saved = store.values[scope]
        let json = saved.flatMap { $0.data(using: .utf8) }.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: String] }
        suite.check(store.writes == [scope] && store.reads.isEmpty && store.deletes.isEmpty,
                    "explicit save targets exactly one FCC service and canonical account without reading")
        suite.check(json?["username"] == email && json?["token"] == token && Set(json?.keys.map { $0 } ?? []) == ["username", "token"],
                    "saved JSON has exactly the two credential fields consumed by the app and helper")
        suite.check(form.message?.contains("saved in Keychain") == true && safe(form.message),
                    "saving reports local persistence without claiming that FCC validated the token")
        let beforeClear = store.calls
        form.clear()
        suite.check(form.username.isEmpty && form.token.isEmpty && form.message == nil && store.calls == beforeClear && store.values[scope] == saved,
                    "clear removes volatile input only and retains the saved record")
        form.useSaved()
        suite.check(store.reads == [scope] && form.username == email && form.token == token && safe(form.message),
                    "explicit Use saved access loads only the scoped JSON and does not connect")
        let second = TMobileFCCCredentialForm(store: store)
        suite.check(second.username.isEmpty && second.token.isEmpty && store.reads.count == 1,
                    "opening another FCC form does not load the saved token")

        for pair in [("", token), ("missing-at", token), ("bad\n@example.invalid", token),
                     (String(repeating: "a", count: 255) + "@", token), (email, ""), (email, "contains space"),
                     (email, "line\nbreak"), (email, "nonascii-é"), (email, String(repeating: "a", count: 4_097))] {
            let calls = store.calls
            form.username = pair.0; form.token = pair.1; form.save()
            suite.check(!form.isValid && store.calls == calls && safe(form.message), "invalid credential input never reaches the scoped store")
        }
        form.username = email; form.token = String(repeating: "a", count: 4_096)
        suite.check(form.isValid, "documented maximum token length is accepted locally")
        store.values[scope] = nil
        form.username = email; form.token = token; form.useSaved()
        suite.check(form.username.isEmpty && form.token.isEmpty && form.message?.contains("No FCC access") == true,
                    "a missing saved item clears previous input")
        let invalidValues = ["", "not-json", #"{"username":"fcc-workflow@example.invalid"}"#,
                             #"{"username":"fcc-workflow@example.invalid","token":"contains space"}"#,
                             #"{"username":"missing-at","token":"synthetic"}"#,
                             #"{"username":"fcc-workflow@example.invalid","token":23}"#]
        for value in invalidValues {
            store.values[scope] = value
            let reads = store.reads.count
            form.username = email; form.token = token; form.useSaved()
            suite.check(store.reads.count == reads + 1 && form.username.isEmpty && form.token.isEmpty
                        && form.message?.contains("unavailable") == true && safe(form.message),
                        "invalid saved values clear both fields and report a safe recovery message")
        }
        store.values[scope] = saved; store.readError = ScopedCredentialStoreError.unavailable
        form.username = email; form.token = token; form.useSaved()
        suite.check(form.username.isEmpty && form.token.isEmpty && form.message?.contains("Unable to read") == true && safe(form.message),
                    "read failure cannot leave prior credential input behind")
        store.readError = nil; store.saveError = ScopedCredentialStoreError.unavailable
        form.username = email; form.token = token; form.save()
        suite.check(form.username == email && form.token == token && form.message?.contains("Unable to save") == true && safe(form.message),
                    "save failure preserves typed input and exposes no credential value")
        store.saveError = nil
        let unrelated = ScopedCredentialScope(service: "fixture.unrelated.credentials", account: "fixture-unrelated")
        store.values[unrelated] = "synthetic-unrelated-value"
        form.forget()
        suite.check(store.deletes.last == scope && store.values[scope] == nil && store.values[unrelated] != nil
                    && form.username.isEmpty && form.token.isEmpty && form.message?.contains("forgotten") == true,
                    "Forget clears memory and removes only the exact FCC record")
        store.values[scope] = saved; store.deleteError = ScopedCredentialStoreError.unavailable
        form.username = email; form.token = token; form.forget()
        suite.check(form.username.isEmpty && form.token.isEmpty && store.values[scope] == saved
                    && form.message?.contains("Unable to forget") == true && safe(form.message),
                    "failed Forget clears input without claiming successful deletion")
    }

    @MainActor private static func quietSavedAccess(_ suite: FCCWorkflowSuite) {
        let access = FCCWorkflowKeychainAccess()
        let store = KeychainScopedCredentialStore(access: access)
        let form = TMobileFCCCredentialForm(store: store)
        access.readData = Data(#"{"username":"fcc-workflow@example.invalid","token":"synthetic-fcc-workflow-token"}"#.utf8)
        form.prepareSavedAccess()
        suite.check(access.reads.count == 1 && form.isValid && !form.needsSave, "FCC opening quietly checks saved access before asking for a token")
        suite.check(exact(access.reads[0]) && access.reads[0][kSecUseAuthenticationUI as String] as? String == kSecUseAuthenticationUIFail as String,
                    "quiet probe uses only exact scope and disallows Keychain UI")
        form.prepareSavedAccess()
        suite.check(access.reads.count == 1, "reappearing in one workspace does not repeat quiet probes")
        form.token = "synthetic-replacement"
        suite.check(form.needsSave, "changing saved access requires saving the new input")
        let typed = TMobileFCCCredentialForm(store: store)
        typed.username = email; typed.token = token; typed.prepareSavedAccess()
        suite.check(access.reads.count == 1 && typed.token == token, "preflight never overwrites input already being entered")
        access.status = errSecInteractionNotAllowed
        let locked = TMobileFCCCredentialForm(store: store)
        locked.prepareSavedAccess()
        suite.check(locked.savedAccessState == .locked && locked.token.isEmpty && access.reads.count == 2,
                    "locked Keychain is distinct from missing token and does not expose access")
        access.status = errSecSuccess
        locked.useSaved()
        suite.check(locked.isValid && access.reads.last?[kSecUseAuthenticationUI as String] == nil,
                    "explicit unlock can use normal Keychain approval")
        access.status = errSecItemNotFound
        let missing = TMobileFCCCredentialForm(store: store)
        missing.prepareSavedAccess()
        suite.check(missing.savedAccessState == .missing && !missing.isValid, "missing item asks for access only after exact probe")
        form.rejectAccess()
        suite.check(form.token.isEmpty && form.username == email && form.savedAccessState == .invalid,
                    "rejected token clears volatile secret and retains email for renewal")
    }

    private static func keychainBoundary(_ suite: FCCWorkflowSuite) {
        let access = FCCWorkflowKeychainAccess()
        let store = KeychainScopedCredentialStore(access: access)
        suite.check(access.calls == 0, "constructing the actual scoped store does not call Security")
        access.readData = Data(#"{"username":"fcc-workflow@example.invalid","token":"synthetic-fcc-workflow-token"}"#.utf8)
        suite.check((try? store.read(scope: scope)) != nil && access.reads.count == 1 && exact(access.reads[0]),
                    "actual read query uses only the exact nonsynchronizing generic-password scope")
        suite.check(access.reads[0][kSecReturnData as String] as? Bool == true
                    && access.reads[0][kSecMatchLimit as String] as? String == kSecMatchLimitOne as String,
                    "actual read requests one credential value without enumeration")
        do { try store.save("synthetic-encoded-credential", scope: scope) }
        catch { suite.check(false, "mocked exact scoped save succeeds") }
        suite.check(access.updates.count == 1 && exact(access.updates[0].0)
                    && Set(access.updates[0].1.keys) == [kSecValueData as String]
                    && access.adds.count == 1 && exact(access.adds[0]),
                    "actual save updates or adds only the selected item with no broader attributes")
        suite.check(access.adds[0][kSecAttrAccess as String] == nil && access.adds[0][kSecAttrAccessGroup as String] == nil,
                    "saving does not grant broad ACL access or a shared access group")
        do { try store.delete(scope: scope) }
        catch { suite.check(false, "mocked exact scoped deletion succeeds") }
        suite.check(access.deletes.count == 1 && exact(access.deletes[0]), "actual Forget query is exact and nonsynchronizing")
    }

    @MainActor private static func references(_ suite: FCCWorkflowSuite, folder: URL) throws {
        let legacyFolder = folder.appendingPathComponent("beta9", isDirectory: true)
        try FileManager.default.createDirectory(at: legacyFolder, withIntermediateDirectories: false)
        let legacy: [String: Any] = ["id": "5A8BC85D-C26A-405B-82F0-A3B257A6CB2B", "publishedDate": date, "importedAt": 0,
                                     "polygons": [[[["latitude": 40, "longitude": -100], ["latitude": 40, "longitude": -99],
                                                     ["latitude": 41, "longitude": -99], ["latitude": 40, "longitude": -100]]]]]
        let legacyData = try JSONSerialization.data(withJSONObject: legacy)
        let direct = try JSONDecoder().decode(TMobileCoverageFCCLayer.self, from: legacyData)
        suite.check(direct.source == nil && direct.modeledSignalDBm == nil && direct.polygons.count == 1,
                    "beta.9 archive without source or modeled signal decodes with unknown values")
        try legacyData.write(to: legacyFolder.appendingPathComponent("fcc-reference.json"))
        let legacyStore = TMobileCoverageReferenceStore(folder: legacyFolder)
        suite.check(legacyStore.layer == direct && legacyStore.errorMessage == nil,
                    "beta.9 saved geometry loads through current bounds validation")
        suite.check((try Data(contentsOf: legacyFolder.appendingPathComponent("fcc-reference.json"))) == legacyData,
                    "loading an older archive does not silently rewrite it")

        let currentFolder = folder.appendingPathComponent("current", isDirectory: true)
        let store = TMobileCoverageReferenceStore(folder: currentFolder)
        suite.check(store.layer == nil && store.errorMessage == nil && !FileManager.default.fileExists(atPath: currentFolder.path),
                    "empty reference-store construction does not create or import data")
        let source = provenance()
        suite.check(source.isValid && source.origin == .officialAPI && source.title.contains(date),
                    "official source has a valid availability date and clear label")
        suite.check(store.importLayer(data: geo, publishedDate: date, source: source), "valid explicit FCC import succeeds")
        let original = store.layer
        let archive = currentFolder.appendingPathComponent("fcc-reference.json")
        let originalData = try Data(contentsOf: archive)
        let loaded = TMobileCoverageReferenceStore(folder: currentFolder)
        suite.check(loaded.layer == original && loaded.layer?.source == source && loaded.errorMessage == nil,
                    "official provenance and geometry survive persistence and reopening")
        let encoded = String(data: originalData, encoding: .utf8) ?? ""
        suite.check(!encoded.contains("excluded-fixture-marker") && !encoded.contains("properties") && !encoded.contains("\"token\""),
                    "arbitrary GeoJSON root and feature properties never enter the archive")
        let persisted = try JSONSerialization.jsonObject(with: originalData) as! [String: Any]
        let sourceObject = persisted["source"] as? [String: Any] ?? [:]
        suite.check(Set(sourceObject.keys) == ["origin", "availabilityAsOf", "stateFIPS", "technology", "minimumDownloadMbps", "minimumUploadMbps", "environment", "fileID"],
                    "persisted provenance contains only the explicit allowlisted fields")
        let permissions = try FileManager.default.attributesOfItem(atPath: archive.path)
        let directoryPermissions = try FileManager.default.attributesOfItem(atPath: currentFolder.path)
        suite.check((permissions[.posixPermissions] as? NSNumber)?.intValue == 0o600
                    && (directoryPermissions[.posixPermissions] as? NSNumber)?.intValue == 0o700,
                    "reference archive and parent folder use owner-only permissions")
        let rejectedMismatch = !store.importLayer(data: geo, publishedDate: date, source: provenance(date: "2025-06-30"))
        let afterMismatch = try Data(contentsOf: archive)
        suite.check(rejectedMismatch && store.layer == original && afterMismatch == originalData,
                    "mismatched availability date rejects import and retains the old reference on disk and in memory")
        let rejectedGeometry = !store.importLayer(data: Data("invalid-fixture".utf8), publishedDate: date, source: source)
        let afterGeometry = try Data(contentsOf: archive)
        suite.check(rejectedGeometry && store.layer == original && afterGeometry == originalData,
                    "malformed replacement geometry cannot erase the old reference")
        for invalid in [provenance(state: "99"), provenance(technology: 300), provenance(down: .nan), provenance(up: .infinity),
                        provenance(down: 0), provenance(up: 1_001), provenance(environment: 3), provenance(fileID: "../invalid"),
                        provenance(date: "2025-02-29"), provenance(state: nil), provenance(fileID: nil)] {
            suite.check(!invalid.isValid && !store.importLayer(data: geo, publishedDate: date, source: invalid)
                        && store.layer == original, "invalid provenance cannot replace the current reference")
        }
        let local = provenance(origin: .localFile, state: nil, fileID: nil)
        let localDecoded = try JSONDecoder().decode(TMobileFCCReferenceSource.self, from: JSONEncoder().encode(local))
        suite.check(local.isValid && local.provenance.contains("origin declared by you")
                    && localDecoded == local,
                    "local-file provenance roundtrips without claiming authenticated official origin")
        var mismatch = persisted
        var wrongSource = sourceObject; wrongSource["availabilityAsOf"] = "2025-06-30"; mismatch["source"] = wrongSource
        try JSONSerialization.data(withJSONObject: mismatch).write(to: archive)
        let badSaved = TMobileCoverageReferenceStore(folder: currentFolder)
        suite.check(badSaved.layer == nil && badSaved.errorMessage != nil,
                    "persisted source/date mismatch cannot become a displayed reference")
        try originalData.write(to: archive)
        let unrelated = currentFolder.appendingPathComponent("unrelated-fixture")
        try Data("fixture".utf8).write(to: unrelated)
        loaded.removeLayer()
        suite.check(loaded.layer == nil && loaded.errorMessage == nil && !FileManager.default.fileExists(atPath: archive.path)
                    && FileManager.default.fileExists(atPath: unrelated.path), "explicit removal deletes only the reference archive")
    }

    @MainActor private static func modeledSignals(_ suite: FCCWorkflowSuite, folder: URL) throws {
        let destination = folder.appendingPathComponent("modeled-signal", isDirectory: true)
        let store = TMobileCoverageReferenceStore(folder: destination)
        let outer = [[-100.0, 40.0], [-99, 40], [-99, 41], [-100, 41], [-100, 40]]
        let hole = [[-99.8, 40.2], [-99.8, 40.4], [-99.6, 40.4], [-99.6, 40.2], [-99.8, 40.2]]
        let polygon = [outer, hole]
        func feature(_ signal: Any?, multi: Bool = false) -> [String: Any] {
            var properties: [String: Any] = ["private": "excluded-fixture-marker", "minsignal": -1]
            if let signal { properties["fccMinimumSignalDBm"] = signal }
            return ["type": "Feature", "properties": properties,
                    "geometry": ["type": multi ? "MultiPolygon" : "Polygon",
                                 "coordinates": multi ? [polygon, polygon] as Any : polygon as Any]]
        }
        func data(_ features: [[String: Any]]) throws -> Data {
            try JSONSerialization.data(withJSONObject: ["type": "FeatureCollection", "features": features])
        }
        let fixture = try data([feature(-90, multi: true), feature(NSNull()), feature(nil)])
        let expected: [Double?] = [-90, -90, nil, nil]
        suite.check(store.importLayer(data: fixture, publishedDate: date, source: provenance()),
                    "explicit modeled signal import succeeds with provenance")
        let original = store.layer
        suite.check(original?.modeledSignalDBm == expected && original?.polygons.count == expected.count,
                    "MultiPolygon signal duplicates per component and null/missing values remain aligned and unknown")
        suite.check(original?.polygons.allSatisfy { $0.count == 2 } == true,
                    "signal retention keeps each component's original hole")
        let archive = destination.appendingPathComponent("fcc-reference.json")
        let saved = try Data(contentsOf: archive)
        let loaded = TMobileCoverageReferenceStore(folder: destination)
        suite.check(loaded.layer == original && loaded.layer?.modeledSignalDBm == expected && loaded.errorMessage == nil,
                    "modeled signal, source and geometry roundtrip through persisted validation")
        let encoded = String(data: saved, encoding: .utf8) ?? ""
        suite.check(!encoded.contains("excluded-fixture-marker") && !encoded.contains("minsignal")
                    && !encoded.contains("fccMinimumSignalDBm") && encoded.contains("modeledSignalDBm"),
                    "archive retains the typed signal array without arbitrary or original property dictionaries")
        for value: Any in [-120, -50, -85.5, NSNull()] {
            let parsed = try TMobileCoverageReferenceSupport.parse(data([feature(value)]), publishedDate: date)
            suite.check(parsed.modeledSignalDBm?.count == 1, "finite signal boundaries, decimals and explicit null are accepted")
        }
        for value: Any in [true, "-90", -120.01, -49.99, [Int](), ["value": -90]] {
            let invalid = try data([feature(value)])
            let rejected = !store.importLayer(data: invalid, publishedDate: date, source: provenance())
            let after = try Data(contentsOf: archive)
            suite.check(rejected && store.layer == original && after == saved,
                        "invalid supplied modeled signal fails without replacing the saved reference")
        }
        let validText = String(data: try data([feature(-90)]), encoding: .utf8)!
        let nonfinite = validText.replacingOccurrences(of: #""fccMinimumSignalDBm":-90"#, with: #""fccMinimumSignalDBm":1e999"#)
        suite.check((try? TMobileCoverageReferenceSupport.parse(Data(nonfinite.utf8), publishedDate: date)) == nil,
                    "nonfinite JSON numeric signal fails closed")
        suite.check(!TMobileCoverageReferenceSupport.validModeledSignalDBm(.nan)
                    && !TMobileCoverageReferenceSupport.validModeledSignalDBm(.infinity),
                    "nonfinite in-memory modeled values are invalid")
        let savedObject = try JSONSerialization.jsonObject(with: saved) as! [String: Any]
        for invalid: [Any] in [[], [-90], [-90, -90, NSNull(), NSNull(), NSNull()],
                               [-121, -90, NSNull(), NSNull()], [-49, -90, NSNull(), NSNull()],
                               [true, -90, NSNull(), NSNull()], ["-90", -90, NSNull(), NSNull()]] {
            var corrupted = savedObject; corrupted["modeledSignalDBm"] = invalid
            try JSONSerialization.data(withJSONObject: corrupted).write(to: archive)
            let rejected = TMobileCoverageReferenceStore(folder: destination)
            suite.check(rejected.layer == nil && rejected.errorMessage != nil && store.layer == original,
                        "persisted signal count, range or type mismatch cannot display an incorrect layer")
        }
        var legacy = savedObject; legacy.removeValue(forKey: "modeledSignalDBm")
        try JSONSerialization.data(withJSONObject: legacy).write(to: archive)
        let legacyLoaded = TMobileCoverageReferenceStore(folder: destination)
        suite.check(legacyLoaded.layer?.modeledSignalDBm == nil && legacyLoaded.layer?.polygons == original?.polygons
                    && legacyLoaded.layer?.source == original?.source && legacyLoaded.errorMessage == nil,
                    "existing source-aware archives without signal remain valid unknown layers")
        try saved.write(to: archive)
    }

    private static func boundedReader(_ suite: FCCWorkflowSuite, folder: URL) throws {
        let regular = folder.appendingPathComponent("reader-regular")
        let content = Data(repeating: 0x20, count: 16)
        try content.write(to: regular)
        suite.check((try TMobileCoverageReferenceSupport.readLocalFile(at: regular, maximumBytes: 16)) == content,
                    "bounded reader accepts an ordinary file exactly at the byte limit")
        let link = folder.appendingPathComponent("reader-link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: regular)
        let fifo = folder.appendingPathComponent("reader-fifo")
        guard mkfifo(fifo.path, 0o600) == 0 else { throw NSError(domain: "FCCFixture", code: 1) }
        let oversized = folder.appendingPathComponent("reader-oversized")
        FileManager.default.createFile(atPath: oversized.path, contents: nil)
        let sparse = try FileHandle(forWritingTo: oversized)
        try sparse.truncate(atOffset: UInt64(TMobileCoverageReferenceSupport.maximumBytes + 1)); try sparse.close()
        for (url, limit, label) in [(fifo, 16, "FIFO without a writer"), (link, 16, "symbolic link"),
                                   (URL(fileURLWithPath: "/dev/null"), 16, "character device"),
                                   (oversized, TMobileCoverageReferenceSupport.maximumBytes, "oversized sparse file"),
                                   (folder, 16, "directory"), (regular, 15, "file above caller byte limit"),
                                   (regular, 0, "nonpositive byte limit")] {
            suite.check(rejectsPromptly(url, limit: limit), "bounded reader promptly rejects \(label)")
        }
        suite.check((try? TMobileCoverageReferenceSupport.readLocalFile(at: URL(string: "https://example.invalid/fixture")!)) == nil,
                    "non-file URL rejects before any URL loading")
        suite.check((try Data(contentsOf: regular)) == content, "rejected reads do not mutate the selected ordinary file")
    }

    /// A broken FIFO guard must fail the check instead of hanging this harness.
    /// Child arguments contain only synthetic temporary paths and numeric limits.
    private static func rejectsPromptly(_ url: URL, limit: Int) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        process.arguments = ["--reader-reject", url.path, String(limit)]
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        let start = ProcessInfo.processInfo.systemUptime
        do { try process.run() } catch { return false }
        while process.isRunning, ProcessInfo.processInfo.systemUptime - start < 2 { usleep(5_000) }
        let timedOut = process.isRunning
        if timedOut { process.terminate(); usleep(100_000); if process.isRunning { kill(process.processIdentifier, SIGKILL) } }
        process.waitUntilExit()
        return !timedOut && process.terminationReason == .exit && process.terminationStatus == 0
            && ProcessInfo.processInfo.systemUptime - start < 2
    }
    private static func provenance(origin: TMobileFCCReferenceSource.Origin = .officialAPI, date: String = date,
                                   state: String? = "06", technology: Int = 500, down: Double = 35, up: Double = 3,
                                   environment: Int = 1, fileID: String? = "fixture-file-123") -> TMobileFCCReferenceSource {
        .init(origin: origin, availabilityAsOf: date, stateFIPS: state, technology: technology,
              minimumDownloadMbps: down, minimumUploadMbps: up, environment: environment, fileID: fileID)
    }
    private static func safe(_ message: String?) -> Bool { !(message ?? "").contains(token) && !(message ?? "").contains(email) }
    private static func exact(_ query: [String: Any]) -> Bool {
        query[kSecClass as String] as? String == kSecClassGenericPassword as String
            && query[kSecAttrService as String] as? String == service
            && query[kSecAttrAccount as String] as? String == scope.account
            && query[kSecAttrSynchronizable as String] as? Bool == false
            && query[kSecAttrAccessGroup as String] == nil && query[kSecAttrAccess as String] == nil
    }
}

private final class FCCWorkflowSuite {
    var checks = 0; var failures = 0
    func check(_ condition: Bool, _ label: String) { checks += 1; if !condition { failures += 1; print("FAIL: \(label)") } }
}
private final class FCCWorkflowCredentialStore: ScopedCredentialStore {
    var values: [ScopedCredentialScope: String] = [:]
    var reads: [ScopedCredentialScope] = [], writes: [ScopedCredentialScope] = [], deletes: [ScopedCredentialScope] = []
    var readError: Error?, saveError: Error?, deleteError: Error?
    var calls: Int { reads.count + writes.count + deletes.count }
    func read(scope: ScopedCredentialScope) throws -> String? { reads.append(scope); if let readError { throw readError }; return values[scope] }
    func save(_ secret: String, scope: ScopedCredentialScope) throws { writes.append(scope); if let saveError { throw saveError }; values[scope] = secret }
    func delete(scope: ScopedCredentialScope) throws { deletes.append(scope); if let deleteError { throw deleteError }; values[scope] = nil }
}
private final class FCCWorkflowKeychainAccess: ScopedCredentialKeychainAccess {
    var reads: [[String: Any]] = [], adds: [[String: Any]] = [], deletes: [[String: Any]] = []
    var updates: [([String: Any], [String: Any])] = []
    var readData: Data?
    var status: OSStatus = errSecSuccess
    var calls: Int { reads.count + adds.count + updates.count + deletes.count }
    func copyMatching(_ query: [String: Any]) -> (OSStatus, Data?) { reads.append(query); return (status, readData) }
    func add(_ attributes: [String: Any]) -> OSStatus { adds.append(attributes); return errSecSuccess }
    func update(_ query: [String: Any], attributes: [String: Any]) -> OSStatus { updates.append((query, attributes)); return errSecItemNotFound }
    func delete(_ query: [String: Any]) -> OSStatus { deletes.append(query); return errSecSuccess }
}
