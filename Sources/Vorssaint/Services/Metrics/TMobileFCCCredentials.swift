// SPDX-License-Identifier: GPL-3.0-or-later
import Combine
import Foundation

/// The FCC flow quietly checks one app-owned Keychain item before asking for
/// access. Only an explicit unlock may display Keychain UI. No enumeration occurs.
@MainActor final class TMobileFCCCredentialForm: ObservableObject {
    enum SavedAccessState { case unchecked, available, missing, locked, invalid }
    @Published var username = "" { didSet { needsSave = true } }
    @Published var token = "" { didSet { needsSave = true } }
    @Published private(set) var needsSave = true
    @Published private(set) var message: String?
    @Published private(set) var savedAccessState = SavedAccessState.unchecked
    private var checkedSavedAccess = false
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
            savedAccessState = .available
            needsSave = false
            message = "FCC access saved in Keychain on this Mac."
        } catch { message = "Unable to save FCC access. Unlock Keychain and try again." }
    }

    func useSaved() {
        clear()
        loadSaved(allowingUserInteraction: true)
    }

    /// Called when the FCC flow opens, once per workspace. It never displays
    /// authentication UI or replaces valid input that the person is entering.
    func prepareSavedAccess() {
        guard !checkedSavedAccess else { return }
        checkedSavedAccess = true
        guard !isValid, username.isEmpty, token.isEmpty else { return }
        loadSaved(allowingUserInteraction: false)
    }

    private func loadSaved(allowingUserInteraction: Bool) {
        do {
            guard let value = try store.read(scope: scope, allowingUserInteraction: allowingUserInteraction) else {
                savedAccessState = .missing
                message = "No FCC access is saved on this Mac."; return
            }
            guard let data = value.data(using: .utf8), let saved = try? JSONDecoder().decode(Saved.self, from: data),
                  Self.valid(username: saved.username, token: saved.token) else {
                savedAccessState = .invalid
                message = "Saved FCC access is unavailable. Enter it again or forget it."; return
            }
            username = saved.username; token = saved.token
            savedAccessState = .available
            needsSave = false
            message = "Saved FCC access is ready."
        } catch ScopedCredentialStoreError.interactionRequired {
            savedAccessState = .locked
            message = "Unlock saved FCC access to continue."
        } catch {
            savedAccessState = .locked
            message = "Unable to read FCC access. Unlock Keychain or enter your token."
        }
    }

    func forget() {
        clear()
        do { try store.delete(scope: scope); savedAccessState = .missing; message = "Saved FCC access forgotten on this Mac." }
        catch { message = "Unable to forget FCC access. Unlock Keychain and try again." }
    }

    func clear() { username = ""; token = ""; message = nil }

    func rejectAccess() {
        token = ""
        savedAccessState = .invalid
        message = "FCC did not accept the saved access. Update your token to continue."
    }
}
