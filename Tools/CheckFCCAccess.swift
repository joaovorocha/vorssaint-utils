// SPDX-License-Identifier: GPL-3.0-or-later
import Darwin
import Foundation
import LocalAuthentication
import Security

/// Explicit owner-run live check. Reads one exact app-owned item, refuses
/// interactive Keychain access, and sends its contents only to the FCC client.
@main enum CheckFCCAccess {
    private struct Saved: Decodable { let username: String; let token: String }
    private final class ReadOnlyKeychain: ScopedCredentialKeychainAccess {
        func copyMatching(_ query: [String: Any]) -> (OSStatus, Data?) {
            // LAContext alone covers Data Protection items. The app's normal
            // macOS Keychain item also needs this process-local legacy guard.
            // This denies UI; it never grants access or changes an item's ACL.
            var wasAllowed = DarwinBoolean(false)
            let previousStatus = SecKeychainGetUserInteractionAllowed(&wasAllowed)
            guard previousStatus == errSecSuccess else { return (previousStatus, nil) }
            let disableStatus = SecKeychainSetUserInteractionAllowed(false)
            guard disableStatus == errSecSuccess else { return (disableStatus, nil) }
            defer { _ = SecKeychainSetUserInteractionAllowed(wasAllowed.boolValue) }
            var request = query
            let context = LAContext()
            context.interactionNotAllowed = true
            request[kSecUseAuthenticationContext as String] = context
            var result: CFTypeRef?
            let status = SecItemCopyMatching(request as CFDictionary, &result)
            return (status, result as? Data)
        }
        func add(_ attributes: [String: Any]) -> OSStatus { errSecAuthFailed }
        func update(_ query: [String: Any], attributes: [String: Any]) -> OSStatus { errSecAuthFailed }
        func delete(_ query: [String: Any]) -> OSStatus { errSecAuthFailed }
    }
    static func main() async {
        if CommandLine.arguments.count == 2, CommandLine.arguments[1] == "--help" {
            print("Usage: CheckFCCAccess.sh [NEW_ZIP_DESTINATION]. Explicitly checks saved FCC access; never prints credentials or permits a Keychain prompt.")
            return
        }
        guard CommandLine.arguments.count == 1 || CommandLine.arguments.count == 2 else {
            stop("Usage: CheckFCCAccess.sh [NEW_ZIP_DESTINATION]", status: 2)
        }
        let scope = ScopedCredentialScope(
            service: "io.github.joaovorocha.shadowutils.credentials.fcc-public-api.v1",
            account: "https://broadbandmap.fcc.gov")
        let saved: Saved
        do {
            guard let value = try KeychainScopedCredentialStore(access: ReadOnlyKeychain()).read(scope: scope),
                  let data = value.data(using: .utf8) else {
                stop("UNVERIFIED: no FCC access is saved in the app-specific Keychain item.", status: 2)
            }
            saved = try JSONDecoder().decode(Saved.self, from: data)
        } catch {
            stop("UNVERIFIED: saved FCC access cannot be read without a macOS approval. Choose Use saved access in the signed app.", status: 2)
        }
        let credentials = FCCCoverageCredentials(username: saved.username, token: saved.token)
        guard credentials.isValid else { stop("FAIL: saved FCC access has an invalid format.", status: 1) }
        do {
            let client = FCCCoverageClient()
            let catalogue = try await client.checkLatestMobileCoverage(stateFIPS: "06", credentials: credentials)
            print("PASS authenticated FCC catalogue: California, as of \(catalogue.asOfDate), \(catalogue.files.count) supported T-Mobile files.")
            if CommandLine.arguments.count == 2 {
                guard let file = catalogue.files.first(where: {
                    $0.geometry == .raw && $0.technology == .nr && $0.speedTier == .thirtyFiveThree
                }) else { stop("UNVERIFIED: no California 5G NR 35/3 raw file is available.", status: 2) }
                _ = try await client.downloadGeoPackage(file: file,
                    to: URL(fileURLWithPath: CommandLine.arguments[1]), credentials: credentials)
                print("PASS authenticated FCC GeoPackage ZIP download.")
            }
        } catch {
            stop("FAIL FCC access check: \(FCCCoverageFailure.safe(error).message)", status: 1)
        }
    }
    private static func stop(_ message: String, status: Int32) -> Never {
        FileHandle.standardError.write(Data((message + "\n").utf8))
        exit(status)
    }
}
