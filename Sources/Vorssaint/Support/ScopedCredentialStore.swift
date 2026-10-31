// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Security

/// A caller must choose an app-owned service and an exact account. No store
/// operation enumerates items or falls back to another service/account.
struct ScopedCredentialScope: Hashable, CustomStringConvertible, CustomDebugStringConvertible {
    let service: String
    let account: String

    var description: String { "ScopedCredentialScope(redacted)" }
    var debugDescription: String { description }
    fileprivate var isValid: Bool {
        !service.isEmpty && service.utf8.count <= 512 && !account.isEmpty && account.utf8.count <= 2_048
    }
}

enum ScopedCredentialStoreError: Error {
    case invalidScope, invalidSecret, invalidSavedValue, unavailable, interactionRequired
}

protocol ScopedCredentialStore {
    func read(scope: ScopedCredentialScope) throws -> String?
    func read(scope: ScopedCredentialScope, allowingUserInteraction: Bool) throws -> String?
    func save(_ secret: String, scope: ScopedCredentialScope) throws
    func delete(scope: ScopedCredentialScope) throws
}

extension ScopedCredentialStore {
    /// Stores without a quiet-read implementation cannot trigger UI implicitly.
    func read(scope: ScopedCredentialScope, allowingUserInteraction: Bool) throws -> String? {
        allowingUserInteraction ? try read(scope: scope) : nil
    }
}

/// Injectable Security boundary lets regression tests inspect every query
/// without accessing even a synthetic item in the real user's Keychain.
protocol ScopedCredentialKeychainAccess {
    func copyMatching(_ query: [String: Any]) -> (OSStatus, Data?)
    func add(_ attributes: [String: Any]) -> OSStatus
    func update(_ query: [String: Any], attributes: [String: Any]) -> OSStatus
    func delete(_ query: [String: Any]) -> OSStatus
}

private struct SystemScopedCredentialKeychainAccess: ScopedCredentialKeychainAccess {
    func copyMatching(_ query: [String: Any]) -> (OSStatus, Data?) {
        // AuthenticationUIFail covers Data Protection items. Legacy local
        // Keychain items also need this process-local guard, restored on return.
        let quiet = query[kSecUseAuthenticationUI as String] as? String == kSecUseAuthenticationUIFail as String
        var previous = DarwinBoolean(true)
        if quiet {
            guard SecKeychainGetUserInteractionAllowed(&previous) == errSecSuccess,
                  SecKeychainSetUserInteractionAllowed(false) == errSecSuccess else {
                return (errSecInteractionNotAllowed, nil)
            }
        }
        defer { if quiet { _ = SecKeychainSetUserInteractionAllowed(previous.boolValue) } }
        var value: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &value)
        return (status, value as? Data)
    }
    func add(_ attributes: [String: Any]) -> OSStatus { SecItemAdd(attributes as CFDictionary, nil) }
    func update(_ query: [String: Any], attributes: [String: Any]) -> OSStatus {
        SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
    }
    func delete(_ query: [String: Any]) -> OSStatus { SecItemDelete(query as CFDictionary) }
}

/// Native macOS generic-password items use the local Keychain and the creating
/// app's normal code-signing access control. Synchronization is always disabled;
/// no shared access group, internet-password item, or plaintext fallback exists.
final class KeychainScopedCredentialStore: ScopedCredentialStore {
    private let access: any ScopedCredentialKeychainAccess
    private let maximumSecretBytes = 16_384

    init(access: (any ScopedCredentialKeychainAccess)? = nil) {
        self.access = access ?? SystemScopedCredentialKeychainAccess()
    }

    private func query(_ scope: ScopedCredentialScope) throws -> [String: Any] {
        guard scope.isValid else { throw ScopedCredentialStoreError.invalidScope }
        return [kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: scope.service,
                kSecAttrAccount as String: scope.account,
                kSecAttrSynchronizable as String: false]
    }

    func read(scope: ScopedCredentialScope) throws -> String? {
        try read(scope: scope, allowingUserInteraction: true)
    }

    func read(scope: ScopedCredentialScope, allowingUserInteraction: Bool) throws -> String? {
        var request = try query(scope)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        if !allowingUserInteraction { request[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail }
        let (status, data) = access.copyMatching(request)
        if status == errSecItemNotFound { return nil }
        if !allowingUserInteraction && [errSecInteractionNotAllowed, errSecAuthFailed].contains(status) {
            throw ScopedCredentialStoreError.interactionRequired
        }
        guard status == errSecSuccess else { throw ScopedCredentialStoreError.unavailable }
        guard let data, !data.isEmpty, data.count <= maximumSecretBytes,
              let value = String(data: data, encoding: .utf8) else {
            throw ScopedCredentialStoreError.invalidSavedValue
        }
        return value
    }

    func save(_ secret: String, scope: ScopedCredentialScope) throws {
        let request = try query(scope)
        guard !secret.isEmpty, secret.utf8.count <= maximumSecretBytes else {
            throw ScopedCredentialStoreError.invalidSecret
        }
        let value = [kSecValueData as String: Data(secret.utf8)]
        var status = access.update(request, attributes: value)
        if status == errSecItemNotFound {
            status = access.add(request.merging(value) { _, new in new })
            if status == errSecDuplicateItem { status = access.update(request, attributes: value) }
        }
        guard status == errSecSuccess else { throw ScopedCredentialStoreError.unavailable }
    }

    func delete(scope: ScopedCredentialScope) throws {
        let status = access.delete(try query(scope))
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw ScopedCredentialStoreError.unavailable
        }
    }
}

enum AppCredentialServices {
    static func service(_ purpose: String) -> String {
        #if SHADOW_UTILITIES
        let fallback = "io.github.joaovorocha.shadowutils"
        #elseif VORSSAINT_DEVELOPMENT
        let fallback = "com.vorssaint.utils.dev"
        #else
        let fallback = "com.vorssaint.utils"
        #endif
        return "\(Bundle.main.bundleIdentifier ?? fallback).credentials.\(purpose)"
    }
}
