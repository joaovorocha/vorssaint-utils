// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Foundation

enum TMobileCellTelemetryTests {
    static let fixture = #"{"cell":{"4g":{"PCI":0,"TAC":"7","ARFCN":"1234","ecgi":"310-260-12345","bandwidth":"20 MHz","cqi":0,"rsrp":-98,"rsrq":-10,"rssi":-65,"sinr":8,"bars":3,"sector":{"cid":"12345","bands":["B66","b2"],"eNBID":48},"supportedBands":["b2","B66","b66","n41","b999"]},"5g":{"pci":1007,"tac":16777215,"nrarfcn":520000,"ECGI":"0x310260ABCDEF","bandwidth":100,"cqi":30,"rsrp":-101,"sinr":12,"bars":2,"sector":{"gnbId":"4294967295","cellId":"68719476735","bands":["N41"]},"supportedBands":["n41","n71","n41","b66"]},"gps":{"latitude":42.123456,"longitude":-122.123456}},"sim":{"imsi":"excluded-private-marker"},"clients":[{"mac":"excluded-private-marker"}],"password":"excluded-private-marker"}"#

    static func run(_ suite: TestSuite) {
        let parsed = try? TMobileCellTelemetrySupport.parse(Data(fixture.utf8))
        suite.expect(parsed?.lte?.signal.bands == ["b66", "b2"] && parsed?.fiveG?.signal.bands == ["n41"],
                     "serving telemetry normalizes flat or sector bands without mixing the radios")
        suite.expect(parsed?.lte?.supportedBands == ["b2", "b66"]
                     && parsed?.fiveG?.supportedBands == ["n41", "n71"],
                     "modem supported-band inventory is separate, deduplicated and technology validated")
        suite.expect(parsed?.lte?.signal.physicalCellID == 0 && parsed?.lte?.signal.trackingAreaCode == 7
                     && parsed?.lte?.signal.channel == 1234 && parsed?.lte?.signal.cqi == 0,
                     "uppercase aliases decode and valid zero PCI/CQI values are retained")
        suite.expect(parsed?.fiveG?.signal.physicalCellID == 1007 && parsed?.fiveG?.signal.channel == 520000
                     && parsed?.fiveG?.signal.trackingAreaCode == 16777215 && parsed?.fiveG?.signal.cqi == 30,
                     "NR channel and identifier upper limits pass the shared public validator")
        suite.expect(parsed?.lte?.signal.bandwidthMHz == 20 && parsed?.fiveG?.signal.bandwidthMHz == 100
                     && parsed?.lte?.signal.cellID == 12345 && parsed?.fiveG?.signal.cellID == 68719476735,
                     "explicit bandwidth and sector cell IDs retain units and integer precision")
        suite.expect(parsed?.fiveG?.signal.gNodeBID == UInt32.max && parsed?.lte?.signal.gNodeBID == nil,
                     "only explicit NR gNB identifiers are retained without deriving one from cid")
        suite.expect(parsed?.lte?.ecgi == "310-260-12345" && parsed?.fiveG?.ecgi == "0x310260ABCDEF",
                     "only explicitly reported bounded decimal or hex ECGI text is retained")
        suite.expect(parsed?.lte?.signal.rsrp == -98 && parsed?.fiveG?.signal.sinr == 12
                     && parsed?.fiveG?.signal.bars == 2,
                     "serving telemetry retains returned measurements without changing their radio")
        let description = String(reflecting: parsed)
        suite.expect(!description.contains("excluded-private-marker") && !description.contains("latitude")
                     && !description.contains("longitude") && !description.contains("42.123456"),
                     "sanitized reports cannot retain unknown credentials, SIM, clients or GPS data")

        let direct = try? TMobileCellTelemetrySupport.parse(Data(#"{"5g":{"rsrp":-100,"bands":["n71"],"cid":12345}}"#.utf8))
        suite.expect(direct?.fiveG?.signal.cellID == 12345 && direct?.fiveG?.signal.gNodeBID == nil,
                     "the documented direct response shape is accepted without guessing gNB identity")
        let nullBand = try? TMobileCellTelemetrySupport.parse(Data(#"{"cell":{"5g":{"bands":null,"sector":{"bands":["n41"]},"rsrp":-100}}}"#.utf8))
        suite.expect(nullBand?.fiveG?.signal.bands == ["n41"],
                     "a null flat band field does not hide the documented sector band list")
        let inventory = try? TMobileCellTelemetrySupport.parse(Data(#"{"cell":{"5g":{"supportedBands":["n41","n71"]}}}"#.utf8))
        suite.expect(inventory?.fiveG?.signal.bands.isEmpty == true
                     && inventory?.fiveG?.signal.rsrp == nil && inventory?.fiveG?.supportedBands == ["n41", "n71"],
                     "supported band inventory alone never manufactures a serving band or measurement")
        let sentinel = try? TMobileCellTelemetrySupport.parse(Data(#"{"cell":{"5g":{"bands":["n41"],"rsrp":0,"rssi":99,"rsrq":5,"sinr":99,"bars":99,"pci":1008,"tac":16777216,"earfcn":3279166,"cqi":31,"bandwidth":0,"sector":{"cid":"68719476736","gNBID":"4294967296"},"ecgi":"-1"}}}"#.utf8))
        let signal = sentinel?.fiveG?.signal
        suite.expect(signal?.rsrp == nil && signal?.rsrq == nil && signal?.rssi == nil && signal?.sinr == nil
                     && signal?.bars == nil && signal?.bandwidthMHz == nil,
                     "impossible measurement and bandwidth sentinels remain unavailable")
        suite.expect(signal?.physicalCellID == nil && signal?.trackingAreaCode == nil && signal?.channel == nil
                     && signal?.cqi == nil && signal?.cellID == nil && signal?.gNodeBID == nil
                     && sentinel?.fiveG?.ecgi == nil,
                     "out-of-range identifiers and negative ECGI cannot masquerade as serving metadata")
        for bad in ["", "0", "000-000-000", "-1", "123-", ":123", "12::34", "1.5", "private value", "12\n34", String(repeating: "1", count: 65)] {
            let data = try! JSONSerialization.data(withJSONObject: ["cell": ["5g": ["bands": ["n41"], "ecgi": bad]]])
            suite.expect((try? TMobileCellTelemetrySupport.parse(data))?.fiveG?.ecgi == nil,
                         "malformed, redacted or overlong ECGI text is unavailable")
        }
        for invalid in ["{}", "[]", "null", #"{"cell":null,"5g":{"bands":["n41"]}}"#,
                        #"{"cell":{"gps":{"latitude":1}}}"#, #"{"cell":{"5g":{}}}"#] {
            suite.expect((try? TMobileCellTelemetrySupport.parse(Data(invalid.utf8))) == nil,
                         "unsupported, empty and GPS-only responses cannot publish a radio report")
        }
        suite.expect((try? TMobileCellTelemetrySupport.parse(Data(repeating: 32,
            count: TMobileCellTelemetrySupport.maximumResponseBytes + 1))) == nil,
                     "telemetry JSON parsing enforces its byte bound")
        var deep: Any = ["5g": ["bands": ["n41"]]]
        for _ in 0..<14 { deep = ["nested": deep] }
        let deepData = try! JSONSerialization.data(withJSONObject: ["cell": ["5g": ["bands": ["n41"]]], "ignored": deep])
        suite.expect((try? TMobileCellTelemetrySupport.parse(deepData)) == nil,
                     "excessive ignored-field nesting still fails the structural bound")
        let broadData = try! JSONSerialization.data(withJSONObject: ["cell": ["5g": ["bands": ["n41"]]],
                                                                    "ignored": Array(repeating: 0, count: 257)])
        suite.expect((try? TMobileCellTelemetrySupport.parse(broadData)) == nil,
                     "oversized JSON containers fail the structural bound")
        for bad in ["", "contains space", "contains\ncontrol", String(repeating: "a", count: 8193)] {
            let data = try! JSONSerialization.data(withJSONObject: ["auth": ["token": bad]])
            suite.expect((try? TMobileCellTelemetrySupport.token(from: data)) == nil,
                         "invalid bearer values cannot become an Authorization header")
        }
        suite.expect((try? TMobileCellTelemetrySupport.token(from: Data(#"{"token":"fixture.token"}"#.utf8))) == "fixture.token"
                     && (try? TMobileCellTelemetrySupport.token(from: Data(#"{"auth":{"token":"fixture.token"}}"#.utf8))) == "fixture.token",
                     "the source's nested and direct login token shapes decode")
    }
}
