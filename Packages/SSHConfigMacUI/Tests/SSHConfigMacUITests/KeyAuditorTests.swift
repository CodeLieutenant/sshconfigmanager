//
//  KeyAuditorTests.swift
//  sshconfigmanagerTests
//
//  The pure key health audit: weak algorithms, file permissions, missing
//  passphrases, orphaned keys, and the RSA bit-length decoder.
//

import Foundation
import SSHConfigCore
import Testing

@testable import SSHConfigMacUI

private let configURL = URL(fileURLWithPath: "/tmp/config")
private let sshDir = URL(fileURLWithPath: "/Users/test/.ssh", isDirectory: true)

private func key(
    _ name: String, algorithm: String,
    hasPublic: Bool = true, hasPrivate: Bool = true
) -> SSHPublicKey {
    SSHPublicKey(
        id: UUID(),
        publicKeyURL: hasPublic ? sshDir.appendingPathComponent("\(name).pub") : nil,
        privateKeyURL: hasPrivate ? sshDir.appendingPathComponent(name) : nil,
        algorithm: algorithm, fingerprint: "SHA256:x", comment: "")
}

private func doc(_ text: String) -> SSHConfigDocument {
    SSHConfigParser.parse(text, sourceURL: configURL)
}

struct KeyAuditorTests {

    // MARK: - Weak algorithms

    @Test func dsaIsAnError() {
        let input = KeyAuditor.KeyInput(key: key("id_dsa", algorithm: "ssh-dss"))
        let findings = KeyAuditor.audit(keys: [input], documents: [])
        let dsa = findings.first { $0.title.contains("DSA") }
        #expect(dsa?.severity == .error)
    }

    @Test func smallRSAIsAnError() {
        let input = KeyAuditor.KeyInput(key: key("id_rsa", algorithm: "ssh-rsa"), rsaBits: 1024)
        let f = KeyAuditor.audit(keys: [input], documents: []).first { $0.title.contains("RSA") }
        #expect(f?.severity == .error)
    }

    @Test func rsa2048IsAWarning() {
        let input = KeyAuditor.KeyInput(key: key("id_rsa", algorithm: "ssh-rsa"), rsaBits: 2048)
        let f = KeyAuditor.audit(keys: [input], documents: []).first { $0.title.contains("RSA") }
        #expect(f?.severity == .warning)
    }

    @Test func rsa4096IsClean() {
        let input = KeyAuditor.KeyInput(key: key("id_rsa", algorithm: "ssh-rsa"), rsaBits: 4096)
        let findings = KeyAuditor.audit(keys: [input], documents: [])
        #expect(!findings.contains { $0.title.contains("RSA key") })
    }

    @Test func ed25519HasNoAlgorithmFinding() {
        let input = KeyAuditor.KeyInput(
            key: key("id_ed25519", algorithm: "ssh-ed25519"),
            isEncrypted: true, privateKeyMode: 0o600, publicKeyMode: 0o644)
        // Referenced so it isn't flagged orphaned either.
        let findings = KeyAuditor.audit(keys: [input], documents: [])
        #expect(findings.isEmpty)
    }

    @Test func nistP256IsInfo() {
        let input = KeyAuditor.KeyInput(
            key: key("ec", algorithm: "ecdsa-sha2-nistp256"),
            isEncrypted: true, privateKeyMode: 0o600)
        let f = KeyAuditor.audit(keys: [input], documents: []).first { $0.title.contains("P-256") }
        #expect(f?.severity == .info)
    }

    // MARK: - Permissions

    @Test func loosePrivateKeyPermsWarnsAndOffersFix() {
        let k = key("id_ed25519", algorithm: "ssh-ed25519")
        let input = KeyAuditor.KeyInput(key: k, isEncrypted: true, privateKeyMode: 0o644)
        let f = KeyAuditor.audit(keys: [input], documents: []).first { $0.title.contains("Private key") }
        #expect(f?.severity == .warning)
        #expect(f?.fix == .setPermissions(path: k.privateKeyURL!.path, mode: 0o600, label: "Fix to 0600"))
    }

    @Test func correctPrivateKeyPermsAreClean() {
        let input = KeyAuditor.KeyInput(
            key: key("id_ed25519", algorithm: "ssh-ed25519"),
            isEncrypted: true, privateKeyMode: 0o600)
        let findings = KeyAuditor.audit(keys: [input], documents: [])
        #expect(!findings.contains { $0.fix != nil })
    }

    // MARK: - Missing passphrase (#33: unknown must not read as "unencrypted")

    @Test func unencryptedKeyWarnsNoPassphrase() {
        let input = KeyAuditor.KeyInput(
            key: key("id_ed25519", algorithm: "ssh-ed25519"),
            isEncrypted: false, privateKeyMode: 0o600)
        let f = KeyAuditor.audit(keys: [input], documents: []).first { $0.title.contains("no passphrase") }
        #expect(f?.severity == .warning)
    }

    @Test func unparseableKeyDoesNotWarnNoPassphrase() {
        // isEncrypted == nil means the PEM couldn't be parsed at all; it must NOT be
        // audited as "has no passphrase" (a false alarm on a corrupt/unknown key file).
        let input = KeyAuditor.KeyInput(
            key: key("id_ed25519", algorithm: "ssh-ed25519"),
            isEncrypted: nil, privateKeyMode: 0o600)
        let findings = KeyAuditor.audit(keys: [input], documents: [])
        #expect(!findings.contains { $0.title.contains("no passphrase") })
    }

    @Test func worldWritablePublicKeyWarns() {
        let input = KeyAuditor.KeyInput(
            key: key("id_ed25519", algorithm: "ssh-ed25519"),
            isEncrypted: true, privateKeyMode: 0o600, publicKeyMode: 0o666)
        let f = KeyAuditor.audit(keys: [input], documents: []).first { $0.title.contains("Public key") }
        #expect(
            f?.fix
                == .setPermissions(
                    path: input.key.publicKeyURL!.path, mode: 0o644, label: "Fix to 0644"))
    }

    @Test func looseDirectoryWarnsAndOffersFix() {
        let findings = KeyAuditor.audit(
            keys: [], documents: [],
            sshDirectory: (path: sshDir.path, mode: 0o755))
        let f = findings.first { $0.title.contains("SSH folder") }
        #expect(f?.fix == .setPermissions(path: sshDir.path, mode: 0o700, label: "Fix to 0700"))
    }

    @Test func tightDirectoryIsClean() {
        let findings = KeyAuditor.audit(
            keys: [], documents: [],
            sshDirectory: (path: sshDir.path, mode: 0o700))
        #expect(findings.isEmpty)
    }

    // MARK: - Passphrase

    @Test func unencryptedPrivateKeyWarns() {
        let input = KeyAuditor.KeyInput(
            key: key("id_ed25519", algorithm: "ssh-ed25519"),
            isEncrypted: false, privateKeyMode: 0o600)
        let f = KeyAuditor.audit(keys: [input], documents: []).first { $0.title.contains("no passphrase") }
        #expect(f?.severity == .warning)
    }

    @Test func unknownEncryptionDoesNotWarn() {
        let input = KeyAuditor.KeyInput(
            key: key("id_ed25519", algorithm: "ssh-ed25519"),
            isEncrypted: nil, privateKeyMode: 0o600)
        let findings = KeyAuditor.audit(keys: [input], documents: [])
        #expect(!findings.contains { $0.title.contains("passphrase") })
    }

    @Test func publicOnlyKeyHasNoPassphraseFinding() {
        let input = KeyAuditor.KeyInput(
            key: key("ext", algorithm: "ssh-ed25519", hasPrivate: false),
            isEncrypted: false)
        let findings = KeyAuditor.audit(keys: [input], documents: [])
        #expect(!findings.contains { $0.title.contains("passphrase") })
    }

    // MARK: - Orphaned keys

    @Test func unreferencedKeyIsOrphaned() {
        let input = KeyAuditor.KeyInput(
            key: key("work", algorithm: "ssh-ed25519"),
            isEncrypted: true, privateKeyMode: 0o600)
        let f = KeyAuditor.audit(keys: [input], documents: []).first { $0.title.contains("isn't used") }
        #expect(f?.severity == .info)
    }

    @Test func orphanedFindingOffersDeleteWithBothPaths() {
        let k = key("work", algorithm: "ssh-ed25519")
        let input = KeyAuditor.KeyInput(key: k, isEncrypted: true, privateKeyMode: 0o600)
        let f = KeyAuditor.audit(keys: [input], documents: []).first { $0.title.contains("isn't used") }
        #expect(
            f?.fix
                == .deleteOrphanedKey(
                    privateKeyPath: k.privateKeyURL!.path,
                    publicKeyPath: k.publicKeyURL!.path,
                    name: "work"))
    }

    @Test func weakKeyOffersGenerateReplacement() {
        // id_rsa is a default identity name, so it isn't also flagged orphaned.
        let input = KeyAuditor.KeyInput(
            key: key("id_rsa", algorithm: "ssh-rsa"),
            rsaBits: 1024, isEncrypted: true, privateKeyMode: 0o600)
        let f = KeyAuditor.audit(keys: [input], documents: []).first { $0.title.contains("RSA") }
        #expect(f?.fix == .generateReplacement(comment: "", originalName: "id_rsa"))
    }

    @Test func weakPublicOnlyKeyHasNoReplacementFix() {
        let input = KeyAuditor.KeyInput(
            key: key("id_rsa", algorithm: "ssh-rsa", hasPrivate: false),
            rsaBits: 1024)
        let f = KeyAuditor.audit(keys: [input], documents: []).first { $0.title.contains("RSA") }
        #expect(f?.severity == .error)
        #expect(f?.fix == nil)
    }

    @Test func referencedKeyIsNotOrphaned() {
        let documents = [doc("Host server\n    IdentityFile ~/.ssh/work\n")]
        let input = KeyAuditor.KeyInput(
            key: key("work", algorithm: "ssh-ed25519"),
            isEncrypted: true, privateKeyMode: 0o600)
        let findings = KeyAuditor.audit(keys: [input], documents: documents)
        #expect(!findings.contains { $0.title.contains("isn't used") })
    }

    @Test func defaultIdentityNamesAreNeverOrphaned() {
        let input = KeyAuditor.KeyInput(
            key: key("id_ed25519", algorithm: "ssh-ed25519"),
            isEncrypted: true, privateKeyMode: 0o600)
        let findings = KeyAuditor.audit(keys: [input], documents: [])
        #expect(!findings.contains { $0.title.contains("isn't used") })
    }

    @Test func identityFileWithPubSuffixStillMatches() {
        let documents = [doc("Host s\n    IdentityFile ~/.ssh/work.pub\n")]
        let names = KeyAuditor.referencedIdentityNames(documents)
        #expect(names.contains("work"))
    }

    // MARK: - RSA bit length decoder

    @Test func decodes2048() {
        #expect(KeyAuditor.rsaBitLength(blob: makeRSABlob(bits: 2048)) == 2048)
    }

    @Test func decodes4096() {
        #expect(KeyAuditor.rsaBitLength(blob: makeRSABlob(bits: 4096)) == 4096)
    }

    @Test func rejectsNonRSABlob() {
        var bytes = sshString(Array("ssh-ed25519".utf8))
        bytes += sshString([UInt8](repeating: 0xAB, count: 32))
        #expect(KeyAuditor.rsaBitLength(blob: bytes) == nil)
    }

    // MARK: - Category gating

    @Test func disablingPassphraseCategorySilencesItsFindings() {
        let input = KeyAuditor.KeyInput(
            key: key("id_ed25519", algorithm: "ssh-ed25519"),
            isEncrypted: false, privateKeyMode: 0o600)
        let findings = KeyAuditor.audit(
            keys: [input], documents: [],
            enabled: [.weakAlgorithm, .permissions, .orphan])
        #expect(!findings.contains { $0.title.contains("passphrase") })
    }

    @Test func disablingWeakAlgorithmCategorySilencesItsFindings() {
        let input = KeyAuditor.KeyInput(key: key("id_dsa", algorithm: "ssh-dss"))
        let findings = KeyAuditor.audit(
            keys: [input], documents: [],
            enabled: [.permissions, .passphrase, .orphan])
        #expect(!findings.contains { $0.title.contains("DSA") })
    }

    @Test func disablingPermissionsCategorySilencesDirectoryAndKeyFindings() {
        let input = KeyAuditor.KeyInput(
            key: key("id_ed25519", algorithm: "ssh-ed25519"),
            privateKeyMode: 0o644)
        let findings = KeyAuditor.audit(
            keys: [input], documents: [],
            sshDirectory: (path: sshDir.path, mode: 0o777),
            enabled: [.weakAlgorithm, .passphrase, .orphan])
        #expect(!findings.contains { $0.title.contains("loose permissions") })
        #expect(!findings.contains { $0.title.contains("SSH folder") })
    }

    @Test func disablingOrphanCategorySilencesItsFindings() {
        let input = KeyAuditor.KeyInput(key: key("stray", algorithm: "ssh-ed25519"))
        let findings = KeyAuditor.audit(
            keys: [input], documents: [],
            enabled: [.weakAlgorithm, .permissions, .passphrase])
        #expect(!findings.contains { $0.title.contains("isn't used") })
    }

    @Test func emptyEnabledSetProducesNoFindings() {
        let input = KeyAuditor.KeyInput(
            key: key("id_dsa", algorithm: "ssh-dss"),
            isEncrypted: false, privateKeyMode: 0o644)
        let findings = KeyAuditor.audit(
            keys: [input], documents: [],
            sshDirectory: (path: sshDir.path, mode: 0o777),
            enabled: [])
        #expect(findings.isEmpty)
    }

    @Test func defaultAuditEnablesEveryCategory() {
        let input = KeyAuditor.KeyInput(
            key: key("id_dsa", algorithm: "ssh-dss"),
            isEncrypted: false, privateKeyMode: 0o600)
        let findings = KeyAuditor.audit(keys: [input], documents: [])
        #expect(findings.contains { $0.title.contains("DSA") })
        #expect(findings.contains { $0.title.contains("passphrase") })
    }

    // Builds a minimal `ssh-rsa` wire blob with a modulus of exactly `bits` bits.
    private func makeRSABlob(bits: Int) -> [UInt8] {
        var modulus = [UInt8](repeating: 0, count: bits / 8)
        modulus[0] = 0x80 // top bit set → exactly `bits` bits
        var blob = sshString(Array("ssh-rsa".utf8))
        blob += sshString([0x01, 0x00, 0x01]) // e = 65537
        blob += sshString([0x00] + modulus) // mpint: leading 0x00 sign byte
        return blob
    }

    /// Length-prefixed SSH string from raw bytes.
    private func sshString(_ bytes: [UInt8]) -> [UInt8] {
        let n = UInt32(bytes.count)
        return [
            UInt8(n >> 24 & 0xFF), UInt8(n >> 16 & 0xFF),
            UInt8(n >> 8 & 0xFF), UInt8(n & 0xFF),
        ] + bytes
    }
}
