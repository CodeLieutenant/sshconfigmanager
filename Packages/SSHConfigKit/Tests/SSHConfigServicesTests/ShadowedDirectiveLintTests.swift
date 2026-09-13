import Foundation
import Testing

@testable import SSHConfigCore

@Suite("Shadowed directive lint")
struct ShadowedDirectiveLintTests {
    private func document(_ text: String, name: String = "config") -> SSHConfigDocument {
        SSHConfigParser.parse(text, sourceURL: URL(filePath: "/tmp/\(name)"))
    }

    private func findings(_ documents: [SSHConfigDocument]) -> [LintFinding] {
        ConfigLinter.lint(documents)
    }

    @Test func duplicatePortInOneBlockNamesTheWinner() {
        let found = findings([
            document(
                """
                Host k3s
                    Port 9999
                    Port 2222
                """)
        ])
        let shadow = found.first { $0.title.contains("Port is set twice") }
        #expect(shadow != nil)
        #expect(shadow?.severity == .warning)
        #expect(shadow?.detail.contains("9999") == true)
        #expect(shadow?.detail.contains("ssh -G k3s") == true)
    }

    @Test func identicalDuplicateIsNotWorthAWarning() {
        let found = findings([
            document(
                """
                Host k3s
                    Port 2222
                    Port 2222
                """)
        ])
        #expect(!found.contains { $0.title.contains("set twice") })
    }

    @Test func repeatableKeywordsNeverShadow() {
        let found = findings([
            document(
                """
                Host k3s
                    IdentityFile ~/.ssh/a
                    IdentityFile ~/.ssh/b
                    LocalForward 8080 localhost:80
                    LocalForward 9090 localhost:90
                """)
        ])
        #expect(!found.contains { $0.title.contains("set twice") })
    }

    @Test func earlierBlockInAnotherFileWinsAndIsNamed() {
        let included = document(
            """
            Host k3s
                Port 9999
            """, name: "included.conf")
        let local = document(
            """
            Host k3s
                Port 2222
            """, name: "config")
        let found = findings([included, local])
        let shadow = found.first { $0.title.contains("Port for “k3s” is already set earlier") }
        #expect(shadow != nil)
        #expect(shadow?.detail.contains("included.conf") == true)
        #expect(shadow?.detail.contains("9999") == true)
        #expect(shadow?.blockID == local.blocks.first?.id)
    }

    @Test func reversingTheOrderMovesTheWinner() {
        let included = document(
            """
            Host k3s
                Port 9999
            """, name: "included.conf")
        let local = document(
            """
            Host k3s
                Port 2222
            """, name: "config")
        let found = findings([local, included])
        let shadow = found.first { $0.title.contains("Port for “k3s” is already set earlier") }
        #expect(shadow?.detail.contains("2222") == true)
        #expect(shadow?.blockID == included.blocks.first?.id)
    }

    @Test func misspelledKeywordIsAnError() {
        let found = findings([
            document(
                """
                Host k3s
                    IdentityKey ~/.ssh/id_ed25519
                """)
        ])
        let unknown = found.first { $0.title.contains("Unknown option") }
        #expect(unknown?.severity == .error)
        #expect(unknown?.detail.contains("255") == true)
        #expect(unknown?.detail.contains("identitykey") == true)
    }

    @Test func ignoreUnknownSilencesTheError() {
        let found = findings([
            document(
                """
                Host k3s
                    IgnoreUnknown UseKeychain,Identity*
                    IdentityKey ~/.ssh/id_ed25519
                """)
        ])
        #expect(!found.contains { $0.title.contains("Unknown option") })
    }

    @Test func everyRegisteredKeywordPassesTheUnknownCheck() {
        let body = KeywordRegistry.all.map { "    \($0.canonical) x" }.joined(separator: "\n")
        let found = findings([document("Host k3s\n\(body)")])
        #expect(!found.contains { $0.title.contains("Unknown option") })
    }
}
