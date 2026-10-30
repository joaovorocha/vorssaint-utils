// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Rebuilds a gateway status reading from the Shadow server's retained
/// `van/router/signal/...` and `van/router/cell/...` topics. The values are
/// rewritten into the gateway's own JSON shape so the existing parser applies
/// every allowlist and range check unchanged.
enum ShadowServerRouter {
    static let topicPrefix = "van/router/"
    static let topics = ["van/router/signal/#", "van/router/cell/#"]
    static let updatedKey = "signal/updated"

    /// `values` maps the topic after `van/router/` to its decoded JSON value.
    static func reading(_ values: [String: Any]) -> (snapshot: TMobileGatewaySnapshot, date: Date)? {
        guard values["signal/status"] as? String == "ok",
              let epoch = (values[updatedKey] as? NSNumber)?.doubleValue, epoch.isFinite, epoch > 0 else { return nil }
        var signal: [String: Any] = [:]
        for radio in ["4g", "5g"] {
            var object: [String: Any] = [:]
            func copy(_ from: String, to key: String) { if let value = values[from] { object[key] = value } }
            copy("signal/\(radio)/band", to: "bands")
            copy("signal/\(radio)/bars", to: "bars")
            copy("signal/\(radio)/rsrp_dbm", to: "rsrp")
            copy("signal/\(radio)/rsrq_db", to: "rsrq")
            copy("signal/\(radio)/rssi_dbm", to: "rssi")
            copy("signal/\(radio)/sinr_db", to: "sinr")
            copy("signal/\(radio)/cell_id", to: "cid")
            copy("signal/\(radio)/antenna", to: "antennaUsed")
            copy("cell/\(radio)/arfcn", to: "arfcn")
            copy("cell/\(radio)/pci", to: "pci")
            copy("cell/\(radio)/tac", to: "tac")
            copy("cell/\(radio)/cqi", to: "cqi")
            copy("cell/\(radio)/ecgi", to: "ecgi")
            if radio == "5g" { copy("cell/5g/gnb_id", to: "gNBID") }
            // The server publishes "20M"; the gateway parser reads "20MHz".
            if let bandwidth = values["cell/\(radio)/bandwidth"] as? String {
                object["bandwidth"] = bandwidth.hasSuffix("M") ? bandwidth + "Hz" : bandwidth
            }
            if let bands = values["cell/\(radio)/supported_bands"] as? String {
                object["supportedBands"] = bands.split(separator: ",").map { String($0) }
            }
            if !object.isEmpty { signal[radio] = object }
        }
        var generic: [String: Any] = [:]
        for key in ["registration", "roaming", "apn"] { if let value = values["signal/\(key)"] { generic[key] = value } }
        signal["generic"] = generic
        guard let data = try? JSONSerialization.data(withJSONObject: ["signal": signal]),
              let snapshot = try? TMobileGatewaySupport.parse(data),
              snapshot.lte != nil || snapshot.fiveG != nil,
              TMobileGatewaySupport.isValidSnapshot(snapshot) else { return nil }
        return (snapshot, Date(timeIntervalSince1970: epoch))
    }

    /// Numbers and booleans arrive as JSON; text fields arrive raw (`ok`, `n41`).
    static func value(_ payload: Data) -> Any? {
        if let json = try? JSONSerialization.jsonObject(with: payload, options: .fragmentsAllowed) { return json }
        guard let text = String(data: payload, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty, text.count <= 256 else { return nil }
        return text
    }
}
