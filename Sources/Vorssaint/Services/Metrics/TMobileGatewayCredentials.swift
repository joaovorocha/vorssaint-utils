// SPDX-License-Identifier: GPL-3.0-or-later
import Combine
import Foundation

enum TMobileGatewayCredentialSupport {
    static func scope(address: String, username: String,
                      service: String = AppCredentialServices.service("gateway-admin.v1")) -> ScopedCredentialScope? {
        guard let origin = TMobileGatewaySupport.privateLANBaseURL(address), !username.isEmpty,
              username.utf8.count <= 128,
              !username.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return nil }
        // Both values are validated without newlines, making this unambiguous.
        // Scheme and explicit port remain part of the exact private LAN origin.
        return .init(service: service, account: "\(origin.absoluteString)\n\(username)")
    }
}

struct TMobileGatewaySignInCredentials: CustomStringConvertible, CustomDebugStringConvertible {
    let address: String
    let username: String
    let password: String
    fileprivate let scope: ScopedCredentialScope
    fileprivate let generation: Int
    fileprivate let remember: Bool
    var description: String { "TMobileGatewaySignInCredentials(redacted)" }
    var debugDescription: String { description }
}

/// Shared form logic only. Constructing, opening, changing scope and signing
/// out never access Keychain or start a network session. Saved values are read
/// only by Use saved password; the existing Sign in action remains explicit.
@MainActor
final class TMobileGatewayCredentialForm: ObservableObject {
    @Published var username = "admin" {
        didSet { if username != oldValue { clearVolatile() } }
    }
    @Published var password = ""
    @Published private(set) var remember = false
    @Published private(set) var message: String?
    private var address: String
    private var generation = 0
    private let store: any ScopedCredentialStore
    private let service: String

    init(address: String = "", store: any ScopedCredentialStore = KeychainScopedCredentialStore(),
         service: String = AppCredentialServices.service("gateway-admin.v1")) {
        self.address = address; self.store = store; self.service = service
    }

    var scopeIsValid: Bool { currentScope != nil }
    private var currentScope: ScopedCredentialScope? {
        TMobileGatewayCredentialSupport.scope(address: address, username: username, service: service)
    }

    func updateAddress(_ value: String) {
        guard address != value else { return }
        address = value; clearVolatile()
    }

    func setRemember(_ value: Bool) {
        if value { remember = true; message = nil }
        else {
            let enteredPassword = password
            forget()
            password = enteredPassword
        }
    }

    func useSavedPassword() {
        clearVolatile()
        guard let scope = currentScope else { message = "Enter a valid private gateway address and username."; return }
        do {
            guard let saved = try store.read(scope: scope) else {
                message = "No password is saved for this gateway and username."; return
            }
            guard !saved.isEmpty, saved.utf8.count <= 1_024 else {
                message = "The saved password is unavailable. Enter it again or forget it."; return
            }
            password = saved; remember = true
            message = "Saved password loaded. Select Sign in to connect."
        } catch {
            message = "Keychain is unavailable. Enter the password to sign in, or unlock Keychain and try again."
        }
    }

    func forget() {
        let scope = currentScope
        clearVolatile()
        guard let scope else { message = "Enter a valid private gateway address and username."; return }
        do {
            try store.delete(scope: scope)
            message = "Saved password forgotten for this gateway and username."
        } catch {
            message = "The saved password could not be forgotten. Unlock Keychain and try again."
        }
    }

    func prepareSignIn() -> TMobileGatewaySignInCredentials? {
        guard let scope = currentScope, !password.isEmpty, password.utf8.count <= 1_024 else {
            message = "Enter a valid private gateway address, username and administrator password."; return nil
        }
        let input = TMobileGatewaySignInCredentials(address: address, username: username, password: password,
                                                   scope: scope, generation: generation, remember: remember)
        password = ""; message = nil
        return input
    }

    func completeSignIn(_ input: TMobileGatewaySignInCredentials, succeeded: Bool) {
        guard succeeded, input.remember, input.generation == generation, input.scope == currentScope else { return }
        do {
            try store.save(input.password, scope: input.scope)
            message = "Password saved in Keychain on this Mac."
        } catch {
            message = "Signed in, but the password could not be saved in Keychain. Unlock Keychain and try again."
        }
    }

    func clearVolatile() {
        generation += 1; password = ""; remember = false; message = nil
    }
}
