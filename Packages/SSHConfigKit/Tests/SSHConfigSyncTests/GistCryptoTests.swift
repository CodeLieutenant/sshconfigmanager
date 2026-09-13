import Foundation
import SSHConfigSync
import Testing

struct GistCryptoTests {
    private func manifest() -> GistSyncManifest {
        GistSyncManifest.from(
            files: [("config", "Host bastion\n    HostName 10.0.0.1\n")], generator: "test", now: Date())
    }

    @Test func encryptThenDecryptRoundTrips() throws {
        let original = manifest()
        let envelope = try GistCrypto.encrypt(original, passphrase: "correct horse battery staple")
        let decrypted = try GistCrypto.decrypt(envelope, passphrase: "correct horse battery staple")
        #expect(decrypted.toFiles().map(\.text) == original.toFiles().map(\.text))
    }

    @Test func wrongPassphraseFailsToDecrypt() throws {
        let envelope = try GistCrypto.encrypt(manifest(), passphrase: "right passphrase")
        #expect(throws: GistCrypto.Failure.self) {
            _ = try GistCrypto.decrypt(envelope, passphrase: "wrong passphrase")
        }
    }

    @Test func tamperedCiphertextFailsToDecrypt() throws {
        var envelope = try GistCrypto.encrypt(manifest(), passphrase: "a passphrase")
        var bytes = Data(base64Encoded: envelope.ct)!
        bytes[0] ^= 0xFF
        envelope.ct = bytes.base64EncodedString()
        #expect(throws: GistCrypto.Failure.self) {
            _ = try GistCrypto.decrypt(envelope, passphrase: "a passphrase")
        }
    }

    @Test func envelopeCarriesVersionAndKDF() throws {
        let envelope = try GistCrypto.encrypt(manifest(), passphrase: "p")
        #expect(envelope.v == GistCrypto.currentVersion)
        #expect(envelope.kdf == "pbkdf2-sha256")
        #expect(envelope.iter == GistCrypto.iterations)
    }

    @Test func futureVersionIsRejected() {
        let envelope = GistCrypto.Envelope(v: 99, kdf: "pbkdf2-sha256", iter: 210_000, salt: "", nonce: "", ct: "")
        #expect(throws: GistCrypto.Failure.self) {
            _ = try GistCrypto.decrypt(envelope, passphrase: "p")
        }
    }
}
