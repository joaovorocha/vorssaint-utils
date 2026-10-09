// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Foundation

enum TMobileWiFiTests {
    // Synthetic credentials only; these fixtures never reach a network.
    static let fixture = #"{"bandSteering":{"isEnabled":true},"2.4ghz":{"isRadioEnabled":true,"channel":"Auto","channelBandwidth":"20MHz","mode":"auto","transmissionPower":100,"maxClients":64,"isMUMIMOEnabled":true,"isWMMEnabled":true,"airtimeFairness":false},"5.0ghz":{"isRadioEnabled":true,"channel":"Auto"},"ssids":[{"ssidName":"Fixture network","wpaKey":"fixture-key-123","isBroadcastEnabled":true,"guest":false,"2.4ghzSsid":true,"5.0ghzSsid":true,"encryptionMode":"unverified-mode","encryptionVersion":"unverified-version","futureSSIDField":17},{"ssidName":"Fixture guest","wpaKey":"fixture-key-456","isBroadcastEnabled":false,"guest":true}],"future":{"untouched":[1,2,3]}}"#

    static func run(_ suite: TestSuite) {
        do {
            let original = try TMobileWiFiPayload(data: Data(fixture.utf8))
            let config = original.configuration
            suite.expect(config.ssids.count == 2 && config.radios.count == 2 && config.bandSteeringEnabled == true,
                         "Wi-Fi projection keeps existing SSIDs, reported radios and steering")
            suite.expect(config.ssids[0].editableFields == Set(TMobileWiFiField.allCases)
                         && config.ssids[0].twoPointFourEnabled == true && config.ssids[0].fiveEnabled == true,
                         "only the four verified existing SSID attributes are editable")
            suite.expect(config.radios[0].channel == "Auto" && config.radios[0].maxClients == 64
                         && config.radios[0].transmissionPower == "100" && config.radios[0].airtimeFairness == false,
                         "radio fields remain typed read-only values without invented channels")
            let edit = TMobileWiFiEdit(ssidID: 0, name: "Renamed fixture", password: "changed-fixture-123",
                                      broadcastEnabled: false, guest: true)
            let changed = try original.applying([edit])
            let raw = try JSONSerialization.jsonObject(with: changed.payload.encoded()) as! [String: Any]
            let rows = raw["ssids"] as! [[String: Any]]
            suite.expect(rows[0]["ssidName"] as? String == "Renamed fixture" && rows[0]["guest"] as? Bool == true
                         && rows[0]["isBroadcastEnabled"] as? Bool == false, "a verified patch changes only requested existing SSID fields")
            suite.expect(rows[0]["futureSSIDField"] as? Int == 17 && rows[1]["wpaKey"] as? String == "fixture-key-456"
                         && (raw["future"] as? [String: Any])?["untouched"] as? [Int] == [1,2,3],
                         "full payload preservation retains other SSIDs, their credentials and unknown fields")
            suite.expect((raw["2.4ghz"] as? [String: Any])?["channel"] as? String == "Auto"
                         && rows[0]["encryptionMode"] as? String == "unverified-mode", "radio and unverified security values survive unchanged")
            suite.expect(changed.changes.count == 4 && !changed.changes.joined().contains("changed-fixture")
                         && !String(reflecting: config).contains("fixture-key")
                         && !String(describing: edit).contains("changed-fixture")
                         && !String(describing: original).contains("fixture-key"), "UI projection, summaries and normal debug descriptions contain no credential values")
            suite.expect(changed.changes.first?.contains("“Fixture network” → “Renamed fixture”") == true,
                         "rename review identifies the exact current and proposed SSID without a password")
            let inverse = try original.inverse(of: [edit])
            let restored = try changed.payload.applying(inverse).payload
            suite.expect(restored.sameConfiguration(as: original), "touched-field inverse restores the original full configuration")
            let reordered = try JSONSerialization.data(withJSONObject: JSONSerialization.jsonObject(with: Data(fixture.utf8)), options: [.prettyPrinted])
            suite.expect(try original.sameConfiguration(as: TMobileWiFiPayload(data: reordered)), "complete conflict comparison ignores JSON key ordering and whitespace")
            for invalid in [TMobileWiFiEdit(ssidID: -1, name: "X"), TMobileWiFiEdit(ssidID: 2, name: "X"),
                            TMobileWiFiEdit(ssidID: 0, name: ""), TMobileWiFiEdit(ssidID: 0, name: String(repeating: "é", count: 17)),
                            TMobileWiFiEdit(ssidID: 0, name: "bad\nname"), TMobileWiFiEdit(ssidID: 0, password: "short"),
                            TMobileWiFiEdit(ssidID: 0, password: String(repeating: "x", count: 64)),
                            TMobileWiFiEdit(ssidID: 0, password: "unicode-é-password"), TMobileWiFiEdit(ssidID: 0, password: "********")] {
                suite.expect((try? original.applying([invalid])) == nil, "invalid indices, names and passwords cannot construct a write")
            }
            suite.expect((try? original.applying([edit, edit])) == nil, "duplicate edits for one SSID are rejected")
            let masked = fixture.replacingOccurrences(of: "fixture-key-123", with: "********")
            let maskedPayload = try TMobileWiFiPayload(data: Data(masked.utf8))
            suite.expect((try? maskedPayload.applying([.init(ssidID: 0, name: "Changed")])) == nil,
                         "a full write cannot silently replay a masked Wi-Fi credential")
            suite.expect((try? maskedPayload.applying([.init(ssidID: 0, password: "explicit-new-key")])) != nil,
                         "an explicit valid replacement resolves a returned redaction placeholder")
            let missing = #"{"ssids":[{"ssidName":"Test","wpaKey":"fixture-key-123"}]}"#
            let sparse = try TMobileWiFiPayload(data: Data(missing.utf8))
            suite.expect(sparse.configuration.ssids[0].editableFields == [.name, .password]
                         && (try? sparse.applying([.init(ssidID: 0, guest: true)])) == nil,
                         "absent fields stay unavailable and cannot be invented by a patch")
        } catch { suite.expect(false, "valid synthetic Wi-Fi fixture parses and patches") }
        for invalid in ["{}", "[]", "null", #"{"ssids":[]}"#, #"{"ssids":[null]}"#] {
            suite.expect((try? TMobileWiFiPayload(data: Data(invalid.utf8))) == nil, "malformed or empty AP configurations reject")
        }
        suite.expect((try? TMobileWiFiPayload(data: Data(repeating: 32, count: TMobileWiFiSupport.maximumResponseBytes + 1))) == nil,
                     "Wi-Fi JSON parsing is size bounded")
        for token in ["", "contains space", "line\nbreak"] {
            let data = try! JSONSerialization.data(withJSONObject: ["auth": ["token": token]])
            suite.expect((try? TMobileWiFiSupport.token(from: data)) == nil, "invalid bearer header contents reject")
        }
        suite.expect((try? TMobileWiFiSupport.token(from: Data(#"{"auth":{"token":"fixture.token"}}"#.utf8))) == "fixture.token",
                     "the verified nested login token shape decodes")
    }
}
