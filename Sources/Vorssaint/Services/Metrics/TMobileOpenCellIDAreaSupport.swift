// SPDX-License-Identifier: GPL-3.0-or-later
import CoreFoundation
import Foundation

/// A small, explicit search around the map center. Never derived from device
/// identity, IP geolocation or an inferred serving tower.
struct TMobileOpenCellIDArea: Equatable, CustomStringConvertible, CustomDebugStringConvertible {
    let south: Double
    let west: Double
    let north: Double
    let east: Double

    init?(latitude: Double, longitude: Double) {
        guard latitude.isFinite, longitude.isFinite, abs(latitude) <= 85,
              (-180...180).contains(longitude) else { return nil }
        // 1.8 km square, below the provider's 4 km² bounding-box limit.
        let halfLatitude = 900 / 6_371_000.0 * 180 / .pi
        let halfLongitude = halfLatitude / cos(latitude * .pi / 180)
        south = latitude - halfLatitude; north = latitude + halfLatitude
        west = longitude - halfLongitude; east = longitude + halfLongitude
        guard west >= -180, east <= 180 else { return nil }
    }

    var description: String { "<OpenCellID map search area>" }
    var debugDescription: String { description }
    var queryValue: String { [south, west, north, east].map { String($0) }.joined(separator: ",") }

    func contains(latitude: Double, longitude: Double, mcc: String) -> Bool {
        // getInArea rounds coordinates to 3 decimals (2 for MCC 404–406).
        let tolerance = ["404", "405", "406"].contains(mcc) ? 0.0051 : 0.00051
        return latitude.isFinite && longitude.isFinite
            && (south - tolerance...north + tolerance).contains(latitude)
            && (west - tolerance...east + tolerance).contains(longitude)
    }
}

enum TMobileOpenCellIDAreaSupport {
    static let maximumCells = 50
    static let documentation = URL(string: "https://wiki.opencellid.org/docs/api/cells-in-area")!

    static func requestURL(area: TMobileOpenCellIDArea, radio: TMobileOpenCellIDRadio, token: String) throws -> URL {
        guard TMobileOpenCellIDSupport.validToken(token) else { throw TMobileOpenCellIDFailure.invalidInput }
        var components = URLComponents(string: "https://opencellid.org/cell/getInArea")!
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        let fields = [("key", token), ("BBOX", area.queryValue), ("radio", radio.rawValue),
                      ("format", "json"), ("limit", String(maximumCells)), ("offset", "0")]
        components.percentEncodedQuery = fields.map { name, value in
            name + "=" + value.addingPercentEncoding(withAllowedCharacters: allowed)!
        }.joined(separator: "&")
        guard let url = components.url else { throw TMobileOpenCellIDFailure.invalidInput }
        return url
    }

    static func parse(_ data: Data, area: TMobileOpenCellIDArea,
                      radio: TMobileOpenCellIDRadio) throws -> [TMobileOpenCellIDResult] {
        guard !data.isEmpty, data.count <= TMobileOpenCellIDSupport.maximumResponseBytes,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw TMobileOpenCellIDFailure.invalidResponse
        }
        guard TMobileOpenCellIDSupport.validResponseJSON(root, maximumValues: 4096) else {
            throw TMobileOpenCellIDFailure.invalidResponse
        }
        if let failure = TMobileOpenCellIDSupport.providerFailure(root) { throw failure }
        guard let count = integer(root["count"]), let cells = root["cells"] as? [[String: Any]],
              cells.count <= maximumCells, count >= UInt64(cells.count) else {
            throw TMobileOpenCellIDFailure.invalidResponse
        }
        var seen = Set<String>()
        return try cells.compactMap { cell in
            guard let mcc = integer(cell["mcc"]), (1...999).contains(mcc),
                  let mnc = integer(cell["mnc"]), mnc <= 999,
                  let tac = integer(cell["lac"]), let fullID = integer(cell["cellid"]),
                  let identity = TMobileOpenCellIDIdentity(radio: radio, mcc: String(format: "%03d", Int(mcc)),
                    mnc: String(mnc), tac: String(tac), cellID: String(fullID)) else {
                throw TMobileOpenCellIDFailure.invalidResponse
            }
            let encoded = try JSONSerialization.data(withJSONObject: cell)
            let result = try TMobileOpenCellIDSupport.parse(encoded, requested: identity)
            guard area.contains(latitude: result.latitude, longitude: result.longitude, mcc: identity.mcc) else {
                throw TMobileOpenCellIDFailure.invalidResponse
            }
            let key = "\(radio.rawValue)|\(identity.mcc)|\(identity.mnc)|\(identity.tac)|\(identity.cellID)"
            return seen.insert(key).inserted ? result : nil
        }
    }

    private static func integer(_ raw: Any?) -> UInt64? {
        guard let number = raw as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        return TMobileOpenCellIDSupport.unsigned(number.stringValue)
    }
}
