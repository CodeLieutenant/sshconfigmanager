import Foundation
import SSHConfigCore
import Testing

@testable import SSHManagerUI

@Suite("Include expansion")
struct ConfigGraphLoaderTests {
    /// ssh resolves a relative Include against ~/.ssh and expands globs. If this
    /// breaks, hosts silently disappear from the sidebar.
    @Test("a relative include with a glob resolves against ~/.ssh")
    func relativeGlob() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("sshmanager-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let included = directory.appendingPathComponent("work.conf")
        try "Host work\n    HostName work.example.com\n".write(
            to: included, atomically: true, encoding: .utf8)

        let resolved = ConfigGraphLoader.resolve(directory.path + "/*.conf")
        #expect(resolved == [included.path])
    }

    @Test("a directory matching the glob is skipped")
    func skipsDirectories() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("sshmanager-\(UUID().uuidString)")
        let nested = directory.appendingPathComponent("nested.conf")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        #expect(ConfigGraphLoader.resolve(directory.path + "/*.conf").isEmpty)
    }
}

@Suite("Lossless editing")
struct LosslessEditTests {
    /// The whole promise of the editor: change one value, and every comment,
    /// blank line and indent in the rest of the file survives byte for byte.
    @Test("editing one value leaves every other line untouched")
    func preservesEverythingElse() throws {
        let original = """
            # A comment that must survive
            Host web
            \tHostName old.example.com
            \tPort  2222

            # Another block
            Host db
                HostName db.example.com
            """
        let url = URL(fileURLWithPath: "/tmp/sshmanager-test-config")
        var document = SSHConfigParser.parse(original, sourceURL: url)
        document.blocks[0].setValue("new.example.com", for: "HostName")

        let result = SSHConfigSerializer.serialize(document)
        #expect(result.contains("# A comment that must survive"))
        #expect(result.contains("# Another block"))
        #expect(result.contains("\tPort  2222"))
        #expect(result.contains("    HostName db.example.com"))
        #expect(result.contains("new.example.com"))
        #expect(!result.contains("old.example.com"))
    }

    @Test("an untouched document serializes back byte for byte")
    func roundTrip() {
        let original = "# hi\nHost a\n\tHostName a.example.com\n\n\n# trailing comment\n"
        let document = SSHConfigParser.parse(
            original, sourceURL: URL(fileURLWithPath: "/tmp/x"))
        #expect(SSHConfigSerializer.serialize(document) == original)
    }
}
