//
//  ServerAlgorithmAuditTests.swift
//  SSHConfigMacUITests
//
//  The audit decides what the user gets warned about, so both directions matter: a weak
//  algorithm must be caught, and a healthy modern server must produce a silent report.
//  A false positive on a good server trains people to ignore the badge.
//

import SSHConfigCore
import Testing

struct ServerAlgorithmAuditTests {
    // MARK: - Host keys

    @Test func flagsShortRSAHostKeys() {
        let broken = ServerAlgorithmAudit.hostKeyVerdict(type: "ssh-rsa", bits: 1024)
        #expect(broken.severity == .error)

        let weak = ServerAlgorithmAudit.hostKeyVerdict(type: "ssh-rsa", bits: 2048)
        #expect(weak.severity == .warning)
        #expect(weak.name.contains("2048"))
    }

    /// The thresholds must match `KeyAuditor`'s, or the same key reads differently
    /// depending on whether it is yours or the server's.
    @Test func rsaThresholdsMatchTheLocalKeyAudit() {
        #expect(ServerAlgorithmAudit.hostKeyVerdict(type: "ssh-rsa", bits: 2047).severity == .error)
        #expect(ServerAlgorithmAudit.hostKeyVerdict(type: "ssh-rsa", bits: 2048).severity == .warning)
        #expect(ServerAlgorithmAudit.hostKeyVerdict(type: "ssh-rsa", bits: 3071).severity == .warning)
        #expect(ServerAlgorithmAudit.hostKeyVerdict(type: "rsa-sha2-512", bits: 3072).severity == nil)
    }

    @Test func flagsDSAHostKeys() {
        #expect(ServerAlgorithmAudit.hostKeyVerdict(type: "ssh-dss").severity == .error)
    }

    /// `ssh-rsa` names the SHA-1 signature algorithm OpenSSH 8.8 disabled. The key is
    /// fine, so this is information, not a warning.
    @Test func notesTheSHA1SignatureNameOnOtherwiseFineRSAKeys() {
        let verdict = ServerAlgorithmAudit.hostKeyVerdict(type: "ssh-rsa", bits: 4096)
        #expect(verdict.severity == .info)
        #expect(ServerAlgorithmAudit.hostKeyVerdict(type: "rsa-sha2-256", bits: 4096).severity == nil)
    }

    @Test func passesEd25519HostKeys() {
        #expect(ServerAlgorithmAudit.hostKeyVerdict(type: "ssh-ed25519").severity == nil)
        #expect(ServerAlgorithmAudit.hostKeyVerdict(type: "ssh-ed25519").isWeak == false)
    }

    // MARK: - Key exchange, ciphers, MACs

    @Test func flagsSHA1KeyExchanges() {
        #expect(ServerAlgorithmAudit.verdict(role: .keyExchange, name: "diffie-hellman-group1-sha1").severity == .error)
        #expect(
            ServerAlgorithmAudit.verdict(role: .keyExchange, name: "diffie-hellman-group14-sha1").severity == .warning)
        #expect(
            ServerAlgorithmAudit.verdict(role: .keyExchange, name: "diffie-hellman-group-exchange-sha1").severity
                == .error)
    }

    @Test func flagsBrokenAndLegacyCiphers() {
        #expect(ServerAlgorithmAudit.verdict(role: .cipher, name: "none").severity == .error)
        #expect(ServerAlgorithmAudit.verdict(role: .cipher, name: "arcfour256").severity == .error)
        #expect(ServerAlgorithmAudit.verdict(role: .cipher, name: "3des-cbc").severity == .error)
        #expect(ServerAlgorithmAudit.verdict(role: .cipher, name: "aes256-cbc").severity == .warning)
    }

    @Test func flagsWeakMACs() {
        #expect(ServerAlgorithmAudit.verdict(role: .mac, name: "hmac-md5").severity == .error)
        #expect(ServerAlgorithmAudit.verdict(role: .mac, name: "hmac-sha1").severity == .warning)
        #expect(ServerAlgorithmAudit.verdict(role: .mac, name: "hmac-sha1-etm@openssh.com").severity == .warning)
        #expect(ServerAlgorithmAudit.verdict(role: .mac, name: "umac-64@openssh.com").severity == .warning)
    }

    /// A hardened, current OpenSSH server must produce no findings at all. This is the
    /// test that keeps the audit from becoming background noise.
    @Test func staysSilentOnAModernServer() {
        let names: [(ServerAlgorithmAudit.Role, String)] = [
            (.keyExchange, "mlkem768x25519-sha256"),
            (.keyExchange, "sntrup761x25519-sha512@openssh.com"),
            (.keyExchange, "curve25519-sha256"),
            (.keyExchange, "ecdh-sha2-nistp384"),
            (.cipher, "chacha20-poly1305@openssh.com"),
            (.cipher, "aes256-gcm@openssh.com"),
            (.cipher, "aes256-ctr"),
            (.mac, "hmac-sha2-256-etm@openssh.com"),
            (.mac, "hmac-sha2-512-etm@openssh.com"),
            (.mac, "umac-128-etm@openssh.com"),
            (.hostKey, "ssh-ed25519"),
        ]
        let verdicts = names.map { ServerAlgorithmAudit.verdict(role: $0.0, name: $0.1) }
        #expect(ServerAlgorithmAudit.weaknesses(in: verdicts).isEmpty)
        #expect(ServerAlgorithmAudit.worstSeverity(in: verdicts) == nil)
    }

    // MARK: - Rollups

    @Test func rollsUpWorstFirst() {
        let verdicts = [
            ServerAlgorithmAudit.verdict(role: .mac, name: "hmac-sha1"),
            ServerAlgorithmAudit.verdict(role: .cipher, name: "3des-cbc"),
            ServerAlgorithmAudit.verdict(role: .cipher, name: "aes256-gcm@openssh.com"),
        ]
        let weak = ServerAlgorithmAudit.weaknesses(in: verdicts)
        #expect(weak.count == 2)
        #expect(weak.first?.severity == .error)
        #expect(ServerAlgorithmAudit.worstSeverity(in: verdicts) == .error)
    }

    @Test func buildsAFindingOnlyForWeakVerdicts() {
        let weak = ServerAlgorithmAudit.hostKeyVerdict(type: "ssh-rsa", bits: 2048)
        let finding = ServerAlgorithmAudit.finding(for: weak, host: "github-old")
        #expect(finding?.severity == .warning)
        #expect(finding?.title.contains("github-old") == true)

        let fine = ServerAlgorithmAudit.hostKeyVerdict(type: "ssh-ed25519")
        #expect(ServerAlgorithmAudit.finding(for: fine, host: "bastion") == nil)
    }

    // MARK: - known_hosts grouping

    private func entry(host: String, type: String, blob: String = "AAAA", marker: String = "") -> KnownHostEntry {
        let raw = (marker.isEmpty ? "" : marker + " ") + "\(host) \(type) \(blob)"
        return KnownHostEntry(
            lineIndex: 0, raw: raw, marker: marker.isEmpty ? nil : marker,
            hostsDisplay: host, isHashed: false, keyType: type, fingerprint: nil)
    }

    /// A server publishes one key per algorithm. ssh negotiates the strongest both sides
    /// support, so an Ed25519 key makes the ECDSA one beside it irrelevant. Judging per
    /// entry produced a finding for every server in a healthy known_hosts.
    @Test func doesNotFlagAHostThatAlsoOffersAStrongKey() {
        let entries = [
            entry(host: "example.com", type: "ssh-ed25519"),
            entry(host: "example.com", type: "ecdsa-sha2-nistp256"),
            entry(host: "example.com", type: "ssh-rsa"),
        ]
        #expect(ServerAlgorithmAudit.knownHostsFindings(entries).isEmpty)
    }

    /// When every key a host offers is weak, there is nothing good to negotiate.
    @Test func flagsAHostWhoseEveryKeyIsWeak() {
        let entries = [
            entry(host: "legacy.example", type: "ssh-dss"),
            entry(host: "legacy.example", type: "ssh-dss"),
        ]
        let findings = ServerAlgorithmAudit.knownHostsFindings(entries)
        #expect(findings.count == 1)
        #expect(findings.first?.severity == .error)
        #expect(findings.first?.title.contains("legacy.example") == true)
    }

    /// Info-only verdicts are for the detail view, not the Issues list: a P-256-only host
    /// is unusual but not a problem worth a badge.
    @Test func keepsInfoOnlyHostsOutOfIssues() {
        let entries = [entry(host: "p256.example", type: "ecdsa-sha2-nistp256")]
        #expect(ServerAlgorithmAudit.knownHostsFindings(entries).isEmpty)
    }

    /// A revoked key is already refused, so calling it weak as well is noise.
    @Test func skipsRevokedEntries() {
        let entries = [entry(host: "gone.example", type: "ssh-dss", marker: "@revoked")]
        #expect(ServerAlgorithmAudit.knownHostsFindings(entries).isEmpty)
    }

    /// The same host under several names must not repeat one warning per line.
    @Test func reportsAWeakHostOnlyOncePerHost() {
        let entries = [
            entry(host: "legacy.example", type: "ssh-dss"),
            entry(host: "legacy.example", type: "ssh-dss"),
            entry(host: "10.0.0.9", type: "ssh-dss"),
        ]
        #expect(ServerAlgorithmAudit.knownHostsFindings(entries).count == 2)
    }

    /// In known_hosts the `ssh-rsa` field names the key family, not the signature
    /// algorithm, so the SHA-1 note that is right on the wire is wrong here.
    @Test func doesNotCallAStoredRSAKeySHA1() {
        let stored = ServerAlgorithmAudit.hostKeyVerdict(
            type: "ssh-rsa", bits: 4096, nameIsSignatureAlgorithm: false)
        #expect(stored.severity == nil)
    }
}
