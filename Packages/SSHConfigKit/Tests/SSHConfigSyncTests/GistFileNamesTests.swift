import Testing

@testable import SSHConfigSync

@Suite("Gist file names")
struct GistFileNamesTests {
    @Test func noticeSortsFirstSoTheGistCarriesItsName() {
        let encrypted = [GistFileNames.notice, GistFileNames.encryptedManifest].sorted()
        let plaintext = [GistFileNames.notice, GistFileNames.plaintextManifest].sorted()
        #expect(encrypted.first == GistFileNames.notice)
        #expect(plaintext.first == GistFileNames.notice)
    }

    @Test func legacyNamesWouldHaveWonTheTitle() {
        let legacy = [GistFileNames.legacyNotice, GistFileNames.legacyEncryptedManifest].sorted()
        #expect(legacy.first == GistFileNames.legacyNotice)
        #expect(GistFileNames.notice > GistFileNames.legacyEncryptedManifest)
    }

    @Test func manifestLookupPrefersTheCurrentName() {
        let both = [
            GistFileNames.plaintextManifest: "new",
            GistFileNames.legacyPlaintextManifest: "old",
        ]
        #expect(GistFileNames.plaintextManifestContent(in: both) == "new")
        #expect(GistFileNames.plaintextManifestContent(in: [GistFileNames.legacyPlaintextManifest: "old"]) == "old")
    }

    @Test func encryptedLookupPrefersTheCurrentName() {
        let both = [
            GistFileNames.encryptedManifest: "new",
            GistFileNames.legacyEncryptedManifest: "old",
        ]
        #expect(GistFileNames.encryptedManifestContent(in: both) == "new")
        #expect(GistFileNames.encryptedManifestContent(in: [GistFileNames.legacyEncryptedManifest: "old"]) == "old")
    }

    @Test func pushingEncryptedDeletesEveryOtherFileIncludingTheOldReadme() {
        let written: Set<String> = [GistFileNames.encryptedManifest, GistFileNames.notice]
        let removed = GistFileNames.superseded(byWriting: written)
        #expect(removed.contains(GistFileNames.legacyNotice))
        #expect(removed.contains(GistFileNames.legacyEncryptedManifest))
        #expect(removed.contains(GistFileNames.legacyPlaintextManifest))
        #expect(removed.contains(GistFileNames.plaintextManifest))
        #expect(!removed.contains(GistFileNames.encryptedManifest))
        #expect(!removed.contains(GistFileNames.notice))
    }

    @Test func pushingPlaintextDeletesTheEncryptedManifest() {
        let written: Set<String> = [GistFileNames.plaintextManifest, GistFileNames.notice]
        let removed = GistFileNames.superseded(byWriting: written)
        #expect(removed.contains(GistFileNames.encryptedManifest))
        #expect(!removed.contains(GistFileNames.plaintextManifest))
    }
}
