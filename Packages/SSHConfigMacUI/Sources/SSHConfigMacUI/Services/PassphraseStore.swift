//
//  PassphraseStore.swift
//  sshconfigmanager
//
//  Persists SSH key passphrases so a key can be re-loaded into the agent after a
//  reboot — our sandbox-safe equivalent of `ssh-add --apple-use-keychain`. We
//  can't write Apple's private `com.apple.ssh.passphrases` keychain group, so we
//  keep passphrases in *our own* data-protection keychain group and re-inject the
//  keys into the running agent at login (see ConfigStore.reloadPersistedAgentKeys
//  + LoginItemManager). Behind a protocol so the remember/forget/reload logic is
//  testable without a signed keychain (unsigned test builds can't use it).
//
//  Robustness: if the data-protection keychain isn't authorized (e.g. an ad-hoc or
//  improperly-provisioned build whose entitlement didn't resolve → errSecMissingEntitlement),
//  we transparently fall back to the legacy file keychain so the feature still works
//  instead of erroring. A given environment consistently uses one backend, so reads
//  always find what writes stored.
//

import Foundation
import Security

/// Stores/loads key passphrases keyed by the key's identity-file path. A nil
/// passphrase means "remembered, but the key is unencrypted" (stored as an empty
/// string) so the reload still knows to load it.
protocol PassphraseStoring: Sendable {
    /// Stores (or replaces) the passphrase for `keyPath`. Pass "" for unencrypted keys.
    func store(passphrase: String, forKeyPath keyPath: String) throws
    /// The stored passphrase for `keyPath`, or nil if none is remembered.
    func passphrase(forKeyPath keyPath: String) -> String?
    /// Removes any stored passphrase for `keyPath` (no-op if absent).
    func remove(forKeyPath keyPath: String)
    /// All key paths that currently have a remembered passphrase.
    func allKeyPaths() -> [String]
}

/// The production store, backed by the macOS data-protection keychain.
struct KeychainPassphraseStore: PassphraseStoring {
    /// Distinct from Apple's "OpenSSH" service so we never collide with the system
    /// `ssh-add --apple-use-keychain` items.
    private static let service = AppIdentity.scoped("ssh-passphrase")

    private func baseQuery(forKeyPath keyPath: String, dataProtection: Bool) -> [String: Any] {
        var q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: keyPath,
        ]
        if dataProtection { q[kSecUseDataProtectionKeychain as String] = true }
        return q
    }

    /// Runs a keychain op against the data-protection keychain; if it's not
    /// authorized on this build, retries against the legacy file keychain so the
    /// feature degrades gracefully instead of erroring.
    private func withFallback(_ op: (_ dataProtection: Bool) -> OSStatus) -> OSStatus {
        let status = op(true)
        return status == errSecMissingEntitlement ? op(false) : status
    }

    func store(passphrase: String, forKeyPath keyPath: String) throws {
        let data = Data(passphrase.utf8)
        let status = withFallback { dp in
            // Replace if present: try update first, then add.
            let update = SecItemUpdate(
                baseQuery(forKeyPath: keyPath, dataProtection: dp) as CFDictionary,
                [kSecValueData as String: data] as CFDictionary)
            if update == errSecSuccess { return errSecSuccess }
            if update == errSecMissingEntitlement { return update } // trigger fallback

            var add = baseQuery(forKeyPath: keyPath, dataProtection: dp)
            add[kSecValueData as String] = data
            add[kSecAttrLabel as String] = "SSH agent passphrase: \(keyPath)"
            if dp { add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock }
            return SecItemAdd(add as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw PassphraseStoreError.keychain(status) }
    }

    func passphrase(forKeyPath keyPath: String) -> String? {
        var found: Data?
        _ = withFallback { dp in
            var query = baseQuery(forKeyPath: keyPath, dataProtection: dp)
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            var result: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            if status == errSecSuccess { found = result as? Data }
            return status
        }
        return found.map { String(decoding: $0, as: UTF8.self) }
    }

    func remove(forKeyPath keyPath: String) {
        _ = withFallback { dp in SecItemDelete(baseQuery(forKeyPath: keyPath, dataProtection: dp) as CFDictionary) }
    }

    func allKeyPaths() -> [String] {
        var names: [String] = []
        _ = withFallback { dp in
            var query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: Self.service,
                kSecReturnAttributes as String: true,
                kSecMatchLimit as String: kSecMatchLimitAll,
            ]
            if dp { query[kSecUseDataProtectionKeychain as String] = true }
            var result: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            if status == errSecSuccess, let items = result as? [[String: Any]] {
                names = items.compactMap { $0[kSecAttrAccount as String] as? String }
            }
            return status
        }
        return names
    }
}

enum PassphraseStoreError: LocalizedError {
    case keychain(OSStatus)
    var errorDescription: String? {
        switch self {
        case .keychain(let status):
            let message = SecCopyErrorMessageString(status, nil) as String? ?? "status \(status)"
            return "Couldn't save the passphrase to the Keychain: \(message)"
        }
    }
}
