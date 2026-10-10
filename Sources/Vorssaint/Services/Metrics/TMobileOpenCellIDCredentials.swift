// SPDX-License-Identifier: GPL-3.0-or-later
import Combine
import Foundation

/// Explicit local credential actions only. Typing, cell-ID edits, lookup and
/// closing a view never read or write Keychain through this form. Syntax checks
/// do not contact the provider or imply that an API key has been validated.
@MainActor
final class TMobileOpenCellIDCredentialForm: ObservableObject {
    @Published var token = "" {
        didSet { if token != oldValue { message = nil } }
    }
    @Published private(set) var message: String?
    private let store: any ScopedCredentialStore
    private let scope: ScopedCredentialScope

    init(store: any ScopedCredentialStore = KeychainScopedCredentialStore(),
         service: String = AppCredentialServices.service("opencellid-api-key.v1")) {
        self.store = store
        scope = .init(service: service, account: "https://opencellid.org")
    }

    var validToken: Bool { TMobileOpenCellIDSupport.validToken(token) }

    func saveKey() {
        guard validToken else {
            message = "Enter an API key without spaces or line breaks, up to 8,192 bytes."; return
        }
        do {
            try store.save(token, scope: scope)
            message = "API key saved in Keychain on this Mac. The provider has not validated it."
        } catch {
            message = "The API key could not be saved in Keychain. Unlock Keychain and try again."
        }
    }

    func useSavedKey() {
        token = ""; message = nil
        do {
            guard let saved = try store.read(scope: scope) else {
                message = "No API key is saved for OpenCelliD on this Mac."; return
            }
            guard TMobileOpenCellIDSupport.validToken(saved) else {
                message = "The saved API key is unavailable. Enter it again or forget it."; return
            }
            token = saved
            message = "Saved API key loaded. Lookup remains manual."
        } catch {
            message = "Keychain is unavailable. Enter an API key, or unlock Keychain and try again."
        }
    }

    func forgetKey() {
        clearVolatile()
        do {
            try store.delete(scope: scope)
            message = "Saved OpenCelliD API key forgotten on this Mac."
        } catch {
            message = "The saved API key could not be forgotten. Unlock Keychain and try again."
        }
    }

    func clearVolatile() { token = ""; message = nil }
}
