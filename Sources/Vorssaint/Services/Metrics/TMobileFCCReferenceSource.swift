// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Small allowlist of provenance, independent of arbitrary GIS properties.
/// Local files describe their contents; their issuer is not authenticated.
struct TMobileFCCReferenceSource: Codable, Equatable {
    enum Origin: String, Codable { case officialAPI, localFile }
    let origin: Origin
    let availabilityAsOf: String
    let stateFIPS: String?
    let technology: Int
    let minimumDownloadMbps: Double
    let minimumUploadMbps: Double
    let environment: Int
    let fileID: String?

    var isValid: Bool {
        TMobileCoverageReferenceSupport.validDate(availabilityAsOf)
            && (stateFIPS == nil || FCCCoverageState.all.contains { $0.fips == stateFIPS })
            && [400, 500].contains(technology)
            && minimumDownloadMbps.isFinite && minimumUploadMbps.isFinite
            && minimumDownloadMbps > 0 && minimumDownloadMbps <= 1_000
            && minimumUploadMbps > 0 && minimumUploadMbps <= 1_000
            && [0, 1, 2].contains(environment)
            && (fileID == nil || fileID!.range(of: #"^[A-Za-z0-9_-]{1,128}$"#, options: .regularExpression) != nil)
            && (origin == .localFile || (stateFIPS != nil && fileID != nil))
    }

    var title: String {
        let radio = technology == 500 ? "5G NR" : "LTE"
        let speed = "\(minimumDownloadMbps.formatted())/\(minimumUploadMbps.formatted()) Mbps"
        return "T-Mobile \(radio) · \(speed) · as of \(availabilityAsOf)"
    }

    var provenance: String {
        let originText = origin == .officialAPI ? "Downloaded through the FCC public API" : "Local FCC-format file · origin declared by you"
        let environmentText = environment == 1 ? "In-vehicle and outdoor stationary" : (environment == 2 ? "Outdoor stationary · both FCC environment categories" : "Outdoor stationary only category")
        return "\(originText) · \(environmentText) · raw modeled polygons intersecting the map area chosen at import"
    }
}
