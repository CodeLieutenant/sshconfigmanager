import Foundation
import SSHConfigCore
import SSHConfigServices

/// One key on disk, with the facts the key screens show. `SSHPublicKey` carries
/// the identity of a key. The size, the passphrase state and the file modes need
/// the files themselves, and the services layer does no I/O by design, so they
/// are gathered here and carried alongside.
public struct SSHKeyEntry: Identifiable, Equatable {
    public let key: SSHPublicKey
    public let rsaBits: Int?
    public let isEncrypted: Bool?
    public let privateKeyMode: Int?
    public let publicKeyMode: Int?

    public var id: UUID { key.id }
    public var name: String { key.name }
    public var fingerprint: String { key.fingerprint }
    public var comment: String { key.comment }
    public var typeLabel: String { key.typeLabel }

    /// The path a `Host` block would name in `IdentityFile`.
    public var path: String {
        (key.privateKeyURL ?? key.publicKeyURL)?.path ?? ""
    }

    public var abbreviatedPath: String {
        key.identityFilePath(relativeTo: SSHDirectory.home)
    }

    /// Ed25519 and ECDSA carry their size in the algorithm name. Only RSA has to
    /// be measured, and only from a public key blob.
    public var sizeLabel: String {
        if let rsaBits { return "\(typeLabel) \(rsaBits)" }
        return typeLabel
    }

    public var randomart: String? {
        guard let digest = RandomArt.digest(fromSHA256Fingerprint: key.fingerprint) else {
            return nil
        }
        let bits = rsaBits.map { " \($0)" } ?? ""
        return RandomArt.drunkenBishop(
            digest: digest,
            title: "\(key.typeLabel.uppercased())\(bits)",
            hashName: "SHA256"
        )
    }

    var auditInput: KeyAuditor.KeyInput {
        .init(
            key: key,
            rsaBits: rsaBits,
            isEncrypted: isEncrypted,
            privateKeyMode: privateKeyMode,
            publicKeyMode: publicKeyMode
        )
    }
}

public enum SSHKeyScanner {
    /// Reads every key in ~/.ssh. Returns an empty list rather than an error when
    /// the directory cannot be read — the Grant access screen already reports that.
    public static func scan(directory: String = SSHDirectory.defaultPath) -> [SSHKeyEntry] {
        let url = URL(fileURLWithPath: directory)
        let files =
            (try? FileManager.default.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: nil
            )) ?? []
        let keys = SSHKeyService.discoverKeys(files: files, readText: readText)
        return keys.map { key in
            let pem = key.privateKeyURL.flatMap(readText)
            return SSHKeyEntry(
                key: key,
                rsaBits: key.publicKeyURL.flatMap(readText).flatMap(SSHKeyService.rsaBitsFromPubFile),
                isEncrypted: pem.flatMap(SSHKeyService.privateKeyEncrypted),
                privateKeyMode: key.privateKeyURL.flatMap(mode),
                publicKeyMode: key.publicKeyURL.flatMap(mode)
            )
        }
    }

    /// Key findings for the Issues screen: weak algorithms, loose permissions,
    /// keys with no passphrase, keys no host refers to.
    public static func audit(keys: [SSHKeyEntry], documents: [SSHConfigDocument]) -> [LintFinding] {
        KeyAuditor.audit(
            keys: keys.map(\.auditInput),
            documents: documents,
            sshDirectory: mode(URL(fileURLWithPath: SSHDirectory.defaultPath))
                .map { (path: SSHDirectory.defaultPath, mode: $0) }
        )
    }

    static func readText(_ url: URL) -> String? {
        try? String(contentsOf: url, encoding: .utf8)
    }

    static func mode(_ url: URL) -> Int? {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.posixPermissions] as? NSNumber)?.intValue
    }
}
