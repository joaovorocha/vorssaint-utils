// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

enum TMobileGatewayHistoryTests {
    static func run(_ suite: TestSuite) {
        let csv = "name,latitude,longitude,bands,cellID\r\n\"Test, tower\",40,-100,n41,12345\r\n"
        let pins = try? TMobileGatewayHistorySupport.importTowers(Data(csv.utf8), json: false)
        suite.expect(pins?.count == 1 && pins?.first?.name == "Test, tower" && pins?.first?.cellID == "12345", "local CSV quoted labels and CRLF parse")
        let json = #"[{"name":"Example","latitude":40,"longitude":-100}]"#
        suite.expect((try? TMobileGatewayHistorySupport.importTowers(Data(json.utf8), json: true))?.first?.bands == "", "JSON optional tower fields stay empty")
        for text in [#"[{"name":"Bad","latitude":91,"longitude":0}]"#, #"[{"name":"Bad","latitude":0,"longitude":181}]"#, #"[{"name":"","latitude":0,"longitude":0}]"#, #"[{"name":"Bad\nlabel","latitude":0,"longitude":0}]"#, "[]"] {
            suite.expect((try? TMobileGatewayHistorySupport.importTowers(Data(text.utf8), json: true)) == nil, "invalid local coordinates/labels reject the entire import")
        }
        suite.expect((try? TMobileGatewayHistorySupport.importTowers(Data(repeating: 32, count: 2_000_001), json: true)) == nil, "local import is size bounded")
        suite.expect((try? TMobileGatewayHistorySupport.importTowers(Data("name,latitude,longitude,bands,cellID\n\"unfinished,1,2,n41,3".utf8), json: false)) == nil, "unterminated CSV rejects")
        suite.expect(!TMobileMapCoordinate(latitude: .nan, longitude: 0).isValid, "nonfinite coordinate rejected")
        MainActor.assumeIsolated { persistence(suite) }
    }

    @MainActor private static func persistence(_ suite: TestSuite) {
        let domain = "com.vorssaint.tests.tmobile-history.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: domain)!
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(domain, isDirectory: true)
        defer { defaults.removePersistentDomain(forName: domain); try? FileManager.default.removeItem(at: folder) }
        let store = TMobileGatewayHistoryStore(folder: folder, defaults: defaults)
        let snapshot = try! TMobileGatewaySupport.parse(Data(#"{"signal":{"5g":{"rsrp":-95,"bands":["n41"]}}}"#.utf8))
        let now = Date()
        store.record(snapshot: snapshot, at: now)
        suite.expect(store.samples.isEmpty && !FileManager.default.fileExists(atPath: folder.path), "history defaults off and creates no files")
        store.isRecording = true
        store.measurementCoordinate = .init(latitude: 40, longitude: -100)
        store.record(snapshot: snapshot, at: now)
        store.record(snapshot: snapshot, at: now.addingTimeInterval(15))
        suite.expect(store.samples.count == 1 && store.samples[0].coordinate?.latitude == 40, "explicit history records once per minute with manual coordinate")
        let attrs = try? FileManager.default.attributesOfItem(atPath: folder.appendingPathComponent("history.json").path)
        suite.expect((attrs?[.posixPermissions] as? NSNumber)?.intValue == 0o600, "history archive is owner readable/writable only")
        let dir = try? FileManager.default.attributesOfItem(atPath: folder.path)
        suite.expect((dir?[.posixPermissions] as? NSNumber)?.intValue == 0o700, "history directory is owner only")
        let localPin = TMobileTowerPin(name: "Example", latitude: 40, longitude: -100,
                                      bands: "n41", cellID: nil, radio: .nr,
                                      nodeID: 12_345, ecgi: "001-01-12345", provenance: "Synthetic manual pin")
        store.addTower(localPin)
        let restored = TMobileGatewayHistoryStore(folder: folder, defaults: defaults)
        suite.expect(restored.samples.count == 1 && restored.samples[0].snapshot == snapshot && restored.towers.count == 1 && restored.isRecording, "local history and pins round-trip with explicit recording preference")
        suite.expect(restored.towers == [localPin], "local identity metadata, provenance and pin UUID survive the version-one history archive")
        store.isRecording = false
        store.record(snapshot: snapshot, at: now.addingTimeInterval(60))
        suite.expect(store.samples.count == 1, "turning recording off prevents another saved sample")
        let old = TMobileHistorySample(date: now.addingTimeInterval(-8 * 86400), snapshot: snapshot, coordinate: nil)
        let future = TMobileHistorySample(date: now.addingTimeInterval(10), snapshot: snapshot, coordinate: nil)
        suite.expect(TMobileGatewayHistorySupport.retained([old, store.samples[0], future], now: now).count == 1, "retention excludes old and future timestamps")
        let many = (0...10_100).map { TMobileHistorySample(date: now.addingTimeInterval(-Double($0)), snapshot: snapshot, coordinate: nil) }
        suite.expect(TMobileGatewayHistorySupport.retained(many, now: now).count == 10_000, "history count is bounded")
        let bytes = try? Data(contentsOf: folder.appendingPathComponent("history.json"))
        let saved = bytes.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        suite.expect(!saved.contains("192.168") && !saved.contains("gps") && !saved.contains("serialNumber"), "archive retains only normalized snapshots and manual coordinates")
        let tower = store.towers[0]
        store.removeTower(tower)
        suite.expect(store.towers.isEmpty && store.removedTower == tower, "tower removal keeps a recoverable undo")
        store.undoTowerRemoval()
        suite.expect(store.towers == [tower] && store.removedTower == nil, "tower removal can be undone")
        store.prune(at: now.addingTimeInterval(8 * 86400))
        suite.expect(store.samples.isEmpty, "pruning expires history even with recording off")
    }
}
