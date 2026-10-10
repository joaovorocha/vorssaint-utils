// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Security

/// Every secret, origin and identity in this harness is synthetic. Both the
/// high-level store and Security call boundary are mocked: no Keychain or URL
/// session is opened, and failure reports print assertion labels only.
@main
enum TMobileGatewayCredentialHarness {
    @MainActor static func main() {
        let suite = CredentialSuite()
        scopes(suite)
        keychainBoundary(suite)
        formLifecycle(suite)
        apiKeyLifecycle(suite)
        print("Scoped credential fixtures: \(suite.checks) checks, \(suite.failures) failures")
        exit(suite.failures == 0 ? 0 : 1)
    }

    private static let origin = "http://192.168.12.1"
    private static let namespace = "fixture.app.credentials.gateway-admin.v1"
    private static let secret = "synthetic-password-value"
    private static func scope(_ address: String = origin, _ user: String = "admin", _ service: String = namespace) -> ScopedCredentialScope? {
        TMobileGatewayCredentialSupport.scope(address: address, username: user, service: service)
    }

    private static func scopes(_ suite: CredentialSuite) {
        suite.check(scope() != nil && scope(origin + "/") == scope(), "trailing-slash normalization shares one validated origin")
        for address in ["https://192.168.12.1", origin + ":80", origin + ":8080", "http://192.168.12.2"] {
            suite.check(scope(address) != scope(), "scheme, explicit port and host isolate saved credentials")
        }
        suite.check(scope(origin, "Admin") != scope() && scope(origin, "other") != scope(), "username scope is exact and case preserving")
        suite.check(scope(origin, "admin", "other.app.credentials.gateway-admin.v1") != scope(), "another app service cannot match a gateway record")
        for address in ["http://8.8.8.8", "https://example.test", origin + "/TMI", origin + "?x=1", "http://192.168.12.1@8.8.8.8", "http://0192.168.12.1", "file:///tmp/gateway"] {
            suite.check(scope(address) == nil, "public, repaired and non-origin inputs never produce a credential key")
        }
        for username in ["", "admin\nother", "admin\t", String(repeating: "a", count: 129)] {
            suite.check(scope(origin, username) == nil, "empty, control and overlong usernames never produce a credential key")
        }
        suite.check(!String(reflecting: scope()!).contains(origin), "scope descriptions do not disclose account metadata")
    }

    private static func keychainBoundary(_ suite: CredentialSuite) {
        let access = MockKeychainAccess()
        let store = KeychainScopedCredentialStore(access: access)
        let key = scope()!
        access.readResult = (errSecSuccess, Data(secret.utf8))
        suite.check((try? store.read(scope: key)) == secret, "exact mocked Keychain value is decoded")
        suite.check(access.reads.count == 1 && exact(access.reads[0], key), "read uses only generic-password, exact service/account and non-sync scope")
        suite.check(access.reads[0][kSecMatchLimit as String] as? String == kSecMatchLimitOne as String
                    && access.reads[0][kSecReturnData as String] as? Bool == true, "read requests one secret without enumeration")
        access.readResult = (errSecItemNotFound, nil)
        do {
            let missing = try store.read(scope: key)
            suite.check(missing == nil, "missing Keychain item is an ordinary empty result")
        }
        catch { suite.check(false, "missing item must not throw") }
        for status in [errSecInteractionNotAllowed, errSecAuthFailed, errSecNotAvailable, errSecMissingEntitlement] {
            access.readResult = (status, nil)
            suite.check(fails { _ = try store.read(scope: key) }, "locked, denied and unavailable Keychain reads fail without fallback")
        }
        for data in [Data(), Data([0xff]), Data(repeating: 65, count: 16_385)] {
            access.readResult = (errSecSuccess, data)
            suite.check(fails { _ = try store.read(scope: key) }, "empty, invalid and oversized saved values reject")
        }
        access.updateResults = [errSecItemNotFound]
        access.addResult = errSecSuccess
        suite.check(!fails { try store.save(secret, scope: key) }, "new value is added after exact update reports missing")
        suite.check(access.updates.allSatisfy { exact($0.0, key) && Set($0.1.keys) == [kSecValueData as String] }
                    && access.adds.count == 1 && exact(access.adds[0], key), "save never widens query or changes unrelated attributes")
        access.updateResults = [errSecSuccess]
        suite.check(!fails { try store.save(secret, scope: key) } && access.adds.count == 1, "existing value updates in place without delete or duplicate creation")
        access.updateResults = [errSecItemNotFound, errSecSuccess]
        access.addResult = errSecDuplicateItem
        suite.check(!fails { try store.save(secret, scope: key) }, "concurrent duplicate creation retries one exact update")
        access.updateResults = [errSecAuthFailed]
        suite.check(fails { try store.save(secret, scope: key) }, "save denial is surfaced without a plaintext fallback")
        access.deleteResult = errSecItemNotFound
        suite.check(!fails { try store.delete(scope: key) }, "forget is idempotent when no record exists")
        suite.check(access.deletes.count == 1 && exact(access.deletes[0], key), "forget targets only the exact generic-password record")
        access.deleteResult = errSecInteractionNotAllowed
        suite.check(fails { try store.delete(scope: key) }, "forget denial cannot claim successful deletion")
        let calls = access.callCount
        for bad in [ScopedCredentialScope(service: "", account: "fixture"), .init(service: "fixture", account: "")] {
            suite.check(fails { _ = try store.read(scope: bad) }
                        && fails { try store.save(secret, scope: bad) }
                        && fails { try store.delete(scope: bad) }, "invalid generic scopes reject before Security access")
        }
        suite.check(access.callCount == calls, "invalid scopes caused no backend calls")
        suite.check(fails { try store.save("", scope: key) } && fails { try store.save(String(repeating: "x", count: 16_385), scope: key) }
                    && access.callCount == calls, "invalid secret lengths reject before Security access")
    }

    @MainActor private static func formLifecycle(_ suite: CredentialSuite) {
        let store = MockCredentialStore()
        let form = TMobileGatewayCredentialForm(address: origin, store: store, service: namespace)
        suite.check(store.calls == 0 && !form.remember && form.password.isEmpty, "opening a form never reads saved secrets or opts in")
        form.password = secret
        let unsaved = form.prepareSignIn()!
        suite.check(form.password.isEmpty && store.calls == 0, "explicit sign-in removes the field value without storing or reading")
        form.completeSignIn(unsaved, succeeded: true)
        suite.check(store.calls == 0, "successful sign-in without opt-in never persists a password")
        form.password = secret; form.setRemember(true)
        let optedIn = form.prepareSignIn()!
        form.completeSignIn(optedIn, succeeded: false)
        suite.check(store.calls == 0, "failed or cancelled authentication cannot save even an opted-in password")
        form.completeSignIn(optedIn, succeeded: true)
        suite.check(store.values[scope()!] == secret && store.writes == 1, "successful explicit opted-in authentication saves one exact record")
        suite.check(!String(describing: optedIn).contains(secret) && !String(reflecting: optedIn).contains(secret), "sign-in credential descriptions redact values")
        let wifi = TMobileGatewayCredentialForm(address: origin + "/", store: store, service: namespace)
        suite.check(wifi.password.isEmpty && store.reads == 0, "a second login surface does not silently load or sign in")
        wifi.useSavedPassword()
        suite.check(wifi.password == secret && wifi.remember && store.reads == 1, "explicit Use saved password shares the exact gateway record across login surfaces")
        wifi.username = "other"
        suite.check(wifi.password.isEmpty && !wifi.remember, "username changes clear loaded secrets and consent")
        wifi.useSavedPassword()
        suite.check(wifi.password.isEmpty && wifi.message?.contains("No password") == true, "another username never receives the saved administrator password")
        wifi.username = "admin"; wifi.useSavedPassword()
        let pending = wifi.prepareSignIn()!
        wifi.updateAddress("https://192.168.12.1")
        let before = store.writes
        wifi.completeSignIn(pending, succeeded: true)
        suite.check(store.writes == before && wifi.password.isEmpty && !wifi.remember, "address changes fence late sign-in completion and clear volatile secrets")
        wifi.useSavedPassword()
        suite.check(wifi.password.isEmpty, "a different scheme cannot load an HTTP-origin password")
        wifi.updateAddress(origin); wifi.useSavedPassword()
        let forgottenPending = wifi.prepareSignIn()!
        wifi.forget()
        wifi.completeSignIn(forgottenPending, succeeded: true)
        suite.check(store.values[scope()!] == nil && wifi.password.isEmpty && !wifi.remember, "Forget deletes the exact record and fences pending sign-in from recreating it")
        suite.check(wifi.message?.contains("forgotten") == true, "successful Forget reports its scoped result")
        form.password = secret; form.setRemember(true)
        let closed = form.prepareSignIn()!
        form.clearVolatile(); form.completeSignIn(closed, succeeded: true)
        suite.check(store.values.isEmpty && form.password.isEmpty, "sign-out/window close fences late persistence without reading or deleting unrelated records")
        form.password = secret; form.setRemember(true); form.setRemember(false)
        suite.check(form.password == secret && !form.remember, "turning Remember off forgets persisted value while preserving typed sign-in input")
        store.error = ScopedCredentialStoreError.unavailable
        form.useSavedPassword()
        suite.check(form.password.isEmpty && form.message?.contains("Keychain is unavailable") == true
                    && form.message?.contains(secret) == false, "Keychain read failure clears volatile input and displays a safe recovery message")
        form.password = secret; form.setRemember(true)
        let denied = form.prepareSignIn()!
        form.completeSignIn(denied, succeeded: true)
        suite.check(form.message?.contains("Signed in, but") == true && form.message?.contains(secret) == false, "persistence failure reports sign-in success without exposing the secret")
        form.forget()
        suite.check(form.message?.contains("could not be forgotten") == true, "forget failure never reports removal")
        store.error = nil
        store.values[scope()!] = String(repeating: "x", count: 1_025)
        form.useSavedPassword()
        suite.check(form.password.isEmpty && !form.remember, "gateway-specific saved password limits apply after generic-store loading")
        form.updateAddress("https://example.test")
        let invalidCalls = store.calls
        form.useSavedPassword(); form.forget(); form.password = secret
        suite.check(form.prepareSignIn() == nil && store.calls == invalidCalls, "invalid gateway scope cannot touch even the mocked store")
    }

    @MainActor private static func apiKeyLifecycle(_ suite: CredentialSuite) {
        let store = MockCredentialStore()
        let apiService = "fixture.app.credentials.opencellid-api-key.v1"
        let apiScope = ScopedCredentialScope(service: apiService, account: "https://opencellid.org")
        let form = TMobileOpenCellIDCredentialForm(store: store, service: apiService)
        suite.check(store.calls == 0 && form.token.isEmpty && !form.validToken, "opening the API key form performs no credential or provider access")
        for invalid in ["", "contains space", "line\nbreak", "nonascii-é", String(repeating: "x", count: 8_193)] {
            form.token = invalid; form.saveKey()
            suite.check(!form.validToken && store.calls == 0, "invalid API keys never reach even the mocked store")
        }
        let apiKey = "synthetic-api-key-value"
        form.token = apiKey
        suite.check(form.validToken && form.token == apiKey && store.calls == 0, "typing and local API key validation preserve the exact key without storage")
        form.saveKey()
        suite.check(store.values[apiScope] == apiKey && store.writes == 1 && form.token == apiKey, "explicit Save API key persists only the exact provider scope and preserves typed input")
        suite.check(form.message?.contains("saved") == true && form.message?.contains("has not validated") == true
                    && form.message?.contains(apiKey) == false, "save reports local persistence without claiming provider validity or exposing the key")
        form.token = "different-synthetic-api-key"
        suite.check(form.message == nil && form.token == "different-synthetic-api-key" && store.writes == 1,
                    "editing an API key clears stale saved-status text without silently saving the new value")
        let calls = store.calls
        form.clearVolatile()
        suite.check(form.token.isEmpty && form.message == nil && store.calls == calls && store.values[apiScope] == apiKey,
                    "closing the API key form clears memory only and retains the saved record")
        form.useSavedKey()
        suite.check(form.token == apiKey && form.validToken && store.reads == 1, "explicit Use saved key loads exactly the provider record")
        suite.check(form.message?.contains("manual") == true, "loading a saved API key never implies an automatic lookup")
        let otherApp = TMobileOpenCellIDCredentialForm(store: store, service: "other.app.credentials.opencellid-api-key.v1")
        otherApp.useSavedKey()
        suite.check(otherApp.token.isEmpty && otherApp.message?.contains("No API key") == true, "another app namespace cannot load this provider key")
        store.values[scope()!] = secret
        form.forgetKey()
        suite.check(form.token.isEmpty && store.values[apiScope] == nil && store.values[scope()!] == secret,
                    "Forget saved key clears memory and deletes only the provider item, preserving gateway credentials")
        suite.check(form.message?.contains("forgotten") == true, "successful API key deletion reports its exact purpose")
        form.useSavedKey()
        suite.check(form.token.isEmpty && form.message?.contains("No API key") == true, "missing provider credentials leave the secure field empty")
        store.values[apiScope] = "invalid saved key"
        form.useSavedKey()
        suite.check(form.token.isEmpty && !form.validToken && form.message?.contains("unavailable") == true, "invalid saved API keys cannot become lookup input")
        store.error = ScopedCredentialStoreError.unavailable
        form.token = apiKey; form.saveKey()
        suite.check(form.token == apiKey && form.message?.contains("could not be saved") == true
                    && form.message?.contains(apiKey) == false, "Keychain save failures preserve typed API input and report no secret")
        form.useSavedKey()
        suite.check(form.token.isEmpty && form.message?.contains("Keychain is unavailable") == true, "failed saved-key loading cannot leave previous input behind")
        form.token = apiKey; form.forgetKey()
        suite.check(form.token.isEmpty && form.message?.contains("could not be forgotten") == true, "failed API key deletion clears volatile input without claiming successful removal")
        let failures = store.calls
        form.clearVolatile()
        suite.check(store.calls == failures, "clearing API key memory never retries a denied Keychain operation")
        form.token = String(repeating: "a", count: 8_192)
        suite.check(form.validToken, "API key form uses the provider support boundary at the accepted maximum")
    }

    private static func exact(_ query: [String: Any], _ scope: ScopedCredentialScope) -> Bool {
        query[kSecClass as String] as? String == kSecClassGenericPassword as String
            && query[kSecAttrService as String] as? String == scope.service
            && query[kSecAttrAccount as String] as? String == scope.account
            && query[kSecAttrSynchronizable as String] as? Bool == false
            && query[kSecAttrAccessGroup as String] == nil
            && query[kSecAttrSynchronizable as String] as? String != kSecAttrSynchronizableAny as String
    }
    private static func fails(_ operation: () throws -> Void) -> Bool {
        do { try operation(); return false } catch { return true }
    }
}

private final class CredentialSuite {
    var checks = 0
    var failures = 0
    func check(_ condition: @autoclosure () -> Bool, _ label: String) {
        checks += 1
        if !condition() { failures += 1; print("FAIL: \(label)") }
    }
}

private final class MockKeychainAccess: ScopedCredentialKeychainAccess {
    var reads: [[String: Any]] = []
    var adds: [[String: Any]] = []
    var updates: [([String: Any], [String: Any])] = []
    var deletes: [[String: Any]] = []
    var readResult: (OSStatus, Data?) = (errSecItemNotFound, nil)
    var updateResults: [OSStatus] = []
    var addResult = errSecSuccess
    var deleteResult = errSecSuccess
    var callCount: Int { reads.count + adds.count + updates.count + deletes.count }
    func copyMatching(_ query: [String: Any]) -> (OSStatus, Data?) { reads.append(query); return readResult }
    func add(_ attributes: [String: Any]) -> OSStatus { adds.append(attributes); return addResult }
    func update(_ query: [String: Any], attributes: [String: Any]) -> OSStatus {
        updates.append((query, attributes)); return updateResults.isEmpty ? errSecSuccess : updateResults.removeFirst()
    }
    func delete(_ query: [String: Any]) -> OSStatus { deletes.append(query); return deleteResult }
}

private final class MockCredentialStore: ScopedCredentialStore {
    var values: [ScopedCredentialScope: String] = [:]
    var reads = 0, writes = 0, deletes = 0
    var calls: Int { reads + writes + deletes }
    var error: Error?
    func read(scope: ScopedCredentialScope) throws -> String? { reads += 1; if let error { throw error }; return values[scope] }
    func save(_ secret: String, scope: ScopedCredentialScope) throws { writes += 1; if let error { throw error }; values[scope] = secret }
    func delete(scope: ScopedCredentialScope) throws { deletes += 1; if let error { throw error }; values.removeValue(forKey: scope) }
}
