// SPDX-License-Identifier: GPL-3.0-or-later
import Darwin
import Foundation

/// Interactive owner-run helper. Secrets travel directly from the controlling
/// terminal to the scoped Keychain store, never through arguments or disk files.
@main enum SaveFCCAccess {
    private struct Access: Encodable { let username: String; let token: String }

    static func main() {
        if CommandLine.arguments.dropFirst().contains("--help") {
            print("Prompts privately for FCC access and saves one Shadow Utilities Keychain item. Makes no network request.")
            return
        }
        guard CommandLine.arguments.count == 1 else { fail("Run without arguments; enter access only at the prompts.") }
        guard let username = prompt("FCC account email: ", hidden: false),
              let token = prompt("FCC API token (hidden): ", hidden: true) else {
            fail("Input cancelled. Nothing was saved.")
        }
        guard (3...254).contains(username.utf8.count), username.contains("@"),
              (1...4_096).contains(token.utf8.count),
              username.utf8.allSatisfy({ $0 > 32 && $0 < 127 }),
              token.utf8.allSatisfy({ $0 > 32 && $0 < 127 }) else {
            fail("Enter the FCC email and token without spaces or line breaks. Nothing was saved.")
        }
        do {
            let data = try JSONEncoder().encode(Access(username: username, token: token))
            guard let value = String(data: data, encoding: .utf8) else { fail("Unable to prepare FCC access.") }
            let scope = ScopedCredentialScope(
                service: "io.github.joaovorocha.shadowutils.credentials.fcc-public-api.v1",
                account: "https://broadbandmap.fcc.gov")
            try KeychainScopedCredentialStore().save(value, scope: scope)
            print("Saved FCC access in this Mac’s Keychain. In the FCC-enabled Shadow Utilities build, choose Use saved access.")
        } catch {
            fail("Unable to save FCC access. Unlock your login Keychain and try again.")
        }
    }

    private static func prompt(_ text: String, hidden: Bool) -> String? {
        var buffer = [CChar](repeating: 0, count: 4_098)
        defer { buffer.withUnsafeMutableBytes { _ = memset_s($0.baseAddress!, $0.count, 0, $0.count) } }
        return buffer.withUnsafeMutableBufferPointer { pointer in
            let flags = Int32(RPP_REQUIRE_TTY | (hidden ? RPP_ECHO_OFF : RPP_ECHO_ON))
            guard readpassphrase(text, pointer.baseAddress, pointer.count, flags) != nil else { return nil }
            return String(validatingUTF8: pointer.baseAddress!)
        }
    }

    private static func fail(_ text: String) -> Never {
        FileHandle.standardError.write(Data((text + "\n").utf8))
        exit(1)
    }
}
