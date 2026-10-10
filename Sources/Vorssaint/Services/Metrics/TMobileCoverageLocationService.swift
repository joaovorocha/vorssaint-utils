// SPDX-License-Identifier: GPL-3.0-or-later
import Combine
import CoreLocation
import Foundation

/// The Mac's reported location, which may be based on Wi-Fi rather than GPS.
/// Construction never requests permission or starts location updates.
@MainActor final class TMobileCoverageLocationService: NSObject, ObservableObject {
    static let shared = TMobileCoverageLocationService()

    @Published private(set) var fix: TMobileCoverageLocationFix?
    @Published private(set) var status = "Mac location is off"
    @Published private(set) var authorization: CLAuthorizationStatus

    private enum Demand { case none, once, continuous }
    private var demand: Demand = .none
    private let manager: CLLocationManager

    init(manager: CLLocationManager = CLLocationManager()) {
        self.manager = manager
        authorization = manager.authorizationStatus
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = 10
    }

    /// Call only for an explicit recording or Use Mac location action.
    func start() {
        demand = .continuous
        beginAuthorizedDemand()
    }

    /// A one-shot request from a user action; does not enable recording.
    func requestLocation() {
        if demand != .continuous { demand = .once }
        beginAuthorizedDemand()
    }

    func stop() {
        demand = .none
        manager.stopUpdatingLocation()
        fix = nil
        status = "Mac location is off"
    }

    private func beginAuthorizedDemand() {
        guard demand != .none else { return }
        authorization = manager.authorizationStatus
        switch authorization {
        case .notDetermined:
            status = "Allow Location Services to place your measurements on the map"
            manager.requestWhenInUseAuthorization()
        case .authorizedAlways, .authorizedWhenInUse:
            status = "Finding the Mac's location…"
            if demand == .continuous { manager.startUpdatingLocation() }
            else { manager.requestLocation() }
        case .denied, .restricted:
            manager.stopUpdatingLocation()
            fix = nil
            status = "Mac location is unavailable. Enable Location Services in System Settings."
        @unknown default:
            fix = nil
            status = "Mac location authorization is unavailable"
        }
    }

    private func received(_ locations: [CLLocation]) {
        guard demand != .none else { return }
        let now = Date()
        guard let location = locations.filter({ $0.horizontalAccuracy >= 0 }).max(by: { $0.timestamp < $1.timestamp }) else { return }
        let candidate = TMobileCoverageLocationFix(
            coordinate: .init(latitude: location.coordinate.latitude, longitude: location.coordinate.longitude),
            timestamp: location.timestamp, horizontalAccuracy: location.horizontalAccuracy, source: .mac)
        // Retain only a genuine recent fix. The recorder applies its stricter
        // 100 m accuracy limit before automatic parking tests and scoring.
        guard candidate.isValid, now.timeIntervalSince(candidate.timestamp) >= 0,
              now.timeIntervalSince(candidate.timestamp) <= 30 else {
            fix = nil
            status = "Waiting for a fresh Mac location"
            return
        }
        fix = candidate
        status = "Mac location · ±\(Int(candidate.horizontalAccuracy.rounded())) m"
        if demand == .once {
            demand = .none
            manager.stopUpdatingLocation()
        }
    }

    private func failed(_ error: Error) {
        guard demand != .none else { return }
        fix = nil
        let denied = (error as? CLError)?.code == .denied
        status = denied ? "Mac location permission was denied" : "Mac location is temporarily unavailable"
        if denied { manager.stopUpdatingLocation() }
    }
}

extension TMobileCoverageLocationService: CLLocationManagerDelegate {
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.authorization = self.manager.authorizationStatus
            self.beginAuthorizedDemand()
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        Task { @MainActor [weak self] in self?.received(locations) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor [weak self] in self?.failed(error) }
    }
}
