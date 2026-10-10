// SPDX-License-Identifier: GPL-3.0-or-later
import Combine
import Foundation

/// Explicit actions access one app-owned Keychain item. No startup lookup,
/// password storage, synchronization, or credential enumeration occurs.
@MainActor final class TMobileFCCCredentialForm: ObservableObject {
    @Published var username = ""
    @Published var token = ""
    @Published private(set) var message: String?
    private let store: any ScopedCredentialStore
    private let scope: ScopedCredentialScope

    private struct Saved: Codable { let username: String; let token: String }

    init(store: any ScopedCredentialStore = KeychainScopedCredentialStore(),
         service: String = AppCredentialServices.service("fcc-public-api.v1")) {
        self.store = store
        scope = .init(service: service, account: "https://broadbandmap.fcc.gov")
    }

    var isValid: Bool {
        Self.valid(username: username, token: token)
    }

    private static func valid(username: String, token: String) -> Bool {
        (3...254).contains(username.utf8.count) && username.contains("@")
            && (1...4_096).contains(token.utf8.count)
            && username.utf8.allSatisfy { $0 > 32 && $0 < 127 }
            && token.utf8.allSatisfy { $0 > 32 && $0 < 127 }
    }

    func save() {
        guard isValid else { message = "Enter your FCC email and API token without spaces or line breaks."; return }
        do {
            let data = try JSONEncoder().encode(Saved(username: username, token: token))
            guard let value = String(data: data, encoding: .utf8) else { throw ScopedCredentialStoreError.invalidSecret }
            try store.save(value, scope: scope)
            message = "FCC email and token saved in Keychain on this Mac. Check for updates to validate access."
        } catch { message = "Unable to save FCC access. Unlock Keychain and try again." }
    }

    func useSaved() {
        clear()
        do {
            guard let value = try store.read(scope: scope) else { message = "No FCC access is saved on this Mac."; return }
            guard let data = value.data(using: .utf8), let saved = try? JSONDecoder().decode(Saved.self, from: data),
                  Self.valid(username: saved.username, token: saved.token) else {
                message = "Saved FCC access is unavailable. Enter it again or forget it."; return
            }
            username = saved.username; token = saved.token
            message = "Saved FCC access loaded. Select Check for updates to connect."
        } catch { message = "Unable to read FCC access. Unlock Keychain or enter your token." }
    }

    func forget() {
        clear()
        do { try store.delete(scope: scope); message = "Saved FCC access forgotten on this Mac." }
        catch { message = "Unable to forget FCC access. Unlock Keychain and try again." }
    }

    func clear() { username = ""; token = ""; message = nil }
}
