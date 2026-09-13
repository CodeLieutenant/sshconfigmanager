import Crypto
import Foundation
import _CryptoExtras

public enum GistCrypto {
    public struct Envelope: Codable, Sendable, Equatable {
        public var v: Int
        public var kdf: String
        public var iter: Int
        public var salt: String
        public var nonce: String
        public var ct: String

        public init(v: Int, kdf: String, iter: Int, salt: String, nonce: String, ct: String) {
            self.v = v
            self.kdf = kdf
            self.iter = iter
            self.salt = salt
            self.nonce = nonce
            self.ct = ct
        }
    }

    public enum Failure: Error, LocalizedError {
        case badPassphrase
        case malformed
        case unsupportedVersion(Int)

        public var errorDescription: String? {
            switch self {
            case .badPassphrase: return "That passphrase doesn't unlock this gist."
            case .malformed: return "The gist's encrypted contents are malformed."
            case .unsupportedVersion(let v): return "This gist was encrypted by a newer version of the app (v\(v))."
            }
        }
    }

    public static let currentVersion = 1
    public static let iterations = 210_000

    public static func encrypt(_ manifest: GistSyncManifest, passphrase: String) throws -> Envelope {
        let plaintext = try JSONEncoder().encode(manifest)
        var salt = Data(count: 16)
        _ = salt.withUnsafeMutableBytes { secRandomFill($0) }
        let key = try KDF.Insecure.PBKDF2.deriveKey(
            from: Data(passphrase.utf8), salt: salt, using: .sha256, outputByteCount: 32, rounds: iterations)
        let sealed = try AES.GCM.seal(plaintext, using: key)
        guard let combined = sealed.combined, combined.count > 12 else { throw Failure.malformed }
        let nonce = combined.prefix(12)
        let ciphertextAndTag = combined.dropFirst(12)
        return Envelope(
            v: currentVersion, kdf: "pbkdf2-sha256", iter: iterations,
            salt: salt.base64EncodedString(), nonce: Data(nonce).base64EncodedString(),
            ct: Data(ciphertextAndTag).base64EncodedString())
    }

    public static func decrypt(_ envelope: Envelope, passphrase: String) throws -> GistSyncManifest {
        guard envelope.v == currentVersion else { throw Failure.unsupportedVersion(envelope.v) }
        guard let salt = Data(base64Encoded: envelope.salt),
            let nonceData = Data(base64Encoded: envelope.nonce),
            let ciphertextAndTag = Data(base64Encoded: envelope.ct)
        else { throw Failure.malformed }
        let key = try KDF.Insecure.PBKDF2.deriveKey(
            from: Data(passphrase.utf8), salt: salt, using: .sha256, outputByteCount: 32, rounds: envelope.iter)
        do {
            let sealedBox = try AES.GCM.SealedBox(combined: nonceData + ciphertextAndTag)
            let plaintext = try AES.GCM.open(sealedBox, using: key)
            return try JSONDecoder().decode(GistSyncManifest.self, from: plaintext)
        } catch {
            throw Failure.badPassphrase
        }
    }
}

#if canImport(Security)
    import Security

    private func secRandomFill(_ buffer: UnsafeMutableRawBufferPointer) -> Int32 {
        SecRandomCopyBytes(kSecRandomDefault, buffer.count, buffer.baseAddress!)
    }
#else
    private func secRandomFill(_ buffer: UnsafeMutableRawBufferPointer) -> Int32 {
        var generator = SystemRandomNumberGenerator()
        for i in buffer.indices { buffer[i] = UInt8.random(in: 0...255, using: &generator) }
        return 0
    }
#endif
