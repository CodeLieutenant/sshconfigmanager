import Crypto
import Foundation

public struct GistSyncManifest: Codable, Equatable, Sendable {
    public static let schemaVersion = 1

    public var schemaVersion: Int
    public var generator: String
    public var updatedAt: Date
    public var files: [Entry]

    public struct Entry: Codable, Equatable, Sendable {
        public var relPath: String
        public var content: String

        public init(relPath: String, content: String) {
            self.relPath = relPath
            self.content = content
        }
    }

    public init(schemaVersion: Int = GistSyncManifest.schemaVersion, generator: String, updatedAt: Date, files: [Entry])
    {
        self.schemaVersion = schemaVersion
        self.generator = generator
        self.updatedAt = updatedAt
        self.files = files
    }

    public static func from(
        files: [(relPath: String, text: String)], generator: String, now: Date
    ) -> GistSyncManifest {
        GistSyncManifest(
            generator: generator, updatedAt: now,
            files: files.map { Entry(relPath: $0.relPath, content: $0.text) })
    }

    public func toFiles() -> [(relPath: String, text: String)] {
        files.map { ($0.relPath, $0.content) }
    }

    public func canonicalData() -> Data {
        var canonical = self
        canonical.files.sort { $0.relPath < $1.relPath }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        struct Stable: Encodable {
            let schemaVersion: Int
            let generator: String
            let files: [Entry]
        }
        let stable = Stable(
            schemaVersion: canonical.schemaVersion, generator: canonical.generator, files: canonical.files)
        return (try? encoder.encode(stable)) ?? Data()
    }

    public func contentHash() -> String {
        SHA256.hash(data: canonicalData()).map { String(format: "%02x", $0) }.joined()
    }
}
