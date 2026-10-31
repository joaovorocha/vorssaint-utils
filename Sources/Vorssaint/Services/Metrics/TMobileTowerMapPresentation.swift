// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint
import Foundation

/// Describes an existing reference without inferring a site, attachment, or
/// capability from its name, band text, or identifiers.
struct TMobileTowerMapPresentation {
    struct BandDescription {
        let code: String
        let guide: TMobileBandGuide.Entry
    }

    struct RelativePosition: Equatable {
        let distance: String
        let bearing: String?
    }

    static let openCellIDSource = URL(string: "https://opencellid.org")!
    static let openCellIDLicense = URL(string: "https://creativecommons.org/licenses/by-sa/4.0/")!

    let title: String
    let isCommunityCellEstimate: Bool
    let source: String
    let latitude: String
    let longitude: String
    let technology: String
    let bands: String
    let bandDescriptions: [BandDescription]
    let relativePosition: RelativePosition?
    let cellID: String?
    let nodeLabel: String
    let nodeID: String?
    let ecgi: String?

    var status: String { isCommunityCellEstimate ? "Community cell estimate" : "Location unverified" }
    var positionDescription: String { isCommunityCellEstimate ? "Estimated cell position" : "Source-declared position" }
    var speedAndCapacity: String { "Not provided" }
    var hasIdentity: Bool { cellID != nil || nodeID != nil || ecgi != nil }

    init(pin: TMobileTowerPin, measurementCoordinate: TMobileMapCoordinate? = nil) {
        title = Self.nonempty(pin.name) ?? "Unnamed reference"
        source = Self.nonempty(pin.provenance) ?? "Source not provided"
        isCommunityCellEstimate = pin.provenance?.localizedCaseInsensitiveContains("opencellid") == true
        latitude = pin.coordinate.isValid ? Self.coordinate(pin.latitude) : "Unavailable"
        longitude = pin.coordinate.isValid ? Self.coordinate(pin.longitude) : "Unavailable"
        technology = pin.radio?.label ?? "Not provided"
        bands = Self.nonempty(pin.bands) ?? "Not provided"
        bandDescriptions = Self.describeBands(pin.bands)
        cellID = Self.nonempty(pin.cellID)
        nodeLabel = pin.radio?.nodeLabel ?? "Node ID"
        nodeID = pin.nodeID.map { String($0) }
        ecgi = Self.nonempty(pin.ecgi)
        relativePosition = measurementCoordinate
            .flatMap { TMobileTowerReferenceSupport.geometry(from: $0, to: pin.coordinate) }
            .map { geometry in
                let distance = geometry.distanceMeters < 1_000
                    ? "\(Self.number(geometry.distanceMeters, decimals: 0)) m"
                    : "\(Self.number(geometry.distanceMeters / 1_000, decimals: 1)) km"
                let bearing = geometry.bearingDegrees.map { degrees in
                    let rounded = Int(degrees.rounded()) % 360
                    let directions = ["N", "NE", "E", "SE", "S", "SW", "W", "NW"]
                    let direction = directions[Int((degrees / 45).rounded()) % directions.count]
                    return "\(rounded)° \(direction)"
                }
                return RelativePosition(distance: distance, bearing: bearing)
            }
    }

    private static func nonempty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }

    private static func coordinate(_ value: Double) -> String {
        // Suppress negative zero after rounding; displayed digits are not an
        // assertion of surveyed accuracy.
        number(abs(value) < 0.0000005 ? 0 : value, decimals: 6)
    }

    private static func number(_ value: Double, decimals: Int) -> String {
        String(format: "%.*f", locale: Locale(identifier: "en_US_POSIX"), decimals, value)
    }

    private static func describeBands(_ value: String) -> [BandDescription] {
        // Only explicit b/n codes have a meaning in the existing guide. A bare
        // number or a gateway capability list never supplies a tower radio.
        guard let pattern = try? NSRegularExpression(pattern: #"(?i)(?<![\p{L}\p{N}])[bn][0-9]{1,3}(?![\p{L}\p{N}])"#) else { return [] }
        var seen = Set<String>()
        return pattern.matches(in: value, range: NSRange(value.startIndex..., in: value)).compactMap { match in
            guard let range = Range(match.range, in: value) else { return nil }
            let code = value[range].lowercased()
            guard seen.insert(code).inserted, let guide = TMobileBandGuide.entry(for: code) else { return nil }
            return BandDescription(code: code, guide: guide)
        }
    }
}
