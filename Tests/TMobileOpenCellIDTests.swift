// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint
import Foundation

enum TMobileOpenCellIDTests {
    static let identity = TMobileOpenCellIDIdentity(radio: .lte, mcc: "310", mnc: "260", tac: "1234", cellID: "12345678")!
    static let fixture = #"{"lat":40,"lon":-100,"mcc":310,"mnc":260,"lac":1234,"cellid":12345678,"radio":"LTE","range":1695,"samples":3,"changeable":1,"message":null}"#
    static let area = TMobileOpenCellIDArea(latitude: 40, longitude: -100)!
    static let areaFixture = #"{"count":1,"cells":[{"lat":40,"lon":-100,"mcc":310,"mnc":260,"lac":1234,"cellid":12345678,"radio":"LTE","range":1695,"samples":3,"changeable":1}]}"#

    static func run(_ suite: TestSuite) {
        for (radio, area, cell) in [(TMobileOpenCellIDRadio.lte, "65535", "268435455"), (.nr, "16777215", "68719476735")] {
            suite.expect(TMobileOpenCellIDIdentity(radio: radio, mcc: "001", mnc: "0", tac: area, cellID: cell) != nil,
                         "manual identity accepts each radio's exact upper bounds without guessing any fields")
        }
        suite.expect(TMobileOpenCellIDIdentity(radio: .lte, mcc: "310", mnc: "026", tac: "0", cellID: "0")?.mnc == "026",
                     "manual network code spelling and legitimate zero identifiers are retained")
        for fields in [("31", "260", "1", "1"), ("0310", "260", "1", "1"), ("000", "260", "1", "1"),
                       ("３１０", "260", "1", "1"), ("310", "", "1", "1"), ("310", "1234", "1", "1"),
                       ("310", "2 6", "1", "1"), ("310", "260", "-1", "1"), ("310", "260", "1.5", "1"),
                       ("310", "260", "65536", "1"), ("310", "260", "1", "268435456"),
                       ("310", "260", "1", "1e3"), ("310", "260", "1", " 21"), ("310", "260", "1", ""),
                       ("310", "260", "1", "18446744073709551616")] {
            suite.expect(TMobileOpenCellIDIdentity(radio: .lte, mcc: fields.0, mnc: fields.1, tac: fields.2, cellID: fields.3) == nil,
                         "malformed, missing and overflow identity fields fail before a lookup")
        }
        suite.expect(TMobileOpenCellIDIdentity(radio: .nr, mcc: "310", mnc: "260", tac: "16777216", cellID: "1") == nil
                     && TMobileOpenCellIDIdentity(radio: .nr, mcc: "310", mnc: "260", tac: "1", cellID: "68719476736") == nil,
                     "NR identifiers reject values beyond the 24-bit TAC and 36-bit full NCI limits")
        for token in ["", "has space", "line\nbreak", String(repeating: "a", count: 8193), "é"] {
            suite.expect(!TMobileOpenCellIDSupport.validToken(token), "empty, non-ASCII, control and overlong API keys are rejected")
        }
        let key = "fixture+a&b=c?d#e%"
        let url = try? TMobileOpenCellIDSupport.requestURL(identity: identity, token: key)
        let components = url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }
        suite.expect(components?.scheme == "https" && components?.host == "opencellid.org" && components?.path == "/cell/get"
                     && components?.port == nil && components?.user == nil && components?.fragment == nil,
                     "provider URL is fixed to the official HTTPS endpoint")
        suite.expect(components?.queryItems?.count == 7 && components?.queryItems?.first(where: { $0.name == "key" })?.value == key
                     && components?.percentEncodedQuery?.contains("%2B") == true,
                     "reserved token characters cannot inject query items or turn plus into a space")
        let result = try? TMobileOpenCellIDSupport.parse(Data(fixture.utf8), requested: identity)
        suite.expect(result?.identity == identity && result?.latitude == 40 && result?.longitude == -100
                     && result?.rangeMeters == 1695 && result?.samples == 3 && result?.changeable == true,
                     "a result publishes only matched cell identity and allowed provider position fields")
        suite.expect(!String(reflecting: result).contains("latitude") && !String(reflecting: identity).contains("12345678"),
                     "debug descriptions do not expose coordinates or cell identifiers")
        for (field, value) in [("mcc", 311), ("mnc", 261), ("lac", 1235), ("cellid", 12345679)] {
            var root = try! JSONSerialization.jsonObject(with: Data(fixture.utf8)) as! [String: Any]
            root[field] = value
            expectFailure(suite, .identityMismatch, try! JSONSerialization.data(withJSONObject: root), "a mismatched echoed identifier rejects coordinates")
        }
        for value in ["NR", "lte", "GSM"] {
            var root = try! JSONSerialization.jsonObject(with: Data(fixture.utf8)) as! [String: Any]
            root["radio"] = value
            expectFailure(suite, .identityMismatch, try! JSONSerialization.data(withJSONObject: root), "the response radio must match exactly")
        }
        for field in ["mcc", "mnc", "lac", "cellid", "radio"] {
            var root = try! JSONSerialization.jsonObject(with: Data(fixture.utf8)) as! [String: Any]
            root.removeValue(forKey: field)
            expectFailure(suite, .identityMismatch, try! JSONSerialization.data(withJSONObject: root), "missing echoed identity cannot establish a result")
        }
        for (code, failure) in [(1, TMobileOpenCellIDFailure.notFound), (2, .authentication), (3, .invalidInput), (5, .unavailable), (7, .limit)] {
            let data = Data("{\"error\":\"fixture-sensitive-key\",\"code\":\(code)}".utf8)
            expectFailure(suite, failure, data, "HTTP-200 provider errors map to safe typed failures")
            suite.expect(!failure.message.contains("fixture-sensitive-key"), "provider error text never reaches the safe message")
        }
        for fields in [("lat", Double(91)), ("lon", Double(-181))] {
            var root = try! JSONSerialization.jsonObject(with: Data(fixture.utf8)) as! [String: Any]
            root[fields.0] = fields.1
            expectFailure(suite, .invalidResponse, try! JSONSerialization.data(withJSONObject: root), "invalid coordinates fail closed")
        }
        var typed = try! JSONSerialization.jsonObject(with: Data(fixture.utf8)) as! [String: Any]
        typed["lat"] = true
        expectFailure(suite, .invalidResponse, try! JSONSerialization.data(withJSONObject: typed), "boolean latitude cannot become a coordinate")
        typed["lat"] = 40; typed["mcc"] = true
        expectFailure(suite, .identityMismatch, try! JSONSerialization.data(withJSONObject: typed), "boolean identifiers cannot become matching numbers")
        expectFailure(suite, .invalidResponse, Data(repeating: 65, count: TMobileOpenCellIDSupport.maximumResponseBytes + 1), "oversized response bodies fail the parser bound")
        var deep: Any = 0
        for _ in 0..<10 { deep = ["nested": deep] }
        var root = try! JSONSerialization.jsonObject(with: Data(fixture.utf8)) as! [String: Any]
        root["ignored"] = deep
        expectFailure(suite, .invalidResponse, try! JSONSerialization.data(withJSONObject: root), "ignored fields still obey structural limits")
        let nr = TMobileOpenCellIDIdentity(radio: .nr, mcc: "310", mnc: "260", tac: "16777215", cellID: "68719476735")!
        let nrData = Data(#"{"lat":0,"lon":0,"mcc":310,"mnc":260,"lac":16777215,"cellid":68719476735,"radio":"NR"}"#.utf8)
        suite.expect((try? TMobileOpenCellIDSupport.parse(nrData, requested: nr))?.identity.cellID == 68719476735,
                     "full NR NCI retains exact integer precision without a guessed node split")
        areaRequests(suite)
        areaResponses(suite)
    }

    private static func areaRequests(_ suite: TestSuite) {
        for latitude in [0.0, 45, 85, -85] {
            let area = TMobileOpenCellIDArea(latitude: latitude, longitude: 0)!
            let height = distance(latitude: area.south, longitude: 0, toLatitude: area.north, toLongitude: 0)
            let width = distance(latitude: latitude, longitude: area.west, toLatitude: latitude, toLongitude: area.east)
            suite.expect(abs(height - 1_800) < 0.1 && abs(width - 1_800) < 0.1 && height * width < 4_000_000,
                         "map-center searches stay near 1.8 km on both axes and below the provider's 4 square km limit at latitude \(latitude)")
            suite.expect(abs((area.south + area.north) / 2 - latitude) < 0.0000001 && area.west < area.east,
                         "a bounded search remains centered on the chosen map coordinate")
        }
        for center in [(Double.nan, 0.0), (Double.infinity, 0.0), (86.0, 0.0), (-86.0, 0.0),
                       (0.0, Double.nan), (0.0, Double.infinity), (0.0, 181.0), (0.0, -181.0),
                       (0.0, 179.999), (0.0, -179.999)] {
            suite.expect(TMobileOpenCellIDArea(latitude: center.0, longitude: center.1) == nil,
                         "invalid, polar and antimeridian-crossing centers cannot create an unbounded search")
        }
        let token = "fixture+a&b=c?d#e%"
        for radio in TMobileOpenCellIDRadio.allCases {
            let url = try? TMobileOpenCellIDAreaSupport.requestURL(area: area, radio: radio, token: token)
            let components = url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }
            let query = components?.queryItems ?? []
            suite.expect(components?.scheme == "https" && components?.host == "opencellid.org"
                         && components?.path == "/cell/getInArea" && components?.port == nil
                         && components?.user == nil && components?.fragment == nil,
                         "area searches use only the fixed official HTTPS read endpoint")
            suite.expect(query.count == 6 && Set(query.map(\.name)) == ["key", "BBOX", "radio", "format", "limit", "offset"]
                         && query.first(where: { $0.name == "key" })?.value == token
                         && query.first(where: { $0.name == "BBOX" })?.value == area.queryValue
                         && query.first(where: { $0.name == "radio" })?.value == radio.rawValue
                         && query.first(where: { $0.name == "format" })?.value == "json"
                         && query.first(where: { $0.name == "limit" })?.value == "50"
                         && query.first(where: { $0.name == "offset" })?.value == "0"
                         && components?.percentEncodedQuery?.contains("%2B") == true
                         && components?.percentEncodedQuery?.contains("%2C") == true,
                         "reserved key and BBOX characters are encoded without adding fields, and requests stop at the first 50 chosen-radio cells")
        }
        do {
            _ = try TMobileOpenCellIDAreaSupport.requestURL(area: area, radio: .lte, token: "has space")
            suite.expect(false, "area request construction rejects an invalid key")
        } catch { suite.expect(error as? TMobileOpenCellIDFailure == .invalidInput, "area request construction rejects an invalid key") }
        suite.expect(!String(reflecting: area).contains("-100") && !String(reflecting: area).contains("south"),
                     "area debug descriptions do not expose map coordinates")
    }

    private static func areaResponses(_ suite: TestSuite) {
        let cell = try! JSONSerialization.jsonObject(with: Data(fixture.utf8)) as! [String: Any]
        let results = try? TMobileOpenCellIDAreaSupport.parse(Data(areaFixture.utf8), area: area, radio: .lte)
        suite.expect(results?.count == 1 && results?.first?.identity == identity
                     && results?.first?.latitude == 40 && results?.first?.longitude == -100
                     && results?.first?.rangeMeters == 1695 && results?.first?.samples == 3 && results?.first?.changeable == true,
                     "an area result retains the returned full identity and validated community position fields")
        suite.expect((try? TMobileOpenCellIDAreaSupport.parse(areaData([]), area: area, radio: .lte))?.isEmpty == true,
                     "an empty area is a valid empty result rather than invented coverage")
        suite.expect((try? TMobileOpenCellIDAreaSupport.parse(areaData([cell, cell]), area: area, radio: .lte))?.count == 1,
                     "duplicate complete cell identities produce a single community estimate")
        let fullPage = (0..<50).map { index -> [String: Any] in
            var changed = cell; changed["cellid"] = 12_345_678 + index; return changed
        }
        suite.expect((try? TMobileOpenCellIDAreaSupport.parse(areaData(fullPage), area: area, radio: .lte))?.count == 50,
                     "a complete first page of 50 valid unique identities remains within parser bounds")
        var otherNetwork = cell; otherNetwork["mnc"] = 261
        suite.expect((try? TMobileOpenCellIDAreaSupport.parse(areaData([cell, otherNetwork], count: 200), area: area, radio: .lte))?.count == 2,
                     "different networks remain distinct while a larger provider total does not require pagination")
        var nr = cell; nr["radio"] = "NR"; nr["lac"] = 16_777_215; nr["cellid"] = UInt64(68_719_476_735)
        let nrResults = try? TMobileOpenCellIDAreaSupport.parse(areaData([nr]), area: area, radio: .nr)
        suite.expect(nrResults?.first?.identity.radio == .nr && nrResults?.first?.identity.tac == 16_777_215
                     && nrResults?.first?.identity.cellID == 68_719_476_735,
                     "area NR responses preserve exact 24-bit TAC and 36-bit full NCI values")
        for radio in ["NR", "lte", "GSM"] {
            var changed = cell; changed["radio"] = radio
            expectAreaFailure(suite, .identityMismatch, areaData([changed]), "area cells must match the explicitly requested radio exactly")
        }
        for field in ["mcc", "mnc", "lac", "cellid", "radio", "lat", "lon"] {
            var changed = cell; changed.removeValue(forKey: field)
            expectAreaFailure(suite, field == "radio" ? .identityMismatch : .invalidResponse, areaData([changed]),
                              "missing returned identity or position fields reject the whole area response")
        }
        let invalidNumbers: [(String, Any)] = [
            ("mcc", true), ("mcc", "310"), ("mcc", 0), ("mcc", 1_000), ("mcc", 310.5),
            ("mnc", true), ("mnc", -1), ("mnc", 1_000), ("lac", true), ("lac", 65_536),
            ("cellid", true), ("cellid", "12345678"), ("cellid", 268_435_456), ("cellid", 12.5),
            ("lat", true), ("lat", "40"), ("lat", 91), ("lon", true), ("lon", -181),
            ("lat", 41), ("lon", -99)
        ]
        for (field, value) in invalidNumbers {
            var changed = cell; changed[field] = value
            expectAreaFailure(suite, .invalidResponse, areaData([changed]),
                              "area identity numbers and coordinates reject booleans, strings, fractions, overflow and out-of-area values")
        }
        var bad = cell; bad["lon"] = -99
        expectAreaFailure(suite, .invalidResponse, areaData([cell, bad]), "one invalid area cell prevents publication of a partial result")
        expectAreaFailure(suite, .invalidResponse, areaData(Array(repeating: cell, count: 51)), "the parser rejects more than 50 returned cells even when duplicates could be collapsed")
        for data in [Data(), Data("[]".utf8), Data(#"{"cells":[]}"#.utf8), Data(#"{"count":0}"#.utf8),
                     Data(#"{"count":true,"cells":[]}"#.utf8), Data(#"{"count":"0","cells":[]}"#.utf8),
                     Data(#"{"count":-1,"cells":[]}"#.utf8), Data(#"{"count":0.5,"cells":[]}"#.utf8),
                     Data(#"{"count":1,"cells":[null]}"#.utf8), areaData([cell], count: 0),
                     Data(repeating: 65, count: TMobileOpenCellIDSupport.maximumResponseBytes + 1)] {
            expectAreaFailure(suite, .invalidResponse, data, "area response envelopes enforce numeric counts, object cells and the response size bound")
        }
        var deep: Any = 0
        for _ in 0..<10 { deep = ["nested": deep] }
        let deepEnvelope: [String: Any] = ["count": 1, "cells": [cell], "ignored": deep]
        expectAreaFailure(suite, .invalidResponse, try! JSONSerialization.data(withJSONObject: deepEnvelope),
                          "ignored area-envelope fields still obey structural response bounds")
        for (code, expected) in [(1, TMobileOpenCellIDFailure.notFound), (2, .authentication), (3, .invalidInput), (7, .limit), (99, .unavailable)] {
            let data = Data("{\"error\":\"fixture-sensitive-key\",\"code\":\(code)}".utf8)
            expectAreaFailure(suite, expected, data, "area provider errors use safe typed failures before parsing cells")
        }
        suite.expect(area.contains(latitude: area.north + 0.0005, longitude: -100, mcc: "310")
                     && !area.contains(latitude: area.north + 0.0006, longitude: -100, mcc: "310")
                     && area.contains(latitude: area.north + 0.005, longitude: -100, mcc: "404")
                     && !area.contains(latitude: area.north + 0.0052, longitude: -100, mcc: "404"),
                     "provider coordinate rounding is allowed only within the documented MCC-specific precision")
        var rounded = cell; rounded["lat"] = area.north + 0.0005
        suite.expect((try? TMobileOpenCellIDAreaSupport.parse(areaData([rounded]), area: area, radio: .lte))?.count == 1,
                     "a valid cell rounded just beyond the BBOX edge remains usable")
    }

    private static func areaData(_ cells: [[String: Any]], count: Any? = nil) -> Data {
        try! JSONSerialization.data(withJSONObject: ["count": count ?? cells.count, "cells": cells])
    }
    private static func expectAreaFailure(_ suite: TestSuite, _ expected: TMobileOpenCellIDFailure, _ data: Data, _ label: String) {
        do { _ = try TMobileOpenCellIDAreaSupport.parse(data, area: area, radio: .lte); suite.expect(false, label) }
        catch { suite.expect(error as? TMobileOpenCellIDFailure == expected, label) }
    }
    private static func distance(latitude: Double, longitude: Double, toLatitude: Double, toLongitude: Double) -> Double {
        let first = latitude * .pi / 180, second = toLatitude * .pi / 180
        let latitudeDelta = (toLatitude - latitude) * .pi / 180
        let longitudeDelta = (toLongitude - longitude) * .pi / 180
        let haversine = pow(sin(latitudeDelta / 2), 2) + cos(first) * cos(second) * pow(sin(longitudeDelta / 2), 2)
        return 6_371_000 * 2 * atan2(sqrt(haversine), sqrt(max(0, 1 - haversine)))
    }
    private static func expectFailure(_ suite: TestSuite, _ expected: TMobileOpenCellIDFailure, _ data: Data, _ label: String) {
        do { _ = try TMobileOpenCellIDSupport.parse(data, requested: identity); suite.expect(false, label) }
        catch { suite.expect(error as? TMobileOpenCellIDFailure == expected, label) }
    }
}
