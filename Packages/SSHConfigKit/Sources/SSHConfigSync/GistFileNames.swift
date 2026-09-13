public enum GistFileNames {
    public static let notice = "sshmanager.app"
    public static let plaintextManifest = "sshmanager.config.json"
    public static let encryptedManifest = "sshmanager.config.enc"

    public static let legacyNotice = "README.md"
    public static let legacyPlaintextManifest = "sshconfigmanager.json"
    public static let legacyEncryptedManifest = "sshconfigmanager.enc"

    public static let noticeText =
        "This gist holds an SSH Config Manager backup (sshmanager.app). Do not edit it by hand."

    public static func plaintextManifestContent(in files: [String: String]) -> String? {
        files[plaintextManifest] ?? files[legacyPlaintextManifest]
    }

    public static func encryptedManifestContent(in files: [String: String]) -> String? {
        files[encryptedManifest] ?? files[legacyEncryptedManifest]
    }

    public static func superseded(byWriting written: Set<String>) -> [String] {
        [
            notice, plaintextManifest, encryptedManifest,
            legacyNotice, legacyPlaintextManifest, legacyEncryptedManifest,
        ]
        .filter { !written.contains($0) }
    }
}
