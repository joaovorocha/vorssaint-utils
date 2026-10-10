// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import Combine
import Foundation
import IOKit

/// Explicitly started, local-only coverage recording. No launch-time location
/// request, automatic session resume, server connection, or background wake.
@MainActor final class TMobileCoverageRecorder: ObservableObject {
    static let shared = TMobileCoverageRecorder()
    static let automaticTestsKey = "tMobileCoverageAutomaticParkedTests"

    let location: TMobileCoverageLocationService
    @Published private(set) var isRecording = false
    @Published private(set) var isSuspended = false
    @Published private(set) var status = "Recording is off"
    @Published private(set) var parkingStatus = "Start recording to detect a parked stop"
    @Published private(set) var speedPhase: SpeedTest.Phase = .idle
    @Published var automaticParkedTestsEnabled: Bool {
        didSet {
            defaults.set(automaticParkedTestsEnabled, forKey: Self.automaticTestsKey)
            parking.reset()
            if !automaticParkedTestsEnabled { parkingStatus = "Automatic parked tests are off" }
        }
    }

    var isTestingSpeed: Bool { speed.isRunning || testContext != nil }

    private let defaults: UserDefaults
    private let monitor: TMobileGatewayMonitor
    private let store: TMobileCoverageStore
    private let speed: SpeedTest
    private var parking = TMobileCoverageParkedDetector()
    private var latestSnapshot: TMobileGatewaySnapshot?
    private var latestSnapshotDate: Date?
    private var latestObservationID: UUID?
    private var lastCompletedTestObservationID: UUID?
    private var testContext: TMobileCoverageSpeedContext?
    private var testObservationID: UUID?
    private var address: String
    private var sessionStartedAt: Date?
    private var waitingForDisplayWake = false
    private var lidNotificationPort: IONotificationPortRef?
    private var lidNotification: io_object_t = 0
    private var openGaps: [String: (TMobileCoverageGapReason, Date)] = [:]
    private var timer: AnyCancellable?
    private var cancellables = Set<AnyCancellable>()

    init(location: TMobileCoverageLocationService? = nil,
         monitor: TMobileGatewayMonitor? = nil, store: TMobileCoverageStore? = nil,
         defaults: UserDefaults = .standard,
         speed: SpeedTest = SpeedTest(configuration: .ephemeral, sampleSeconds: 3,
                                      maximumDownloadBytes: 20_000_000, maximumUploadBytes: 5_000_000)) {
        let location = location ?? TMobileCoverageLocationService.shared
        let monitor = monitor ?? TMobileGatewayMonitor.shared
        let store = store ?? TMobileCoverageStore.shared
        self.location = location
        self.monitor = monitor
        self.store = store
        self.defaults = defaults
        self.speed = speed
        address = defaults.string(forKey: DefaultsKey.tMobileGatewayAddress) ?? TMobileGatewayService.defaultBaseURL
        automaticParkedTestsEnabled = defaults.object(forKey: Self.automaticTestsKey) as? Bool ?? true

        NotificationCenter.default.publisher(for: TMobileGatewayMonitor.snapshotDidUpdate, object: monitor)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notification in
                guard let snapshot = notification.userInfo?["snapshot"] as? TMobileGatewaySnapshot,
                      let date = notification.userInfo?["date"] as? Date else { return }
                self?.received(snapshot: snapshot, at: date)
            }.store(in: &cancellables)
        monitor.service.$snapshot.receive(on: DispatchQueue.main)
            .sink { [weak self] snapshot in
                if snapshot == nil { self?.gatewayBecameUnavailable() }
            }.store(in: &cancellables)
        location.$fix.receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.tick(at: Date()) }.store(in: &cancellables)
        speed.$phase.receive(on: DispatchQueue.main)
            .sink { [weak self] phase in self?.speedChanged(phase) }.store(in: &cancellables)
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.preferencesChanged() }.store(in: &cancellables)

        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification] {
            workspace.publisher(for: name).receive(on: DispatchQueue.main)
                .sink { [weak self] _ in
                    self?.waitingForDisplayWake = true
                    self?.suspend(at: Date())
                }.store(in: &cancellables)
        }
        // A full wake can precede display wake. Resume only once a display is
        // awake, so a closed/sleeping Mac does not collect fresh observations.
        workspace.publisher(for: NSWorkspace.didWakeNotification).receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self, self.isSuspended else { return }
                self.parking.reset()
                self.status = "Mac woke · waiting for the display to wake before recording"
            }.store(in: &cancellables)
        workspace.publisher(for: NSWorkspace.screensDidWakeNotification).receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.waitingForDisplayWake = false
                self?.resume(at: Date())
            }.store(in: &cancellables)
        NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)
            .sink { [weak self] _ in self?.finish(at: Date(), reason: .appClosed) }.store(in: &cancellables)
    }

    deinit {
        if lidNotification != 0 { IOObjectRelease(lidNotification) }
        if let lidNotificationPort { IONotificationPortDestroy(lidNotificationPort) }
    }

    func start(name: String = "Coverage session") {
        guard !isRecording else { return }
        guard BrightnessService.lidClosed() != true else {
            status = "Open the Mac's lid before starting coverage recording"
            return
        }
        let now = Date()
        guard store.beginSession(name: name, at: now) != nil else {
            status = store.errorMessage ?? "A local coverage session could not be created"
            return
        }
        latestSnapshot = nil
        latestSnapshotDate = nil
        latestObservationID = nil
        lastCompletedTestObservationID = nil
        parking.reset()
        isSuspended = false
        waitingForDisplayWake = false
        isRecording = true
        sessionStartedAt = now
        defaults.set(automaticParkedTestsEnabled, forKey: Self.automaticTestsKey)
        status = "Recording on this Mac"
        observeLid()
        if !isSuspended {
            location.start()
            monitor.setCoverageRecording(true)
        }
        timer = Timer.publish(every: 10, on: .main, in: .common).autoconnect()
            .sink { [weak self] in self?.tick(at: $0) }
        setGap(.locationUnavailable, unavailable: true, at: now)
        setGap(.gatewayUnavailable, unavailable: true, at: now)
    }

    func stop(reason: TMobileCoverageGapReason = .recordingPaused) { finish(at: Date(), reason: reason) }

    /// Does not start a recording session or a speed test.
    func useMacLocation() { location.requestLocation() }

    func runSpeedTest() { beginSpeedTest(automatic: false, at: Date()) }

    func cancelSpeedTest() {
        guard testContext != nil || speed.isRunning else { return }
        testContext = nil
        testObservationID = nil
        speed.cancel()
        status = isRecording ? "Speed test cancelled · recording continues" : "Speed test cancelled"
    }

    private func finish(at date: Date, reason: TMobileCoverageGapReason) {
        guard isRecording else { return }
        cancelSpeedTest()
        for (_, value) in openGaps { store.addGap(reason: value.0, from: value.1, to: date) }
        openGaps.removeAll()
        store.addGap(reason: reason, from: date)
        store.endSession(at: date)
        isRecording = false
        isSuspended = false
        sessionStartedAt = nil
        stopObservingLid()
        timer?.cancel()
        timer = nil
        location.stop()
        monitor.setCoverageRecording(false)
        parking.reset()
        latestSnapshot = nil
        latestSnapshotDate = nil
        latestObservationID = nil
        status = store.errorMessage ?? "Recording stopped · saved on this Mac"
        parkingStatus = "Start recording to detect a parked stop"
    }

    private func received(snapshot: TMobileGatewaySnapshot, at date: Date) {
        guard isRecording else { return }
        lidStateChanged()
        guard !isSuspended, let sessionStartedAt, date >= sessionStartedAt,
              TMobileGatewaySupport.isValidSnapshot(snapshot),
              (0...30).contains(Date().timeIntervalSince(date)) else { return }
        let previousAddress = address
        preferencesChanged()
        guard previousAddress == address else { return }
        latestSnapshot = snapshot
        latestSnapshotDate = date
        let fix = freshLocation(at: date)
        latestObservationID = store.record(snapshot: snapshot, at: date, location: fix)
        if latestObservationID == nil, let error = store.errorMessage {
            status = error
            // Automatic network activity must not continue if its local
            // observation or stop attempt cannot be durably saved.
            cancelSpeedTest()
        }
        setGap(.gatewayUnavailable, unavailable: false, at: date)
        tick(at: Date())
    }

    private func gatewayBecameUnavailable() {
        latestSnapshot = nil
        latestSnapshotDate = nil
        latestObservationID = nil
        guard isRecording, !isSuspended else { return }
        setGap(.gatewayUnavailable, unavailable: true, at: Date())
        validateTest(at: Date())
    }

    private func freshSnapshot(at date: Date) -> TMobileGatewaySnapshot? {
        guard let latestSnapshot, let receivedAt = latestSnapshotDate,
              date.timeIntervalSince(receivedAt) >= 0, date.timeIntervalSince(receivedAt) <= 30 else { return nil }
        return latestSnapshot
    }

    private func freshLocation(at date: Date) -> TMobileCoverageLocationFix? {
        guard let fix = location.fix, fix.isValid,
              (0...30).contains(date.timeIntervalSince(fix.timestamp)) else { return nil }
        return fix
    }

    private func tick(at date: Date) {
        guard isRecording else { return }
        lidStateChanged()
        guard !isSuspended else { return }
        let rawFix = freshLocation(at: date)
        let fix = rawFix.flatMap { TMobileCoverageParkedDetector.usable($0, at: date) ? $0 : nil }
        setGap(.locationUnavailable, unavailable: rawFix == nil, at: date)
        setGap(.gatewayUnavailable, unavailable: freshSnapshot(at: date) == nil, at: date)
        validateTest(at: date)
        guard automaticParkedTestsEnabled else { parkingStatus = "Automatic parked tests are off"; return }
        let stops = store.testedStops.map { TMobileCoverageParkedDetector.TestedStop(location: $0.location, testedAt: $0.testedAt) }
        let candidate = parking.update(fix: fix, at: date, testedStops: stops)
        switch parking.state {
        case .waitingForLocation: parkingStatus = "Waiting for a fresh Mac location within ±100 m"
        case .settling(let seconds): parkingStatus = "Parked test in \(seconds) seconds if the Mac stays here"
        case .alreadyTestedHere: parkingStatus = "This stop has already been tested"
        case .cooldown: parkingStatus = "Waiting for the 15-minute speed-test cooldown"
        case .ready: parkingStatus = "Parked at a new place · ready to test"
        }
        if candidate != nil, !isTestingSpeed, freshSnapshot(at: date) != nil {
            beginSpeedTest(automatic: true, at: date)
        }
    }

    private func beginSpeedTest(automatic: Bool, at date: Date) {
        guard isRecording else { return }
        lidStateChanged()
        guard !isSuspended, !isTestingSpeed else { return }
        guard let snapshot = freshSnapshot(at: date), TMobileCoverageRadioIdentity(snapshot: snapshot) != nil,
              let observationID = latestObservationID else {
            status = "Waiting for a fresh serving-radio reading before testing speed"
            return
        }
        guard observationID != lastCompletedTestObservationID else {
            status = "Waiting for the next radio sample before another speed test"
            return
        }
        let fix = freshLocation(at: date)
        if automatic && fix.map({ TMobileCoverageParkedDetector.usable($0, at: date) }) != true { return }
        if let fix, TMobileCoverageParkedDetector.usable(fix, at: date) {
            guard store.noteTestedStop(location: fix, at: date) else {
                status = store.errorMessage ?? "The speed-test stop could not be saved"
                return
            }
            parking.markAttempted()
        }
        testContext = .init(startedAt: date, startLocation: fix, snapshot: snapshot)
        testObservationID = observationID
        status = automatic ? "Testing the new parked stop with Cloudflare…" : "Testing speed with Cloudflare…"
        speed.start()
    }

    private func validateTest(at date: Date) {
        testContext?.validate(location: location.fix, snapshot: freshSnapshot(at: date),
                              snapshotDate: latestSnapshotDate, at: date)
    }

    private func speedChanged(_ phase: SpeedTest.Phase) {
        speedPhase = phase
        guard testContext != nil else { return }
        switch phase {
        case .done:
            saveCompletedDownload(uploadFailed: false, at: Date())
        case .failed:
            if speed.downloadMbps != nil {
                saveCompletedDownload(uploadFailed: true, at: Date())
            } else {
                testContext = nil
                testObservationID = nil
                status = "Speed test failed · this stop will not be tested again automatically"
            }
        default: break
        }
    }

    private func saveCompletedDownload(uploadFailed: Bool, at endedAt: Date) {
        validateTest(at: endedAt)
        if uploadFailed { testContext?.markUploadFailed() }
        guard let context = testContext, let observationID = testObservationID,
              let download = speed.downloadMbps, download.isFinite, download >= 0 else {
            cancelSpeedTest()
            return
        }
        let result = TMobileCoverageSpeedResult(startedAt: context.startedAt, endedAt: endedAt,
            startLocation: context.startLocation, endLocation: freshLocation(at: endedAt),
            downloadMbps: download, uploadMbps: uploadFailed ? nil : speed.uploadMbps,
            latencyMilliseconds: speed.latencyMs, provider: "Cloudflare",
            scoreEligible: context.invalidationReason == nil,
            invalidationReason: context.invalidationReason)
        testContext = nil
        testObservationID = nil
        let saved = store.recordSpeedTest(result, for: observationID)
        if saved { lastCompletedTestObservationID = observationID }
        if !saved { status = store.errorMessage ?? "The speed result could not be saved" }
        else if uploadFailed { status = "Download saved; upload test failed · recording continues" }
        else {
            status = result.scoreEligible ? "Speed test saved · recording continues"
                : "Speed saved without a Connection Score: \(context.invalidationReason ?? "context changed")"
        }
    }

    private func preferencesChanged() {
        let newAddress = defaults.string(forKey: DefaultsKey.tMobileGatewayAddress) ?? TMobileGatewayService.defaultBaseURL
        guard address != newAddress else { return }
        address = newAddress
        latestSnapshot = nil
        latestSnapshotDate = nil
        latestObservationID = nil
        parking.reset()
        if isRecording {
            cancelSpeedTest()
            setGap(.gatewayUnavailable, unavailable: true, at: Date())
            status = "Gateway address changed · waiting for fresh radio data"
        }
    }

    private func suspend(at date: Date) {
        guard isRecording, !isSuspended else { return }
        isSuspended = true
        cancelSpeedTest()
        parking.reset()
        location.stop()
        monitor.setCoverageRecording(false)
        latestSnapshot = nil
        latestSnapshotDate = nil
        latestObservationID = nil
        setGap(.sleep, unavailable: true, at: date)
        status = "Recording paused while the Mac or display sleeps"
    }

    private func resume(at date: Date) {
        guard isRecording, isSuspended, !waitingForDisplayWake,
              BrightnessService.lidClosed() != true else { return }
        isSuspended = false
        setGap(.sleep, unavailable: false, at: date)
        parking.reset()
        location.start()
        monitor.setCoverageRecording(true)
        status = "Recording resumed · waiting for fresh location and radio data"
    }

    private func setGap(_ reason: TMobileCoverageGapReason, unavailable: Bool, at date: Date) {
        if unavailable, openGaps[reason.rawValue] == nil {
            openGaps[reason.rawValue] = (reason, date)
            store.addGap(reason: reason, from: date)
        } else if !unavailable, let (_, startedAt) = openGaps.removeValue(forKey: reason.rawValue) {
            store.addGap(reason: reason, from: startedAt, to: max(date, startedAt))
        }
    }

    /// Same read-only lid query used by the display feature. Observing the
    /// root-domain interest does not change sleep, brightness, or power policy.
    private func observeLid() {
        guard lidNotificationPort == nil else { return }
        let root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard root != 0 else { return }
        defer { IOObjectRelease(root) }
        guard let port = IONotificationPortCreate(kIOMainPortDefault) else { return }
        let result = IOServiceAddInterestNotification(port, root, kIOGeneralInterest, { context, _, _, _ in
            guard let context else { return }
            let recorder = Unmanaged<TMobileCoverageRecorder>.fromOpaque(context).takeUnretainedValue()
            DispatchQueue.main.async { [weak recorder] in recorder?.lidStateChanged() }
        }, Unmanaged.passUnretained(self).toOpaque(), &lidNotification)
        guard result == KERN_SUCCESS else { IONotificationPortDestroy(port); return }
        lidNotificationPort = port
        IONotificationPortSetDispatchQueue(port, DispatchQueue.main)
        lidStateChanged()
    }

    private func stopObservingLid() {
        if lidNotification != 0 { IOObjectRelease(lidNotification); lidNotification = 0 }
        if let port = lidNotificationPort { IONotificationPortDestroy(port); lidNotificationPort = nil }
    }

    private func lidStateChanged() {
        guard isRecording else { return }
        if BrightnessService.lidClosed() == true {
            suspend(at: Date())
            status = "Recording paused while the Mac's lid is closed"
        } else if isSuspended, !waitingForDisplayWake {
            resume(at: Date())
        }
    }
}
