// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint
import Foundation

enum TMobileOpenCellIDTests {
    static let identity = TMobileOpenCellIDIdentity(radio: .lte, mcc: "310", mnc: "260", tac: "1234", cellID: "12345678")!
    static let fixture = #"{"lat":40,"lon":-100,"mcc":310,"mnc":260,"lac":1234,"cellid":12345678,"radio":"LTE","range":1695,"samples":3,"changeable":1,"message":null}"#

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
    }
    private static func expectFailure(_ suite: TestSuite, _ expected: TMobileOpenCellIDFailure, _ data: Data, _ label: String) {
        do { _ = try TMobileOpenCellIDSupport.parse(data, requested: identity); suite.expect(false, label) }
        catch { suite.expect(error as? TMobileOpenCellIDFailure == expected, label) }
    }
}
