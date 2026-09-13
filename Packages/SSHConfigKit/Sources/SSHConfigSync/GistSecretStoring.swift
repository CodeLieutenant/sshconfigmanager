public protocol GistSecretStoring: Sendable {
    func saveToken(_ token: String) throws
    func token() -> String?
    func removeToken()
    func savePassphrase(_ passphrase: String) throws
    func passphrase() -> String?
    func removePassphrase()
}
