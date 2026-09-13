import Foundation
import SSHConfigSync
import Testing

struct GistSyncManifestTests {
    @Test func roundTripsThroughFiles() {
        let files: [(relPath: String, text: String)] = [
            ("config", "Host a\n    HostName a.example.com\n"),
            ("conf.d/work", "Host b\n    HostName b.example.com\n"),
        ]
        let manifest = GistSyncManifest.from(files: files, generator: "sshconfigmanager/1.1.0", now: Date())
        let roundTripped = manifest.toFiles()
        #expect(roundTripped.count == files.count)
        #expect(Set(roundTripped.map(\.relPath)) == Set(files.map(\.relPath)))
    }

    @Test func canonicalDataIsStableAcrossFileOrder() {
        let now = Date()
        let a = GistSyncManifest.from(
            files: [("config", "x"), ("conf.d/work", "y")], generator: "g", now: now)
        let b = GistSyncManifest.from(
            files: [("conf.d/work", "y"), ("config", "x")], generator: "g", now: now)
        #expect(a.canonicalData() == b.canonicalData())
        #expect(a.contentHash() == b.contentHash())
    }

    @Test func canonicalDataIgnoresUpdatedAt() {
        let a = GistSyncManifest.from(files: [("config", "x")], generator: "g", now: Date())
        let b = GistSyncManifest.from(files: [("config", "x")], generator: "g", now: Date().addingTimeInterval(3600))
        #expect(a.canonicalData() == b.canonicalData())
        #expect(a.contentHash() == b.contentHash())
    }

    @Test func differentContentHashesDiffer() {
        let a = GistSyncManifest.from(files: [("config", "x")], generator: "g", now: Date())
        let b = GistSyncManifest.from(files: [("config", "y")], generator: "g", now: Date())
        #expect(a.contentHash() != b.contentHash())
    }
}
