// SPDX-License-Identifier: GPL-3.0-or-later
import Combine
import Darwin
import Foundation

extension Notification.Name {
    static let tMobileGatewayHistoryPreferenceChanged = Notification.Name("TMobileGatewayHistoryPreferenceChanged")
}

@MainActor final class TMobileGatewayHistoryStore: ObservableObject {
    static let shared = TMobileGatewayHistoryStore()
    static let recordingKey = "tMobileHistoryRecording"
    @Published private(set) var samples: [TMobileHistorySample] = []
    @Published private(set) var towers: [TMobileTowerPin] = []
    @Published var measurementCoordinate: TMobileMapCoordinate? { didSet { persist() } }
    @Published private(set) var errorMessage: String?
    @Published private(set) var removedTower: TMobileTowerPin?
    @Published var isRecording: Bool {
        didSet {
            defaults.set(isRecording, forKey: Self.recordingKey)
            NotificationCenter.default.post(name: .tMobileGatewayHistoryPreferenceChanged, object: nil)
        }
    }
    private let folder: URL
    private let defaults: UserDefaults
    private var loading = true
    private var pruningTimer: AnyCancellable?
    private struct Archive: Codable {
        let version: Int
        let samples: [TMobileHistorySample]
        let towers: [TMobileTowerPin]
        let measurementCoordinate: TMobileMapCoordinate?
    }

    init(folder: URL? = nil, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.folder = folder ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "io.github.joaovorocha.shadowutils", isDirectory: true)
            .appendingPathComponent("T-Mobile", isDirectory: true)
        isRecording = defaults.bool(forKey: Self.recordingKey)
        var needsRewrite = false
        let file = self.folder.appendingPathComponent("history.json")
        if let attrs = try? FileManager.default.attributesOfItem(atPath: file.path),
           (attrs[.size] as? NSNumber)?.intValue ?? Int.max <= 20_000_000,
           attrs[.type] as? FileAttributeType == .typeRegular,
           let data = try? Data(contentsOf: file), let archive = try? JSONDecoder().decode(Archive.self, from: data), archive.version == 1 {
            var sampleIDs = Set<UUID>(), towerIDs = Set<UUID>()
            samples = TMobileGatewayHistorySupport.retained(archive.samples, now: Date()).filter { sampleIDs.insert($0.id).inserted }
            towers = Array(archive.towers.filter { $0.isValid && towerIDs.insert($0.id).inserted }.prefix(5_000))
            measurementCoordinate = archive.measurementCoordinate.flatMap { $0.isValid ? $0 : nil }
            needsRewrite = samples.count != archive.samples.count || towers.count != archive.towers.count
        }
        loading = false
        if needsRewrite { persist() }
        pruningTimer = Timer.publish(every: 60, on: .main, in: .common).autoconnect().sink { [weak self] date in self?.prune(at: date) }
    }

    func record(snapshot: TMobileGatewaySnapshot, at date: Date = Date()) {
        guard isRecording, date.timeIntervalSince1970.isFinite, TMobileGatewaySupport.isValidSnapshot(snapshot) else { return }
        // One sample per minute; live menu bar readings continue every 15 seconds.
        guard samples.last.map({ date.timeIntervalSince($0.date) >= 60 }) ?? true else { return }
        samples.append(.init(date: date, snapshot: snapshot, coordinate: measurementCoordinate))
        samples = TMobileGatewayHistorySupport.retained(samples, now: date)
        persist()
    }

    func addTower(_ pin: TMobileTowerPin) {
        guard pin.isValid, towers.count < 5_000 else { errorMessage = "Enter a valid name and coordinates. Maximum 5,000 towers."; return }
        towers.append(pin); persist()
    }

    func removeTower(_ pin: TMobileTowerPin) {
        removedTower = pin
        towers.removeAll { $0.id == pin.id }; persist()
    }

    func undoTowerRemoval() {
        guard let pin = removedTower, towers.count < 5_000 else { return }
        towers.append(pin); removedTower = nil; persist()
    }

    func clearHistory() { samples = []; persist() }

    func prune(at date: Date = Date()) {
        let retained = TMobileGatewayHistorySupport.retained(samples, now: date)
        if retained.count != samples.count { samples = retained; persist() }
    }

    func importTowers(from url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
            guard attrs[.type] as? FileAttributeType == .typeRegular,
                  (attrs[.size] as? NSNumber)?.intValue ?? Int.max <= 2_000_000 else { throw TMobileTowerImportError.invalidFile }
            let imported = try TMobileGatewayHistorySupport.importTowers(Data(contentsOf: url), json: url.pathExtension.lowercased() == "json")
            guard towers.count + imported.count <= 5_000 else { throw TMobileTowerImportError.invalidFile }
            towers.append(contentsOf: imported); persist()
        } catch { errorMessage = error.localizedDescription }
    }

    func dismissError() { errorMessage = nil }

    private func persist() {
        guard !loading else { return }
        let fm = FileManager.default
        let temporary = folder.appendingPathComponent(".history-\(UUID().uuidString).tmp")
        do {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let attrs = try fm.attributesOfItem(atPath: folder.path)
            guard attrs[.type] as? FileAttributeType == .typeDirectory else { throw CocoaError(.fileWriteNoPermission) }
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
            let data = try JSONEncoder().encode(Archive(version: 1, samples: samples, towers: towers, measurementCoordinate: measurementCoordinate))
            guard fm.createFile(atPath: temporary.path, contents: data, attributes: [.posixPermissions: 0o600]) else { throw CocoaError(.fileWriteUnknown) }
            let destination = folder.appendingPathComponent("history.json")
            guard rename(temporary.path, destination.path) == 0 else { throw CocoaError(.fileWriteUnknown) }
            errorMessage = nil
        } catch {
            try? fm.removeItem(at: temporary)
            errorMessage = "Local history could not be saved. Check this Mac’s Application Support folder permissions."
        }
    }
}
