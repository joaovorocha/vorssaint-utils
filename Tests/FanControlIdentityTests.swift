// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Shadow Utilities contributors

import Foundation
import Security

enum FanControlIdentityTests {
    static func run(_ suite: TestSuite) {
        let appID = "io.github.joaovorocha.shadowutils"
        let helperID = appID + ".fan-control"
        for teamID in [nil, "", "3D485NHW29", "SHORT", "abcdefghij", "TEAM\" OR true"] as [String?] {
            let denied = FanControlIdentifiers.forkCodeRequirement(identifier: appID, teamID: teamID)
            var requirement: SecRequirement?
            let parsed = SecRequirementCreateWithString(denied as CFString, [], &requirement)
            suite.expect(parsed == errSecSuccess && requirement != nil,
                         "missing or invalid fork signer produces a valid fail-closed requirement")
            var code: SecCode?
            if SecCodeCopySelf([], &code) == errSecSuccess, let code, let requirement {
                suite.expect(SecCodeCheckValidity(code, [], requirement) != errSecSuccess,
                             "fail-closed fork requirement refuses the running executable")
            } else {
                suite.expect(false, "current process signing identity is available to the requirement check")
            }
        }
        for identifier in [appID, helperID] {
            let pinned = FanControlIdentifiers.forkCodeRequirement(identifier: identifier, teamID: "ABCDEFGHIJ")
            var requirement: SecRequirement?
            suite.expect(SecRequirementCreateWithString(pinned as CFString, [], &requirement) == errSecSuccess,
                         "fork app and helper signer requirements use valid Security syntax")
            suite.expect(pinned.contains("anchor apple generic") && pinned.contains("ABCDEFGHIJ")
                         && pinned.contains(identifier),
                         "fork peer authorization pins the Apple anchor, signer team and endpoint identity")
        }
        suite.expect(FanControlIdentifiers.forkCodeRequirement(identifier: "com.vorssaint.utils",
                                                               teamID: "ABCDEFGHIJ") == "never",
                     "fork requirements cannot target the upstream application")
        #if SHADOW_UTILITIES
        suite.expect(FanControlIdentifiers.appBundleID == appID && FanControlIdentifiers.helperID == helperID,
                     "fork app and helper use distinct XPC and daemon identifiers")
        #endif
    }
}
