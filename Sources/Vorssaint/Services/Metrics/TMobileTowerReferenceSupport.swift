// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint
import Foundation

enum TMobileTowerRadio: String, Codable, CaseIterable {
    case lte = "LTE"
    case nr = "NR"

    var label: String { self == .nr ? "5G NR" : "LTE / 4G" }
    var nodeLabel: String { self == .nr ? "gNB ID" : "eNB ID" }
}

enum TMobileTowerIdentityMatch: Equatable {
    case ecgi, node, ecgiAndNode

    var label: String {
        switch self {
        case .ecgi: return "ECGI matches"
        case .node: return "Node ID matches"
        case .ecgiAndNode: return "ECGI and node ID match"
        }
    }
}

struct TMobileTowerGeometry: Equatable {
    let distanceMeters: Double
    // Direction is undefined when the two supplied points coincide.
    let bearingDegrees: Double?
}

/// Compares owner-supplied references only. No legacy sector CID, band, identity
/// bit slicing, database lookup, location request or position estimate is used.
enum TMobileTowerReferenceSupport {
    static func canonicalECGI(_ value: String) -> String? {
        guard !value.isEmpty, value.utf8.count <= 64 else { return nil }
        let body = value.hasPrefix("0x") || value.hasPrefix("0X") ? String(value.dropFirst(2)) : value
        guard !body.isEmpty else { return nil }
        var hasDigit = value.utf8.contains(where: { (48...57).contains($0) })
        var hasNonzero = false, previousSeparator = true
        for character in body.utf8 {
            if character == 45 || character == 58 {
                guard !previousSeparator else { return nil }
                previousSeparator = true
            } else {
                let digit = (48...57).contains(character)
                let hexLetter = (65...70).contains(character) || (97...102).contains(character)
                guard digit || hexLetter else { return nil }
                hasDigit = hasDigit || digit
                hasNonzero = hasNonzero || character != 48
                previousSeparator = false
            }
        }
        guard hasDigit, hasNonzero, !previousSeparator else { return nil }
        // Opaque reported text: never infer a number, node split or alternate format.
        return value
    }

    static func match(_ pin: TMobileTowerPin, radio: TMobileTowerRadio,
                      nodeID: UInt32?, ecgi: String?) -> TMobileTowerIdentityMatch? {
        guard pin.isValid, pin.radio == radio else { return nil }
        if radio == .lte, let nodeID, nodeID > 0x0FFF_FFFF { return nil }
        if let ecgi, canonicalECGI(ecgi) == nil { return nil }
        let savedECGI = pin.ecgi.flatMap(canonicalECGI)
        let currentECGI = ecgi.flatMap(canonicalECGI)
        // A conflicting supplied identifier cannot be overridden by another hit.
        if let savedECGI, let currentECGI, savedECGI != currentECGI { return nil }
        if let savedNode = pin.nodeID, let nodeID, savedNode != nodeID { return nil }
        let ecgiMatches = savedECGI != nil && savedECGI == currentECGI
        let nodeMatches = pin.nodeID != nil && pin.nodeID == nodeID
        if ecgiMatches && nodeMatches { return .ecgiAndNode }
        if ecgiMatches { return .ecgi }
        if nodeMatches { return .node }
        return nil
    }

    static func geometry(from: TMobileMapCoordinate, to: TMobileMapCoordinate) -> TMobileTowerGeometry? {
        guard from.isValid, to.isValid else { return nil }
        let latitude1 = from.latitude * .pi / 180, latitude2 = to.latitude * .pi / 180
        let deltaLatitude = latitude2 - latitude1
        let deltaLongitude = (to.longitude - from.longitude) * .pi / 180
        let a = pow(sin(deltaLatitude / 2), 2)
            + cos(latitude1) * cos(latitude2) * pow(sin(deltaLongitude / 2), 2)
        let distance = 6_371_000 * 2 * atan2(sqrt(max(0, min(1, a))), sqrt(max(0, 1 - min(1, a))))
        let y = sin(deltaLongitude) * cos(latitude2)
        let x = cos(latitude1) * sin(latitude2) - sin(latitude1) * cos(latitude2) * cos(deltaLongitude)
        let bearing = distance < 0.001 || abs(x) + abs(y) < 1e-12
            ? nil : (atan2(y, x) * 180 / .pi + 360).truncatingRemainder(dividingBy: 360)
        return .init(distanceMeters: distance, bearingDegrees: bearing)
    }
}
