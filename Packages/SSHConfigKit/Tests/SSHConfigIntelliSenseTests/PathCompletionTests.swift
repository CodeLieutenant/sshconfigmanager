import SSHConfigCore
import Testing

@testable import SSHConfigIntelliSense

/// An in-memory `FileSystemBrowsing` so path completion is testable without disk.
private struct FakeFS: FileSystemBrowsing {
    let homeDirectoryPath: String
    let baseDirectoryPath: String?
    /// Directory contents keyed by *normalized* absolute path.
    let entries: [String: [FileEntry]]

    func listDirectory(_ absolutePath: String) -> [FileEntry] {
        entries[PathCompletion.normalize(absolutePath)] ?? []
    }
}

private func sshFixture() -> FakeFS {
    FakeFS(
        homeDirectoryPath: "/Users/me",
        baseDirectoryPath: "/Users/me/.ssh",
        entries: [
            "/Users/me/.ssh": [
                FileEntry(name: "config", isDirectory: false),
                FileEntry(name: "id_ed25519", isDirectory: false),
                FileEntry(name: "id_ed25519.pub", isDirectory: false),
                FileEntry(name: "id_rsa", isDirectory: false),
                FileEntry(name: "known_hosts", isDirectory: false),
                FileEntry(name: ".hidden", isDirectory: false),
                FileEntry(name: "work", isDirectory: true),
            ],
            "/Users/me/.ssh/work": [
                FileEntry(name: "id_work", isDirectory: false)
            ],
        ])
}

@Suite struct PathCompletionPureTests {
    @Test func splitOnLastSlash() {
        #expect(PathCompletion.split("~/.ssh/id_e").directory == "~/.ssh/")
        #expect(PathCompletion.split("~/.ssh/id_e").namePrefix == "id_e")
        #expect(PathCompletion.split("id_e").directory == "")
        #expect(PathCompletion.split("id_e").namePrefix == "id_e")
    }

    @Test func resolveDirectoryExpandsTildeAndRelative() {
        let home = "/Users/me"
        let base = "/Users/me/.ssh"
        #expect(PathCompletion.resolveDirectory("~/.ssh/", home: home, base: base) == "/Users/me/.ssh/")
        #expect(PathCompletion.resolveDirectory("~", home: home, base: base) == "/Users/me")
        #expect(PathCompletion.resolveDirectory("/etc/", home: home, base: base) == "/etc/")
        #expect(PathCompletion.resolveDirectory("", home: home, base: base) == base)
        #expect(PathCompletion.resolveDirectory("sub/", home: home, base: base) == "/Users/me/.ssh/sub/")
    }

    @Test func normalizeCollapsesDotsAndSlashes() {
        #expect(PathCompletion.normalize("/Users/me/.ssh/") == "/Users/me/.ssh")
        #expect(PathCompletion.normalize("/Users/me/.ssh/../.ssh") == "/Users/me/.ssh")
        #expect(PathCompletion.normalize("/a//b/./c") == "/a/b/c")
    }

    @Test func isInsideConfinesToBase() {
        let base = "/Users/me/.ssh"
        #expect(PathCompletion.isInside("/Users/me/.ssh", base: base))
        #expect(PathCompletion.isInside("/Users/me/.ssh/work", base: base))
        #expect(!PathCompletion.isInside("/Users/me", base: base))
        #expect(!PathCompletion.isInside("/etc", base: base))
    }

    @Test func completeFiltersHiddenUnlessDotTyped() {
        let fs = sshFixture()
        let visible = PathCompletion.complete(value: "~/.ssh/", fileSystem: fs)
        #expect(visible?.candidates.contains { $0.value == ".hidden" } == false)

        let withDot = PathCompletion.complete(value: "~/.ssh/.h", fileSystem: fs)
        #expect(withDot?.candidates.contains { $0.value == ".hidden" } == true)
    }

    @Test func completeMarksFoldersWithTrailingSlash() {
        let fs = sshFixture()
        let result = PathCompletion.complete(value: "~/.ssh/", fileSystem: fs)
        let folder = result?.candidates.first { $0.kind == .folder }
        #expect(folder?.value == "work/")
    }

    @Test func completeOutsideGrantYieldsNothing() {
        let fs = sshFixture()
        let result = PathCompletion.complete(value: "/etc/pa", fileSystem: fs)
        #expect(result?.candidates.isEmpty == true)
    }
}

@Suite struct PathCompletionEngineTests {
    let engine = IntelliSenseEngine()

    private func complete(_ source: String, fileSystem: FileSystemBrowsing?) -> [CompletionItem] {
        let offset = source.utf16.distance(
            from: source.utf16.startIndex,
            to: source.firstIndex(of: "|")!.samePosition(in: source.utf16)!)
        let text = source.replacingOccurrences(of: "|", with: "")
        return engine.completions(in: text, utf16CursorOffset: offset, fileSystem: fileSystem)
    }

    @Test func identityFileListsKeysUnderSSH() {
        let items = complete("IdentityFile ~/.ssh/id|", fileSystem: sshFixture())
        #expect(items.contains { $0.label == "id_ed25519" && $0.kind == .file })
        #expect(items.contains { $0.label == "id_rsa" && $0.kind == .file })
    }

    @Test func pathReplaceCoversOnlyLastSegment() {
        let items = complete("IdentityFile ~/.ssh/id|", fileSystem: sshFixture())
        let key = items.first { $0.label == "id_ed25519" }
        // "~/.ssh/" stays on the line; only the typed "id" (length 2) is replaced.
        #expect(key?.replace.length == 2)
        #expect(key?.insertText == "id_ed25519")
    }

    @Test func emptyPathPrefixListsGrantedDirectory() {
        let items = complete("IdentityFile |", fileSystem: sshFixture())
        #expect(items.contains { $0.label == "config" })
        #expect(items.first?.isPreselected == true)
    }

    @Test func noProviderMeansNoPathCompletion() {
        // Without a filesystem, IdentityFile offers nothing (prior behaviour).
        #expect(complete("IdentityFile ~/.ssh/id|", fileSystem: nil).isEmpty)
    }

    @Test func identityAgentKeepsEnvTokensUntilPathTyped() {
        // A bare prefix still offers the env/none catalog…
        let envItems = complete("IdentityAgent SSH|", fileSystem: sshFixture())
        #expect(envItems.contains { $0.label == "SSH_AUTH_SOCK" })
        // …but a slash switches to filesystem completion.
        let pathItems = complete("IdentityAgent ~/.ssh/wo|", fileSystem: sshFixture())
        #expect(pathItems.contains { $0.label == "work/" && $0.kind == .folder })
    }
}

@Suite struct CompletionMetadataTests {
    let engine = IntelliSenseEngine()

    private func complete(_ source: String) -> [CompletionItem] {
        let offset = source.utf16.distance(
            from: source.utf16.startIndex,
            to: source.firstIndex(of: "|")!.samePosition(in: source.utf16)!)
        return engine.completions(
            in: source.replacingOccurrences(of: "|", with: ""),
            utf16CursorOffset: offset)
    }

    @Test func topItemIsPreselected() {
        let items = complete("Hos|")
        #expect(items.first?.isPreselected == true)
        // Exactly one preselected item per list.
        #expect(items.filter(\.isPreselected).count == 1)
    }

    @Test func matchedRangesCoverTypedCharacters() {
        let item = complete("Hos|").first { $0.label == "HostName" }
        #expect(item?.matchedRanges.isEmpty == false)
        // "Hos" matches the leading three characters contiguously → one range of length 3.
        #expect(item?.matchedRanges.first == ReplacementRange(location: 0, length: 3))
    }

    @Test func snippetsOfferedForForwarding() {
        let items = complete("LocalFor|")
        #expect(items.contains { $0.kind == .snippet && $0.insertText.hasPrefix("LocalForward 127.0.0.1") })
    }
}

@Suite struct FuzzyMatchIndexTests {
    @Test func matchReportsConsumedIndices() {
        let m = FuzzyMatch.match(query: "hn", candidate: "HostName")
        #expect(m?.matchedIndices == [0, 4]) // h…n in "hostname"
    }

    @Test func scoreStillAgreesWithMatch() {
        #expect(
            FuzzyMatch.score(query: "ciph", candidate: "Ciphers")
                == FuzzyMatch.match(query: "ciph", candidate: "Ciphers")?.score)
    }

    @Test func emptyQueryMatchesWithNoIndices() {
        let m = FuzzyMatch.match(query: "", candidate: "anything")
        #expect(m?.score == 0)
        #expect(m?.matchedIndices.isEmpty == true)
    }

    @Test func nonMatchReturnsNil() {
        #expect(FuzzyMatch.match(query: "zzz", candidate: "abc") == nil)
    }
}
