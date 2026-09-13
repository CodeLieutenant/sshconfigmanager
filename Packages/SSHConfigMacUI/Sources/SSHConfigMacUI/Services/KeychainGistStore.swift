import Foundation
import SSHConfigSync
import Security

struct KeychainGistStore: GistSecretStoring {
    private static let service = AppIdentity.scoped("gist")
    private static let tokenAccount = "access-token"
    private static let passphraseAccount = "encryption-passphrase"

    private func baseQuery(account: String, dataProtection: Bool) -> [String: Any] {
        var q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: account,
        ]
        if dataProtection { q[kSecUseDataProtectionKeychain as String] = true }
        return q
    }

    private func withFallback(_ op: (_ dataProtection: Bool) -> OSStatus) -> OSStatus {
        let status = op(true)
        return status == errSecMissingEntitlement ? op(false) : status
    }

    private func save(_ value: String, account: String) throws {
        let data = Data(value.utf8)
        let status = withFallback { dp in
            let update = SecItemUpdate(
                baseQuery(account: account, dataProtection: dp) as CFDictionary,
                [kSecValueData as String: data] as CFDictionary)
            if update == errSecSuccess { return errSecSuccess }
            if update == errSecMissingEntitlement { return update }

            var add = baseQuery(account: account, dataProtection: dp)
            add[kSecValueData as String] = data
            add[kSecAttrLabel as String] = "SSH Config Manager gist sync: \(account)"
            if dp { add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock }
            return SecItemAdd(add as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw KeychainGistStoreError.keychain(status) }
    }

    private func load(account: String) -> String? {
        var found: Data?
        _ = withFallback { dp in
            var query = baseQuery(account: account, dataProtection: dp)
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            var result: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            if status == errSecSuccess { found = result as? Data }
            return status
        }
        return found.map { String(decoding: $0, as: UTF8.self) }
    }

    private func remove(account: String) {
        _ = withFallback { dp in SecItemDelete(baseQuery(account: account, dataProtection: dp) as CFDictionary) }
    }

    func saveToken(_ token: String) throws { try save(token, account: Self.tokenAccount) }
    func token() -> String? { load(account: Self.tokenAccount) }
    func removeToken() { remove(account: Self.tokenAccount) }

    func savePassphrase(_ passphrase: String) throws { try save(passphrase, account: Self.passphraseAccount) }
    func passphrase() -> String? { load(account: Self.passphraseAccount) }
    func removePassphrase() { remove(account: Self.passphraseAccount) }
}

enum KeychainGistStoreError: LocalizedError {
    case keychain(OSStatus)
    var errorDescription: String? {
        switch self {
        case .keychain(let status):
            let message = SecCopyErrorMessageString(status, nil) as String? ?? "status \(status)"
            return "Couldn't save to the Keychain: \(message)"
        }
    }
}
