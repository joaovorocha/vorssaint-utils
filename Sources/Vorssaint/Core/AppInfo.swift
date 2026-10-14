// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Foundation
#if SHADOW_UTILITIES
import Security
#endif

/// Static identity of the app, shared by UI, notifications and tooling.
enum AppInfo {
    #if SHADOW_UTILITIES
    static let name = "Shadow Utilities"
    static let copyright = "© 2026 Shadow Utilities contributors"
    static let repository = "joaovorocha/vorssaint-utils"
    static let repositoryURL = URL(string: "https://github.com/joaovorocha/vorssaint-utils")!
    static let websiteURL = repositoryURL
    static let coffeeURL = repositoryURL
    static let discordURL = URL(string: "https://github.com/joaovorocha/vorssaint-utils/issues")!
    static let socialURL = URL(string: "https://github.com/joaovorocha")!
    #else
    static let name = "Vorssaint"
    static let copyright = "© 2026 Vorssaint"
    static let repository = "vorssaint/vorssaint-utils"
    static let websiteURL = URL(string: "https://vorssaint.com")!
    static let repositoryURL = URL(string: "https://github.com/vorssaint/vorssaint-utils")!
    static let coffeeURL = URL(string: "https://buymeacoffee.com/vorssaint")!
    static let discordURL = URL(string: "https://discord.gg/M6BwWH4BJp")!
    static let socialURL = URL(string: "https://x.com/vorssaint")!
    #endif

    /// Fork releases pin their own public Team ID in the signed Info.plist.
    /// Missing metadata, a local signature or a changed bundle disables updates.
    static var updateSigningIdentity: UpdateInstallerSupport.SigningIdentity? {
        #if SHADOW_UTILITIES
        guard let teamID = Bundle.main.object(forInfoDictionaryKey: "ShadowUpdateTeamID") as? String,
              teamID != UpdateInstallerSupport.SigningIdentity.official.teamID,
              let identity = UpdateInstallerSupport.SigningIdentity(
                bundleIdentifier: UpdateInstallerSupport.forkBundleIdentifier, teamID: teamID),
              Bundle.main.bundleIdentifier == identity.bundleIdentifier else { return nil }

        var code: SecStaticCode?
        var requirement: SecRequirement?
        guard SecStaticCodeCreateWithPath(Bundle.main.bundleURL as CFURL, [], &code) == errSecSuccess,
              let code,
              SecRequirementCreateWithString(identity.appRequirement as CFString, [], &requirement) == errSecSuccess,
              SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate), requirement) == errSecSuccess
        else { return nil }

        var information: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation),
                                             &information) == errSecSuccess,
              let signing = information as? [String: Any] else { return nil }
        return UpdateInstallerSupport.forkSigningIdentity(
            configuredTeamID: teamID, bundleIdentifier: Bundle.main.bundleIdentifier,
            signatureTeamID: signing[kSecCodeInfoTeamIdentifier as String] as? String,
            signatureIsValid: true)
        #else
        return .official
        #endif
    }

    /// The bundle version. The fallback only applies to the bare binary
    /// (e.g. `--selftest`), never the shipped app, which reads its Info.plist.
    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    /// True for the local "Vorssaint (Developer)" build (bundle id ends in `.dev`).
    /// It is never published and never auto-updates; all work is tested here first.
    static var isDeveloperBuild: Bool {
        (Bundle.main.bundleIdentifier ?? "").hasSuffix(".dev")
    }

    /// True when the current version is a pre-release (e.g. 3.3.4-beta.1 or 3.3.4-rc.1).
    static var isBeta: Bool {
        if isDeveloperBuild && UserDefaults.standard.bool(forKey: DefaultsKey.simulateBetaUI) {
            return true
        }
        let v = version.lowercased()
        return v.contains("-beta") || v.contains("-rc") || v.contains("-alpha")
    }

    /// The git commit a Developer build was compiled from, e.g. "ed2ebba · 2026-06-15 21:30"
    /// (or with a "-dirty" suffix on the SHA for uncommitted changes). build.sh stamps
    /// this into the Developer bundle only, so you can confirm at a glance that the
    /// running dev app matches the source you are about to change. nil in the official app.
    static var buildCommit: String? {
        Bundle.main.object(forInfoDictionaryKey: "VorssaintBuildCommit") as? String
    }
}
