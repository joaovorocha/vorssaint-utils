// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint
import Foundation

@main struct TMobileTowerMapPresentationHarness {
    private static var checks = 0

    private static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        checks += 1
        precondition(condition(), message)
    }

    @MainActor static func main() {
        let unknownPin = pin()
        let unknown = TMobileTowerMapPresentation(pin: unknownPin)
        check(unknown.title == "Reference", "The source-provided name remains the inspector title")
        check(unknown.status == "Location unverified", "An ordinary local pin is never verified by presentation")
        check(unknown.positionDescription == "Source-declared position", "Ordinary coordinates retain declared provenance")
        check(unknown.source == "Source not provided", "Missing provenance stays unavailable")
        check(unknown.technology == "Not provided", "Missing technology is not inferred")
        check(unknown.bands == "Not provided" && unknown.bandDescriptions.isEmpty, "Missing band text stays unavailable")
        check(unknown.speedAndCapacity == "Not provided", "The model contains no speed or capacity evidence")
        check(unknown.relativePosition == nil, "No distance appears without a supplied measurement location")
        check(!unknown.hasIdentity, "Missing cell identifiers are represented explicitly")
        check(unknown.latitude == "0.000000" && unknown.longitude == "0.000000", "Coordinates have six stable decimal places")
        // Compile the public view API with its default and supplied measurement.
        // This does not launch an app, show a window or access a persisted store.
        _ = TMobileTowerMapInspector(pin: unknownPin)
        _ = TMobileTowerMapInspector(pin: unknownPin, measurementCoordinate: .init(latitude: 0, longitude: 0))

        for spelling in ["OpenCellID", "OpenCelliD", "opencellid", "OPENCELLID"] {
            let value = TMobileTowerMapPresentation(pin: pin(provenance: "\(spelling) CC BY-SA 4.0 · community cell estimate"))
            check(value.isCommunityCellEstimate, "OpenCellID attribution is detected without case sensitivity")
            check(value.status == "Community cell estimate", "OpenCellID records are cells, not confirmed tower sites")
            check(value.positionDescription == "Estimated cell position", "Estimated cell coordinates are described honestly")
            check(value.source.contains(spelling), "The complete original provenance remains available")
        }
        let namedOnly = TMobileTowerMapPresentation(pin: pin(name: "OpenCellID candidate"))
        check(!namedOnly.isCommunityCellEstimate, "A name alone is not treated as source attribution")
        check(TMobileTowerMapPresentation.openCellIDSource.absoluteString == "https://opencellid.org", "Attribution links to the source")
        check(TMobileTowerMapPresentation.openCellIDLicense.absoluteString == "https://creativecommons.org/licenses/by-sa/4.0/", "Attribution includes the exact license")

        let rawBands = "N41 + n71, B66 / b2; n41"
        let described = TMobileTowerMapPresentation(pin: pin(bands: rawBands))
        check(described.bands == rawBands, "The declared band string is displayed without rewriting its claims")
        check(described.bandDescriptions.map(\.code) == ["n41", "n71", "b66", "b2"], "Explicit known band codes are normalized and deduplicated in source order")
        for band in described.bandDescriptions {
            check(band.guide.frequency == TMobileBandGuide.entry(for: band.code)?.frequency, "Band frequencies come from the existing catalog")
            check(band.guide.category == TMobileBandGuide.entry(for: band.code)?.category, "Band explanations come from the existing catalog")
        }
        check(described.technology == "Not provided", "An NR band code cannot fill a missing reported technology")
        check(described.speedAndCapacity == "Not provided", "Known bands cannot become numeric speed or capacity claims")
        let unsupported = TMobileTowerMapPresentation(pin: pin(bands: "xn41 n41tail 41 n999 b999 én41 n41é"))
        check(unsupported.bandDescriptions.isEmpty, "Unknown and embedded codes do not acquire an unrelated explanation")
        check(!unsupported.bands.isEmpty, "Unsupported band text remains visible as declared")
        let modeled = TMobileTowerMapPresentation(pin: pin(name: "FCC 35/3", bands: "n41 · 35/3 Mbps", provenance: "FCC modeled coverage"))
        check(modeled.speedAndCapacity == "Not provided", "FCC modeled tiers in free text never become a tower maximum speed")
        check(modeled.status == "Location unverified", "A source string does not verify a physical site")

        for radio in TMobileTowerRadio.allCases {
            let value = TMobileTowerMapPresentation(pin: pin(radio: radio, node: 123, cell: "456", ecgi: "310-260-000123"))
            check(value.technology == radio.label, "Only the explicit radio field supplies technology")
            check(value.nodeLabel == radio.nodeLabel, "Node labels use the declared radio without identity bit slicing")
            check(value.nodeID == "123" && value.cellID == "456", "Numeric identity is displayed without inferring other identifiers")
            check(value.ecgi == "310-260-000123", "Reported identity text remains opaque")
            check(value.hasIdentity, "Available identity opens a useful secondary detail section")
        }
        let opaque = TMobileTowerMapPresentation(pin: pin(node: 123, cell: " 456 ", ecgi: "0x123A"))
        check(opaque.nodeLabel == "Node ID", "An unknown radio does not assign an LTE or NR node type")
        check(opaque.cellID == "456" && opaque.ecgi == "0x123A", "Only surrounding whitespace is removed from identity text")
        let empty = TMobileTowerMapPresentation(pin: pin(name: "  ", bands: "  ", cell: "  ", provenance: "  "))
        check(empty.title == "Unnamed reference" && empty.source == "Source not provided", "Whitespace-only fields have short unavailable labels")
        check(empty.bands == "Not provided" && !empty.hasIdentity, "Whitespace does not become a false band or identity")

        let decimal = TMobileTowerMapPresentation(pin: pin(latitude: -12.3456786, longitude: 123.4567894))
        check(decimal.latitude == "-12.345679" && decimal.longitude == "123.456789", "Coordinates round correctly with an invariant decimal separator")
        let zero = TMobileTowerMapPresentation(pin: pin(latitude: -0.0000001, longitude: -0.0))
        check(zero.latitude == "0.000000" && zero.longitude == "0.000000", "Rounded zero does not display a negative sign")
        let edge = TMobileTowerMapPresentation(pin: pin(latitude: 90, longitude: -180))
        check(edge.latitude == "90.000000" && edge.longitude == "-180.000000", "Valid WGS84 boundary coordinates remain selectable numeric text")
        for coordinate in [TMobileMapCoordinate(latitude: .nan, longitude: 0), .init(latitude: 91, longitude: 0), .init(latitude: 0, longitude: .infinity)] {
            let invalid = TMobileTowerMapPresentation(pin: pin(latitude: coordinate.latitude, longitude: coordinate.longitude), measurementCoordinate: .init(latitude: 0, longitude: 0))
            check(invalid.latitude == "Unavailable" && invalid.longitude == "Unavailable", "Invalid coordinates cannot leak NaN or infinite numeric labels")
            check(invalid.relativePosition == nil, "Invalid pin coordinates produce no geometry claim")
        }

        let origin = TMobileMapCoordinate(latitude: 0, longitude: 0)
        let east = TMobileTowerMapPresentation(pin: pin(longitude: 0.001), measurementCoordinate: origin)
        check(east.relativePosition == .init(distance: "111 m", bearing: "90° E"), "A known eastward separation has correct meter and bearing labels")
        let north = TMobileTowerMapPresentation(pin: pin(latitude: 1), measurementCoordinate: origin)
        check(north.relativePosition == .init(distance: "111.2 km", bearing: "0° N"), "Longer separation switches to kilometers without inventing travel distance")
        let west = TMobileTowerMapPresentation(pin: pin(longitude: -0.001), measurementCoordinate: origin)
        check(west.relativePosition?.bearing == "270° W", "Westward bearings remain normalized")
        let coincident = TMobileTowerMapPresentation(pin: pin(), measurementCoordinate: origin)
        check(coincident.relativePosition == .init(distance: "0 m", bearing: nil), "A coincident point has no arbitrary bearing")
        let dateLine = TMobileTowerMapPresentation(pin: pin(longitude: -179.999), measurementCoordinate: .init(latitude: 0, longitude: 179.999))
        check(dateLine.relativePosition == .init(distance: "222 m", bearing: "90° E"), "Distance across the date line uses the short separation")
        let invalidMeasurement = TMobileTowerMapPresentation(pin: pin(), measurementCoordinate: .init(latitude: 100, longitude: 0))
        check(invalidMeasurement.relativePosition == nil, "An invalid supplied measurement does not produce direction or distance")

        print("PASS \(checks) tower inspector presentation checks; real SwiftUI inspector compiled")
    }

    private static func pin(name: String = "Reference", latitude: Double = 0, longitude: Double = 0,
                            bands: String = "", radio: TMobileTowerRadio? = nil, node: UInt32? = nil,
                            cell: String? = nil, ecgi: String? = nil, provenance: String? = nil) -> TMobileTowerPin {
        .init(name: name, latitude: latitude, longitude: longitude, bands: bands, cellID: cell,
              radio: radio, nodeID: node, ecgi: ecgi, provenance: provenance)
    }
}
