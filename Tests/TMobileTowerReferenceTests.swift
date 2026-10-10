// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint
import Foundation

enum TMobileTowerReferenceTests {
    static func run(_ suite: TestSuite) {
        coding(suite)
        imports(suite)
        canonicalIdentity(suite)
        matching(suite)
        geometry(suite)
    }

    private static func coding(_ suite: TestSuite) {
        let legacy = #"{"id":"22222222-2222-2222-2222-222222222222","name":"Legacy reference","latitude":40,"longitude":-100,"bands":"n41","cellID":"12345"}"#
        let decoded = try? JSONDecoder().decode(TMobileTowerPin.self, from: Data(legacy.utf8))
        suite.expect(decoded?.id.uuidString == "22222222-2222-2222-2222-222222222222"
                     && decoded?.cellID == "12345" && decoded?.isValid == true,
                     "old tower archives preserve the pin identity and display reference")
        suite.expect(decoded?.radio == nil && decoded?.nodeID == nil && decoded?.ecgi == nil
                     && decoded?.provenance == nil,
                     "absent metadata in an old archive stays unspecified")
        if let decoded, let data = try? JSONEncoder().encode(decoded) {
            suite.expect((try? JSONDecoder().decode(TMobileTowerPin.self, from: data)) == decoded,
                         "legacy tower pins round-trip without inventing identity metadata")
        } else { suite.expect(false, "a legacy tower archive decodes and encodes") }

        let pin = TMobileTowerPin(name: "Synthetic reference", latitude: 0, longitude: 1,
                                  bands: "b2", cellID: "display only", radio: .lte,
                                  nodeID: 12_345, ecgi: "00123456789", provenance: "Manual pin")
        if let data = try? JSONEncoder().encode(pin) {
            suite.expect((try? JSONDecoder().decode(TMobileTowerPin.self, from: data)) == pin,
                         "new tower metadata and local UUID survive archive round-trip")
        } else { suite.expect(false, "a tower pin with metadata encodes") }

        let lteMaximum = TMobileTowerPin(name: "LTE maximum", latitude: 0, longitude: 1,
                                        bands: "b2", cellID: nil, radio: .lte, nodeID: 0x0FFF_FFFF)
        let lteOverflow = TMobileTowerPin(name: "LTE overflow", latitude: 0, longitude: 1,
                                         bands: "b2", cellID: nil, radio: .lte, nodeID: 0x1000_0000)
        let nrMaximum = TMobileTowerPin(name: "NR maximum", latitude: 0, longitude: 1,
                                       bands: "n41", cellID: nil, radio: .nr, nodeID: UInt32.max)
        let unspecifiedRadio = TMobileTowerPin(name: "Unspecified radio", latitude: 0, longitude: 1,
                                              bands: "", cellID: nil, nodeID: UInt32.max,
                                              ecgi: "0x310260ABCDEF")
        suite.expect(lteMaximum.isValid && !lteOverflow.isValid,
                     "LTE reference nodes enforce the inclusive 28-bit limit")
        suite.expect(nrMaximum.isValid,
                     "NR reference nodes retain the complete UInt32 range")
        suite.expect(unspecifiedRadio.isValid,
                     "metadata without a radio can be stored without inventing a radio identity")
    }

    private static func imports(_ suite: TestSuite) {
        let legacyJSON = #"[{"name":"Legacy import","latitude":40,"longitude":-100,"cellID":"12345"}]"#
        let legacy = imported(legacyJSON, json: true)?.first
        suite.expect(legacy?.bands == "" && legacy?.cellID == "12345" && legacy?.radio == nil
                     && legacy?.nodeID == nil && legacy?.ecgi == nil,
                     "old JSON imports retain their optional display fields")
        suite.expect(legacy?.provenance == "Imported local file",
                     "an import without provenance records its local-file origin")

        let metadataJSON = #"[{"id":"22222222-2222-2222-2222-222222222222","name":"Imported reference","latitude":40,"longitude":-100,"bands":"n41","cellID":"sector label","radio":"NR","nodeID":4294967295,"ecgi":"000123456789","provenance":"Synthetic local fixture"}]"#
        let metadata = imported(metadataJSON, json: true)?.first
        suite.expect(metadata?.radio == .nr && metadata?.nodeID == UInt32.max
                     && metadata?.ecgi == "000123456789"
                     && metadata?.provenance == "Synthetic local fixture",
                     "JSON imports preserve explicit radio, unsigned node and opaque ECGI metadata")
        suite.expect(metadata?.id.uuidString != "22222222-2222-2222-2222-222222222222"
                     && metadata != nil,
                     "a supplied import UUID cannot overwrite an existing local pin")
        let zeroNodeJSON = #"[{"name":"Zero node","latitude":0,"longitude":0,"radio":"LTE","nodeID":0}]"#
        suite.expect(imported(zeroNodeJSON, json: true)?.first?.nodeID == 0,
                     "zero node values remain exact unsigned values without inventing an ECGI")
        let lteMaximumJSON = #"[{"name":"LTE maximum","latitude":0,"longitude":1,"radio":"LTE","nodeID":268435455}]"#
        let lteOverflowJSON = #"[{"name":"LTE overflow","latitude":0,"longitude":1,"radio":"LTE","nodeID":268435456}]"#
        suite.expect(imported(lteMaximumJSON, json: true)?.first?.nodeID == 0x0FFF_FFFF
                     && imported(lteOverflowJSON, json: true) == nil,
                     "JSON imports enforce the LTE node boundary rather than the NR boundary")
        for identity in ["0x310260ABCDEF", "001-01-12345", "18446744073709551616"] {
            let json = "[{\"name\":\"Opaque identity\",\"latitude\":0,\"longitude\":1,\"ecgi\":\"\(identity)\"}]"
            suite.expect(imported(json, json: true)?.first?.ecgi == identity,
                         "JSON imports retain valid opaque ECGI text exactly: \(identity)")
        }

        let oldCSV = "name,latitude,longitude,bands,cellID\r\n\"Legacy, CSV\",40,-100,n41,12345\r\n"
        let oldPin = imported(oldCSV, json: false)?.first
        suite.expect(oldPin?.name == "Legacy, CSV" && oldPin?.cellID == "12345"
                     && oldPin?.provenance == "Imported local file",
                     "the existing five-column CSV format stays compatible with quoted fields and CRLF")
        let appendedCSV = "name,latitude,longitude,bands,cellID,radio,nodeID,ecgi,provenance\nReference,0,1,b2,label,LTE,12345,000123456789,\"Owner, offline fixture\"\n"
        let appended = imported(appendedCSV, json: false)?.first
        suite.expect(appended?.radio == .lte && appended?.nodeID == 12_345
                     && appended?.ecgi == "000123456789"
                     && appended?.provenance == "Owner, offline fixture",
                     "optional CSV metadata can be appended and retain quoted provenance")
        let reorderedCSV = "ecgi,longitude,name,cellID,provenance,nodeID,bands,latitude,radio\n123456789,1,Reference,label,Manual fixture,12345,b2,0,LTE\n"
        let reordered = imported(reorderedCSV, json: false)?.first
        suite.expect(reordered?.name == "Reference" && reordered?.latitude == 0
                     && reordered?.longitude == 1 && reordered?.radio == .lte
                     && reordered?.nodeID == 12_345 && reordered?.ecgi == "123456789",
                     "CSV columns are resolved by header names rather than positions")
        let reorderedOldCSV = "cellID,bands,longitude,name,latitude\nlabel,n41,1,Reference,0\n"
        suite.expect(imported(reorderedOldCSV, json: false)?.first?.cellID == "label",
                     "the five required CSV columns can also be reordered without metadata")
        let subsetCSV = "name,latitude,longitude,bands,cellID,radio\nReference,0,1,n41,,NR\n"
        suite.expect(imported(subsetCSV, json: false)?.first?.radio == .nr
                     && imported(subsetCSV, json: false)?.first?.nodeID == nil,
                     "optional CSV columns do not require the other metadata columns")
        let blankCSV = "name,latitude,longitude,bands,cellID,radio,nodeID,ecgi,provenance\nReference,0,1,,,,,,\n"
        let blank = imported(blankCSV, json: false)?.first
        suite.expect(blank?.radio == nil && blank?.nodeID == nil && blank?.ecgi == nil
                     && blank?.provenance == "Imported local file",
                     "empty optional CSV fields become unavailable with default import provenance")
        let nodeHeader = "name,latitude,longitude,bands,cellID,radio,nodeID\n"
        suite.expect(imported(nodeHeader + "LTE maximum,0,1,b2,,LTE,268435455\n", json: false)?.first?.nodeID == 0x0FFF_FFFF
                     && imported(nodeHeader + "LTE overflow,0,1,b2,,LTE,268435456\n", json: false) == nil,
                     "CSV imports enforce the inclusive LTE node limit")
        suite.expect(imported(nodeHeader + "NR maximum,0,1,n41,,NR,4294967295\n", json: false)?.first?.nodeID == UInt32.max,
                     "CSV imports accept the full unsigned NR node range")
        for identity in ["0x310260ABCDEF", "001-01-12345", "18446744073709551616"] {
            let csv = "name,latitude,longitude,bands,cellID,ecgi\nOpaque identity,0,1,,,\(identity)\n"
            suite.expect(imported(csv, json: false)?.first?.ecgi == identity,
                         "CSV imports retain valid opaque ECGI text exactly: \(identity)")
        }

        for metadata in [#""radio":"5G""#, #""radio":"lte""#, #""radio":5""#,
                         #""nodeID":-1"#, #""nodeID":4294967296"#, #""nodeID":1.5"#,
                         #""nodeID":true"#, #""nodeID":"12345""#,
                         #""ecgi":12345"#, #""ecgi":"""#, #""ecgi":"-1""#, #""ecgi":"1.5""#,
                         #""ecgi":"0000""#, #""ecgi":"0x000""#, #""ecgi":"１２３""#,
                         #""provenance":"Line\nbreak""#, #""provenance":"Tab\tlabel""#] {
            let text = "[{\"name\":\"Invalid metadata\",\"latitude\":0,\"longitude\":1,\(metadata)}]"
            suite.expect(imported(text, json: true) == nil,
                         "invalid JSON identity types, ranges, radio names and controls reject the import: \(metadata)")
        }
        let mixedJSON = #"[{"name":"Valid","latitude":0,"longitude":1,"radio":"LTE"},{"name":"Invalid","latitude":0,"longitude":1,"ecgi":"1g3"}]"#
        suite.expect(imported(mixedJSON, json: true) == nil,
                     "a malformed metadata record rejects the whole JSON import")

        for header in ["name,latitude,longitude,bands,cellID,radio,radio",
                       "name,latitude,longitude,bands,cellID,nodeID,nodeID",
                       "name,latitude,longitude,bands,cellID,unexpected",
                       "name,latitude,longitude,bands,radio",
                       "name,latitude,longitude,bands,cellID,Radio"] {
            let row = header.split(separator: ",").map { column in
                switch column {
                case "name": return "Reference"
                case "latitude": return "0"
                case "longitude": return "1"
                case "bands": return "b2"
                case "cellID": return "display"
                case "radio", "Radio": return "LTE"
                case "nodeID": return "12345"
                default: return "extra"
                }
            }.joined(separator: ",")
            suite.expect(imported(header + "\n" + row + "\n", json: false) == nil,
                         "duplicate, unknown or missing required CSV headers reject: \(header)")
        }
        for fields in ["5G,12345,123456789,Fixture", "lte,12345,123456789,Fixture",
                       "LTE,-1,123456789,Fixture", "LTE,4294967296,123456789,Fixture",
                       "LTE,1.5,123456789,Fixture", "LTE,true,123456789,Fixture",
                       "LTE,12345,1g3,Fixture", "LTE,12345,+123,Fixture",
                       "LTE,12345,0000,Fixture", "LTE,12345,0x000,Fixture",
                       "LTE,12345,１２３,Fixture", "LTE,12345,123,Tab\tlabel",
                       "LTE,12345,123,\"Line\nbreak\""] {
            let text = "name,latitude,longitude,bands,cellID,radio,nodeID,ecgi,provenance\nInvalid,0,1,b2,label,\(fields)\n"
            suite.expect(imported(text, json: false) == nil,
                         "invalid CSV identity fields and provenance controls reject: \(fields)")
        }
        let wrongWidth = "name,latitude,longitude,bands,cellID,radio\nReference,0,1,b2,label\n"
        suite.expect(imported(wrongWidth, json: false) == nil,
                     "a CSV row cannot omit its declared optional column")
    }

    private static func canonicalIdentity(_ suite: TestSuite) {
        for raw in ["12345", "00012345", "0x310260ABCDEF", "0X310260abcdef",
                    "001-01-12345", "310:260:abc123", "00A0", "1e3",
                    "18446744073709551616", String(repeating: "1", count: 64)] {
            suite.expect(TMobileTowerReferenceSupport.canonicalECGI(raw) == raw,
                         "valid opaque ECGI text preserves every digit, separator and letter case: \(raw)")
        }
        for raw in ["", " ", " 123", "123 ", "+123", "-123", "123-", ":123", "123:",
                    "1--23", "1::23", "1-:23", "1.0", "1g3", "0x", "0X", "0x-123",
                    "ABCDEF", "0xABC", "12_3", "１２３", "١٢٣", "123\n", "123\0",
                    "0", "0000", "0x000", "0X0:0-0", String(repeating: "1", count: 65)] {
            suite.expect(TMobileTowerReferenceSupport.canonicalECGI(raw) == nil,
                         "ECGI rejects malformed, non-ASCII, all-zero and overlength text: \(raw.debugDescription)")
        }
    }

    private static func matching(_ suite: TestSuite) {
        let complete = TMobileTowerPin(name: "Reference", latitude: 0, longitude: 1,
                                       bands: "n41", cellID: "display only", radio: .nr,
                                       nodeID: 12_345, ecgi: "000123456789", provenance: "Manual pin")
        suite.expect(TMobileTowerReferenceSupport.match(complete, radio: .nr, nodeID: 12_345,
                                                        ecgi: "000123456789") == .ecgiAndNode,
                     "same-radio explicit node and byte-for-byte ECGI establish both identity matches")
        suite.expect(TMobileTowerReferenceSupport.match(complete, radio: .nr, nodeID: nil,
                                                        ecgi: "000123456789") == .ecgi,
                     "an absent current node leaves an exact ECGI match")
        suite.expect(TMobileTowerReferenceSupport.match(complete, radio: .nr, nodeID: 12_345,
                                                        ecgi: nil) == .node,
                     "an absent current ECGI leaves an explicit node match")
        suite.expect(TMobileTowerReferenceSupport.match(complete, radio: .lte, nodeID: 12_345,
                                                        ecgi: "000123456789") == nil,
                     "equal numbers across LTE and NR cannot establish a reference match")
        suite.expect(TMobileTowerReferenceSupport.match(complete, radio: .nr, nodeID: 999,
                                                        ecgi: "000123456789") == nil,
                     "a conflicting supplied node prevents an otherwise exact ECGI match")
        suite.expect(TMobileTowerReferenceSupport.match(complete, radio: .nr, nodeID: 12_345,
                                                        ecgi: "999") == nil,
                     "a conflicting supplied ECGI prevents an otherwise exact node match")
        suite.expect(TMobileTowerReferenceSupport.match(complete, radio: .nr, nodeID: 12_345,
                                                        ecgi: "123456789") == nil,
                     "leading zeros remain identity text and a differing ECGI prevents a node match")
        suite.expect(TMobileTowerReferenceSupport.match(complete, radio: .nr, nodeID: nil,
                                                        ecgi: nil) == nil,
                     "no current identity cannot establish a match")
        for malformed in ["", "1g3", "123\n", "0000", String(repeating: "1", count: 65)] {
            suite.expect(TMobileTowerReferenceSupport.match(complete, radio: .nr, nodeID: 12_345,
                                                            ecgi: malformed) == nil,
                         "a malformed supplied ECGI fails closed even with a matching node")
        }
        let unspecifiedRadio = TMobileTowerPin(name: "Unspecified radio", latitude: 0, longitude: 1,
                                               bands: "n41", cellID: "123456789",
                                               nodeID: 12_345, ecgi: "123456789")
        suite.expect(TMobileTowerReferenceSupport.match(unspecifiedRadio, radio: .nr, nodeID: 12_345,
                                                        ecgi: "123456789") == nil,
                     "identity metadata without an explicit pin radio cannot match")
        let legacy = TMobileTowerPin(name: "Legacy", latitude: 0, longitude: 1,
                                     bands: "n41", cellID: "123456789")
        suite.expect(TMobileTowerReferenceSupport.match(legacy, radio: .nr, nodeID: 12_345,
                                                        ecgi: "123456789") == nil,
                     "matching bands and legacy display cellID never become identity evidence")
        let nodeOnly = TMobileTowerPin(name: "Node", latitude: 0, longitude: 1, bands: "b2",
                                       cellID: nil, radio: .lte, nodeID: 12_345)
        suite.expect(TMobileTowerReferenceSupport.match(nodeOnly, radio: .lte, nodeID: 12_345,
                                                        ecgi: "0x310260ABCDEF") == .node,
                     "a node-only pin can match when a valid unrelated-format ECGI has no saved counterpart")
        let ecgiOnly = TMobileTowerPin(name: "ECGI", latitude: 0, longitude: 1, bands: "n41",
                                       cellID: nil, radio: .nr, ecgi: "123456789")
        suite.expect(TMobileTowerReferenceSupport.match(ecgiOnly, radio: .nr, nodeID: 999,
                                                        ecgi: "123456789") == .ecgi,
                     "an ECGI-only pin matches exactly without deriving or constraining a node")
        suite.expect(TMobileTowerReferenceSupport.match(ecgiOnly, radio: .nr, nodeID: 999,
                                                        ecgi: "000123456789") == nil,
                     "an ECGI-only pin does not normalize leading zeros into a match")
        for identity in ["0x310260ABCDEF", "001-01-12345"] {
            let opaquePin = TMobileTowerPin(name: "Opaque reference", latitude: 0, longitude: 1,
                                           bands: "", cellID: nil, radio: .nr, ecgi: identity)
            suite.expect(TMobileTowerReferenceSupport.match(opaquePin, radio: .nr, nodeID: nil,
                                                            ecgi: identity) == .ecgi,
                         "formatted opaque ECGI matches only its exact saved text: \(identity)")
        }
        let prefixedPin = TMobileTowerPin(name: "Prefixed reference", latitude: 0, longitude: 1,
                                         bands: "", cellID: nil, radio: .nr, nodeID: 12_345, ecgi: "0x123")
        suite.expect(TMobileTowerReferenceSupport.match(prefixedPin, radio: .nr, nodeID: 12_345,
                                                        ecgi: "123") == nil,
                     "a hex prefix cannot be removed to rescue an otherwise matching node")
        let caseSensitivePin = TMobileTowerPin(name: "Case reference", latitude: 0, longitude: 1,
                                              bands: "", cellID: nil, radio: .nr, ecgi: "0x310260ABCDEF")
        suite.expect(TMobileTowerReferenceSupport.match(caseSensitivePin, radio: .nr, nodeID: nil,
                                                        ecgi: "0x310260abcdef") == nil,
                     "hex letter case remains part of opaque ECGI identity")
        let malformedPin = TMobileTowerPin(name: "Invalid", latitude: 0, longitude: 1, bands: "n41",
                                           cellID: nil, radio: .nr, nodeID: 12_345, ecgi: "1g3")
        suite.expect(TMobileTowerReferenceSupport.match(malformedPin, radio: .nr, nodeID: 12_345,
                                                        ecgi: "123456789") == nil,
                     "malformed reference identity cannot be rescued by an equal node")
    }

    private static func geometry(_ suite: TestSuite) {
        let origin = TMobileMapCoordinate(latitude: 0, longitude: 0)
        if let same = TMobileTowerReferenceSupport.geometry(from: origin, to: origin) {
            suite.expectClose(same.distanceMeters, 0, "identical coordinates have zero distance", tol: 0)
            suite.expect(same.bearingDegrees == nil,
                         "identical coordinates do not invent a directional bearing")
        } else { suite.expect(false, "valid identical coordinates have a geometry result") }

        let cardinalPoints: [(TMobileMapCoordinate, Double)] = [
            (.init(latitude: 0, longitude: 1), 90),
            (.init(latitude: 1, longitude: 0), 0),
            (.init(latitude: 0, longitude: -1), 270),
            (.init(latitude: -1, longitude: 0), 180)
        ]
        for (destination, bearing) in cardinalPoints {
            if let value = TMobileTowerReferenceSupport.geometry(from: origin, to: destination) {
                suite.expectClose(value.distanceMeters, 111_195, "one degree near the equator is about 111 km", tol: 250)
                suite.expect(value.bearingDegrees != nil, "distinct cardinal points have a bearing")
                if let actual = value.bearingDegrees {
                    suite.expectClose(actual, bearing, "cardinal bearing uses north-zero clockwise degrees", tol: 0.001)
                }
            } else { suite.expect(false, "valid cardinal destination has a geometry result") }
        }
        if let crossing = TMobileTowerReferenceSupport.geometry(
            from: .init(latitude: 0, longitude: 179.9), to: .init(latitude: 0, longitude: -179.9)) {
            suite.expectClose(crossing.distanceMeters, 22_239, "antimeridian route uses the short separation", tol: 50)
            suite.expect(crossing.bearingDegrees != nil, "antimeridian crossing has a bearing")
            if let bearing = crossing.bearingDegrees {
                suite.expectClose(bearing, 90, "antimeridian crossing from 179.9 east proceeds east", tol: 0.001)
            }
        } else { suite.expect(false, "valid antimeridian coordinates have a geometry result") }

        for invalid in [TMobileMapCoordinate(latitude: .nan, longitude: 0),
                        .init(latitude: 0, longitude: .infinity),
                        .init(latitude: -.infinity, longitude: 0),
                        .init(latitude: 90.001, longitude: 0),
                        .init(latitude: -90.001, longitude: 0),
                        .init(latitude: 0, longitude: 180.001),
                        .init(latitude: 0, longitude: -180.001)] {
            suite.expect(TMobileTowerReferenceSupport.geometry(from: invalid, to: origin) == nil
                         && TMobileTowerReferenceSupport.geometry(from: origin, to: invalid) == nil,
                         "nonfinite or out-of-range coordinates cannot produce distance or bearing")
        }
    }

    private static func imported(_ text: String, json: Bool) -> [TMobileTowerPin]? {
        try? TMobileGatewayHistorySupport.importTowers(Data(text.utf8), json: json)
    }
}
