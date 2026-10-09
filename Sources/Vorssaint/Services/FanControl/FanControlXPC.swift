// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Foundation
import Security

enum FanControlIdentifiers {
    #if SHADOW_UTILITIES
    static let appBundleID = "io.github.joaovorocha.shadowutils"
    // The same source runs in the app and its helper. Each requires its peer
    // to have the same Apple-issued Team ID as its own process; local/ad-hoc
    // builds fail closed instead of borrowing the upstream helper's identity.
    static let appCodeRequirement = forkCodeRequirement(
        identifier: appBundleID, teamID: currentProcessTeamID)
    static let helperCodeRequirement = forkCodeRequirement(
        identifier: helperID, teamID: currentProcessTeamID)

    private static let currentProcessTeamID: String? = {
        var code: SecCode?
        var staticCode: SecStaticCode?
        var information: CFDictionary?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation),
                                           &information) == errSecSuccess,
              let signing = information as? [String: Any] else { return nil }
        return signing[kSecCodeInfoTeamIdentifier as String] as? String
    }()
    #else
    static let teamID = "3D485NHW29"

    #if VORSSAINT_DEVELOPMENT
    static let appBundleID = "com.vorssaint.utils.dev"
    #else
    static let appBundleID = "com.vorssaint.utils"
    #endif

    static let appCodeRequirement =
        "anchor apple generic and certificate leaf[subject.OU] = \"\(teamID)\" and identifier \"\(appBundleID)\""
    static let helperCodeRequirement =
        "anchor apple generic and certificate leaf[subject.OU] = \"\(teamID)\" and identifier \"\(helperID)\""
    #endif

    static let helperID = "\(appBundleID).fan-control"
    static let plistName = "\(helperID).plist"

    /// Invalid or upstream identities cannot authorize either fork endpoint.
    /// ASCII validation also keeps requirement text from becoming executable
    /// requirement syntax when the signing metadata is malformed.
    static func forkCodeRequirement(identifier: String, teamID: String?) -> String {
        guard let teamID, teamID != "3D485NHW29", teamID.utf8.count == 10,
              teamID.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) }),
              identifier == "io.github.joaovorocha.shadowutils"
                || identifier == "io.github.joaovorocha.shadowutils.fan-control"
        else { return "never" }
        return "anchor apple generic and certificate leaf[subject.OU] = \"\(teamID)\" and identifier \"\(identifier)\""
    }
}

@objc protocol FanControlXPCProtocol {
    func status(withReply reply: @escaping (Data) -> Void)
    func startMaximumCooling(withReply reply: @escaping (Data) -> Void)
    func applyConfiguration(_ configuration: Data, withReply reply: @escaping (Data) -> Void)
    func heartbeat(withReply reply: @escaping (Data) -> Void)
    func restoreAutomatic(withReply reply: @escaping (Data) -> Void)
}

enum FanControlIPC {
    static func encode(_ response: FanControlResponse) -> Data {
        // Every value in this closed response model is JSON encodable. Keeping
        // one deterministic fallback avoids ever violating the XPC reply shape.
        (try? JSONEncoder().encode(response))
            ?? Data(#"{"succeeded":false,"snapshot":{"fans":[],"isCooling":false},"error":"controlFailed"}"#.utf8)
    }

    static func decode(_ data: Data) -> FanControlResponse? {
        try? JSONDecoder().decode(FanControlResponse.self, from: data)
    }

    static func encode(_ configuration: FanControlConfiguration) -> Data? {
        try? JSONEncoder().encode(configuration)
    }

    static func decodeConfiguration(_ data: Data) -> FanControlConfiguration? {
        guard let configuration = try? JSONDecoder().decode(FanControlConfiguration.self,
                                                              from: data),
              FanControlPolicy.validConfiguration(configuration) else { return nil }
        return configuration
    }
}
