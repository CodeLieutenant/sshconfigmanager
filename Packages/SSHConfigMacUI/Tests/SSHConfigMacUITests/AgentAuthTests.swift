//
//  AgentAuthTests.swift
//  sshconfigmanagerTests
//
//  The pure "prefer agent, fall back to key" selection used by the in-process
//  engine to decide how each hop authenticates. (Live agent signing is covered by
//  the opt-in TunnelE2ETests.)
//

import Foundation
import SSHConfigCore
import Testing

@testable import SSHConfigMacUI

struct AgentAuthSelectionTests {
    private func identity(blob: [UInt8], type: String = "ssh-ed25519", comment: String = "k") -> AgentIdentity {
        AgentIdentity(keyBlob: blob, comment: comment, keyType: type)
    }

    /// Builds a `.pub` line whose base64 blob matches the given bytes.
    private func pubLine(blob: [UInt8], type: String = "ssh-ed25519") -> String {
        "\(type) \(Data(blob).base64EncodedString()) user@host\n"
    }

    @Test func noAgentIdentitiesFallsBackToKey() {
        let result = NIOTunnelEngine.matchingAgentIdentities(
            identityFileName: "id_ed25519", pubText: pubLine(blob: [1, 2, 3]), among: [])
        #expect(result == nil)
    }

    @Test func noIdentityFileOffersAllAgentKeys() {
        let ids = [identity(blob: [1]), identity(blob: [2])]
        let result = NIOTunnelEngine.matchingAgentIdentities(
            identityFileName: nil, pubText: nil, among: ids)
        #expect(result?.count == 2)
    }

    @Test func identityFileMatchesAgentKeyByBlob() {
        let target: [UInt8] = [9, 8, 7, 6]
        let ids = [identity(blob: [1, 1]), identity(blob: target)]
        let result = NIOTunnelEngine.matchingAgentIdentities(
            identityFileName: "id_ed25519", pubText: pubLine(blob: target), among: ids)
        #expect(result?.count == 1)
        #expect(result?.first?.keyBlob == target)
    }

    @Test func identityFileWithNoAgentMatchFallsBackToKey() {
        let ids = [identity(blob: [1]), identity(blob: [2])]
        let result = NIOTunnelEngine.matchingAgentIdentities(
            identityFileName: "id_ed25519", pubText: pubLine(blob: [3, 3, 3]), among: ids)
        #expect(result == nil) // a specific key was requested; agent doesn't hold it
    }

    @Test func missingPubTextFallsBackToKey() {
        let ids = [identity(blob: [1])]
        let result = NIOTunnelEngine.matchingAgentIdentities(
            identityFileName: "id_ed25519", pubText: nil, among: ids)
        #expect(result == nil)
    }
}

/// The pure `IdentityAgent` → agent-socket decision used to gate/override where the
/// tunnel engine queries and signs against (Task 4 of the ssh_config-fidelity work:
/// IdentityAgent/IdentitiesOnly/ConnectTimeout/ServerAliveInterval/BindAddress).
struct AgentSocketDecisionTests {
    private func hop(identityAgentRaw: String?, host: String = "example.com", port: Int = 22, user: String = "me")
        -> TunnelHop
    {
        TunnelHop(host: host, port: port, user: user, identityAgentRaw: identityAgentRaw)
    }

    @Test func unsetUsesDefaultSocket() {
        #expect(NIOTunnelEngine.agentSocketDecision(for: hop(identityAgentRaw: nil)) == .socket(nil))
    }

    @Test func emptyOrWhitespaceUsesDefaultSocket() {
        #expect(NIOTunnelEngine.agentSocketDecision(for: hop(identityAgentRaw: "")) == .socket(nil))
        #expect(NIOTunnelEngine.agentSocketDecision(for: hop(identityAgentRaw: "   ")) == .socket(nil))
    }

    @Test func noneDisablesTheAgent() {
        #expect(NIOTunnelEngine.agentSocketDecision(for: hop(identityAgentRaw: "none")) == .disabled)
        // Case-insensitive per ssh_config(5).
        #expect(NIOTunnelEngine.agentSocketDecision(for: hop(identityAgentRaw: "None")) == .disabled)
        #expect(NIOTunnelEngine.agentSocketDecision(for: hop(identityAgentRaw: "NONE")) == .disabled)
    }

    @Test func literalSSHAuthSockUsesDefaultSocket() {
        #expect(NIOTunnelEngine.agentSocketDecision(for: hop(identityAgentRaw: "SSH_AUTH_SOCK")) == .socket(nil))
        // Case-insensitive, matching the adjacent `none` check.
        #expect(NIOTunnelEngine.agentSocketDecision(for: hop(identityAgentRaw: "ssh_auth_sock")) == .socket(nil))
        #expect(NIOTunnelEngine.agentSocketDecision(for: hop(identityAgentRaw: "Ssh_Auth_Sock")) == .socket(nil))
    }

    @Test func absolutePathPassesThroughUnchanged() {
        let decision = NIOTunnelEngine.agentSocketDecision(for: hop(identityAgentRaw: "/tmp/my-agent.sock"))
        #expect(decision == .socket("/tmp/my-agent.sock"))
    }

    @Test func tildeExpandsAgainstRealHomeDirectory() {
        let decision = NIOTunnelEngine.agentSocketDecision(for: hop(identityAgentRaw: "~/agent.sock"))
        guard case .socket(let path) = decision else {
            Issue.record("expected .socket, got \(decision)")
            return
        }
        #expect(path == SSHFileAccess.realHomeDirectory.path + "/agent.sock")
        #expect(path?.hasPrefix("~") == false)
    }

    @Test func bareTildeExpandsToRealHomeDirectory() {
        let decision = NIOTunnelEngine.agentSocketDecision(for: hop(identityAgentRaw: "~"))
        #expect(decision == .socket(SSHFileAccess.realHomeDirectory.path))
    }

    /// Regression: `~someuser/…` (a different user's home) must not be naively
    /// concatenated with our real home — that previously produced a garbage path
    /// with no separator (e.g. `/Users/mesomeuser/agent.sock`). Only `~/…` and a
    /// bare `~` expand; anything else starting with `~` passes through untouched.
    @Test func tildeWithNonSlashSuffixIsNotExpanded() {
        let decision = NIOTunnelEngine.agentSocketDecision(for: hop(identityAgentRaw: "~someuser/agent.sock"))
        #expect(decision == .socket("~someuser/agent.sock"))
    }

    @Test func percentTokensAreSubstituted() {
        let decision = NIOTunnelEngine.agentSocketDecision(
            for: hop(
                identityAgentRaw: "/tmp/agent-%h-%p-%r.sock", host: "bastion.example.com", port: 2222, user: "deploy"))
        #expect(decision == .socket("/tmp/agent-bastion.example.com-2222-deploy.sock"))
    }

    /// Regression: a socket path with spaces is written double-quoted
    /// (`IdentityAgent "~/…/agent.sock"`). The quotes must be stripped before the
    /// `~/` tilde check, else the socket path stays quoted-and-unexpanded and the
    /// sandbox-grant prompt points at a path that can never be reached. This is the
    /// exact 1Password "Group Containers" case that was reported broken.
    @Test func quotedSocketPathIsUnquotedAndTildeExpanded() {
        let raw = "\"~/Library/Group Containers/2BUA8C4S2C.com.1password/t/agent.sock\""
        let decision = NIOTunnelEngine.agentSocketDecision(for: hop(identityAgentRaw: raw))
        let expected =
            SSHFileAccess.realHomeDirectory.path
            + "/Library/Group Containers/2BUA8C4S2C.com.1password/t/agent.sock"
        #expect(decision == .socket(expected))
    }

    /// A quoted absolute path is unquoted (no tilde to expand), so the resulting
    /// socket path carries no stray quote characters.
    @Test func quotedAbsolutePathIsUnquoted() {
        let decision = NIOTunnelEngine.agentSocketDecision(for: hop(identityAgentRaw: "\"/tmp/my agent.sock\""))
        #expect(decision == .socket("/tmp/my agent.sock"))
    }

    /// Regression: sequential `replacingOccurrences` calls (one per token) would let
    /// an earlier token's *replacement* value get re-scanned by a later
    /// substitution. Here `%h` expands to a string that itself contains the literal
    /// text "%p" — a single left-to-right pass must not then also replace that
    /// embedded "%p" with the port.
    @Test func singlePassSubstitutionDoesNotReScanReplacementText() {
        let decision = NIOTunnelEngine.agentSocketDecision(
            for: hop(identityAgentRaw: "/tmp/%h.sock", host: "host-with-%p-in-name", port: 2222))
        #expect(decision == .socket("/tmp/host-with-%p-in-name.sock"))
    }
}

/// `IdentitiesOnly` gating: skip the agent entirely (key file / keyboard-interactive
/// only) whenever `IdentitiesOnly yes` is set, regardless of whether an explicit
/// `IdentityFile` was configured (see `identitiesOnlySuppressesAgent`'s doc comment).
struct IdentitiesOnlyGatingTests {
    private func hop(identitiesOnly: Bool, identityFileName: String?) -> TunnelHop {
        TunnelHop(
            host: "example.com", port: 22, user: "me",
            identityFileName: identityFileName, identitiesOnly: identitiesOnly)
    }

    @Test func trueWithIdentityFileSuppressesAgent() {
        #expect(
            NIOTunnelEngine.identitiesOnlySuppressesAgent(
                for: hop(identitiesOnly: true, identityFileName: "id_ed25519")))
    }

    /// Regression: ssh_config(5)'s `IdentitiesOnly yes` restricts to
    /// IdentityFile(s), falling back to ssh(1)'s *default* identity files
    /// (id_rsa/id_ed25519/…) when none is explicitly configured — it never means
    /// "and the agent is still fine to use." This app always has an effective
    /// identity-file candidate either way (see `planHops`'s `id_ed25519` fallback),
    /// so the agent must be suppressed here too, not left in play.
    @Test func trueWithoutIdentityFileStillSuppressesAgent() {
        #expect(
            NIOTunnelEngine.identitiesOnlySuppressesAgent(
                for: hop(identitiesOnly: true, identityFileName: nil)))
    }

    @Test func falseNeverSuppressesAgentRegardlessOfIdentityFile() {
        #expect(
            !NIOTunnelEngine.identitiesOnlySuppressesAgent(
                for: hop(identitiesOnly: false, identityFileName: "id_ed25519")))
        #expect(
            !NIOTunnelEngine.identitiesOnlySuppressesAgent(
                for: hop(identitiesOnly: false, identityFileName: nil)))
    }
}

/// `ConfigStore`'s unified "Grant Access" queue for a hop's unreachable external
/// path — a custom `IdentityAgent` socket (e.g. 1Password's per-app agent) or a
/// `UserKnownHostsFile`, both outside every sandbox-granted folder — reported live
/// by the tunnel engine, mirroring the existing symlink-escape queue's dedup/dismiss
/// semantics. One queue backs both reasons (see `ConfigStore.ExternalAccessReason`).
@MainActor
struct ExternalAccessQueueTests {
    private func store() -> ConfigStore {
        ConfigStore(settings: AppSettings(database: nil))
    }

    @Test func reportingQueuesThePrompt() {
        let store = store()
        #expect(store.pendingExternalAccessRequest == nil)
        store.reportUnreachableExternalPath("/tmp/1p-agent.sock", reason: .agentSocket(hopDescription: "me@bastion"))
        let pending = store.pendingExternalAccessRequest
        #expect(pending?.path.path == "/tmp/1p-agent.sock")
        #expect(pending?.reason.hopDescription == "me@bastion")
    }

    @Test func reportingQueuesTheUserKnownHostsFilePrompt() {
        let store = store()
        store.reportUnreachableExternalPath(
            "/tmp/other_known_hosts",
            reason: .userKnownHostsFile(hopDescription: "me@bastion"))
        let pending = store.pendingExternalAccessRequest
        #expect(pending?.path.path == "/tmp/other_known_hosts")
        if case .userKnownHostsFile = pending?.reason {} else { Issue.record("expected .userKnownHostsFile") }
    }

    /// A jump chain sharing one third-party agent across hops should only prompt once.
    @Test func duplicatePathIsNotQueuedTwice() {
        let store = store()
        store.reportUnreachableExternalPath("/tmp/1p-agent.sock", reason: .agentSocket(hopDescription: "me@bastion"))
        store.reportUnreachableExternalPath("/tmp/1p-agent.sock", reason: .agentSocket(hopDescription: "me@target"))
        #expect(store.externalAccessQueue.count == 1)
        // First reporter wins the description shown in the modal.
        #expect(store.pendingExternalAccessRequest?.reason.hopDescription == "me@bastion")
    }

    @Test func distinctPathsQueueSeparately() {
        let store = store()
        store.reportUnreachableExternalPath("/tmp/agent-a.sock", reason: .agentSocket(hopDescription: "me@a"))
        store.reportUnreachableExternalPath("/tmp/agent-b.sock", reason: .agentSocket(hopDescription: "me@b"))
        #expect(store.externalAccessQueue.count == 2)
    }

    @Test func dismissingRemovesFromQueueAndSuppressesFurtherReports() {
        let store = store()
        store.reportUnreachableExternalPath("/tmp/1p-agent.sock", reason: .agentSocket(hopDescription: "me@bastion"))
        store.dismissPendingExternalAccessRequest()
        #expect(store.pendingExternalAccessRequest == nil)
        // A later connect attempt against the same path must not re-queue it.
        store.reportUnreachableExternalPath("/tmp/1p-agent.sock", reason: .agentSocket(hopDescription: "me@bastion"))
        #expect(store.pendingExternalAccessRequest == nil)
    }

    @Test func dismissingOnlyRemovesTheFrontOfTheQueue() {
        let store = store()
        store.reportUnreachableExternalPath("/tmp/agent-a.sock", reason: .agentSocket(hopDescription: "me@a"))
        store.reportUnreachableExternalPath("/tmp/agent-b.sock", reason: .agentSocket(hopDescription: "me@b"))
        store.dismissPendingExternalAccessRequest()
        #expect(store.pendingExternalAccessRequest?.path.path == "/tmp/agent-b.sock")
    }

    @Test func readExternalKnownHostsEntriesReturnsNilWhenUngranted() {
        let store = store()
        #expect(store.readExternalKnownHostsEntries(atPath: "/tmp/definitely-not-granted-\(UUID()).txt") == nil)
    }

    @Test func readExternalKnownHostsEntriesParsesOnceGranted() throws {
        let sshDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ssh-access-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: sshDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sshDir) }
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("known-hosts-access-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("other_known_hosts")
        try "example.com ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIA==\n".write(to: file, atomically: true, encoding: .utf8)

        let store = store()
        store.useDirectoryForTesting(sshDir)
        store.useAdditionalDirectoryForTesting(dir)
        let entries = store.readExternalKnownHostsEntries(atPath: file.path)
        #expect(entries?.count == 1)
        #expect(entries?.first?.hostsDisplay == "example.com")
    }

    @Test func readExternalKnownHostsEntriesReturnsEmptyForMissingFileInsideGrantedDirectory() throws {
        let sshDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ssh-access-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: sshDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sshDir) }
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("known-hosts-access-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = store()
        store.useDirectoryForTesting(sshDir)
        store.useAdditionalDirectoryForTesting(dir)
        let entries = store.readExternalKnownHostsEntries(atPath: dir.appendingPathComponent("missing").path)
        #expect(entries?.isEmpty == true)
    }
}
