//
//  AgentIntegrationTests.swift
//  sshconfigmanagerTests
//
//  Covers the ssh-agent integration's pure pieces: the REMOVE_IDENTITY /
//  REMOVE_ALL_IDENTITIES protocol framing + status parsing, and the disk↔agent
//  correlation that drives the Agent view's loaded/not-loaded badges.
//

import Darwin
import Foundation
import SSHConfigCore
import SSHConfigCrypto
import SSHConfigEngine
import SSHConfigServices
import Testing

@testable import SSHConfigMacUI

struct SSHAgentProtocolRemoveTests {
    @Test func removeIdentityMessageFramesTypeAndBlob() throws {
        let blob: [UInt8] = [0xAA, 0xBB, 0xCC]
        let message = SSHAgentProtocol.removeIdentityMessage(keyBlob: blob)

        // 4-byte length prefix, then: type(1) + string(4 len + 3 blob) = 8 bytes.
        var reader = ByteReader(message)
        #expect(try reader.readUInt32() == 8)
        #expect(try reader.readUInt8() == SSHAgentProtocol.removeIdentity)
        #expect(try reader.readString() == blob)
    }

    @Test func removeAllMessageIsBareType() throws {
        let message = SSHAgentProtocol.removeAllIdentitiesMessage()
        var reader = ByteReader(message)
        #expect(try reader.readUInt32() == 1)
        #expect(try reader.readUInt8() == SSHAgentProtocol.removeAllIdentities)
    }

    @Test func parseStatusAcceptsSuccess() throws {
        try SSHAgentProtocol.parseStatus([SSHAgentProtocol.success])
    }

    @Test func parseStatusThrowsAgentFailureOnFailureByte() {
        #expect(throws: SSHAgentError.self) {
            try SSHAgentProtocol.parseStatus([SSHAgentProtocol.failure])
        }
    }

    @Test func parseStatusThrowsOnUnexpectedType() {
        #expect(throws: SSHAgentError.self) {
            try SSHAgentProtocol.parseStatus([99])
        }
    }
}

struct AgentKeyCorrelationTests {
    /// A disk key whose `fingerprint` matches the SHA256 of `blob`, so an agent
    /// identity carrying the same blob correlates to it.
    private func diskKey(blob: [UInt8], name: String, hasPrivate: Bool = true) -> SSHPublicKey {
        SSHPublicKey(
            id: UUID(),
            publicKeyURL: URL(fileURLWithPath: "/keys/\(name).pub"),
            privateKeyURL: hasPrivate ? URL(fileURLWithPath: "/keys/\(name)") : nil,
            algorithm: "ssh-ed25519",
            fingerprint: SSHKeyService.fingerprint(blob: blob) ?? "",
            comment: "disk@host"
        )
    }

    private func identity(blob: [UInt8], comment: String = "agent@host") -> AgentIdentity {
        AgentIdentity(keyBlob: blob, comment: comment, keyType: "ssh-ed25519")
    }

    @Test func diskKeyLoadedInAgentIsMarkedLoaded() {
        let blob: [UInt8] = [1, 2, 3, 4]
        let rows = AgentKeyCorrelation.merge(
            diskKeys: [diskKey(blob: blob, name: "id_ed25519")],
            agentIdentities: [identity(blob: blob)])
        #expect(rows.count == 1)
        #expect(rows[0].isLoaded)
        #expect(rows[0].diskKey != nil)
        #expect(!rows[0].isOnDiskOnly)
    }

    @Test func diskKeyNotInAgentIsOnDiskOnly() {
        let rows = AgentKeyCorrelation.merge(
            diskKeys: [diskKey(blob: [1, 2, 3], name: "id_ed25519")],
            agentIdentities: [])
        #expect(rows.count == 1)
        #expect(!rows[0].isLoaded)
        #expect(rows[0].isOnDiskOnly)
    }

    @Test func agentIdentityWithNoDiskKeyBecomesAgentOnlyRow() {
        let rows = AgentKeyCorrelation.merge(
            diskKeys: [],
            agentIdentities: [identity(blob: [9, 9, 9], comment: "1password")])
        #expect(rows.count == 1)
        #expect(rows[0].isLoaded)
        #expect(rows[0].diskKey == nil)
        #expect(rows[0].comment == "1password")
    }

    @Test func loadedAndUnloadedAreNotDoubleCounted() {
        let loadedBlob: [UInt8] = [1, 1, 1]
        let unloadedBlob: [UInt8] = [2, 2, 2]
        let rows = AgentKeyCorrelation.merge(
            diskKeys: [
                diskKey(blob: loadedBlob, name: "loaded"),
                diskKey(blob: unloadedBlob, name: "unloaded"),
            ],
            agentIdentities: [identity(blob: loadedBlob)])
        #expect(rows.count == 2)
        // Loaded keys sort first.
        #expect(rows[0].isLoaded)
        #expect(!rows[1].isLoaded)
    }

    @Test func diskKeyWithNoFingerprintNeverMatches() {
        let noFingerprint = SSHPublicKey(
            id: UUID(), publicKeyURL: URL(fileURLWithPath: "/keys/weird.pub"),
            privateKeyURL: nil, algorithm: "", fingerprint: "", comment: "")
        // An agent identity also yields an empty-ish blob path; ensure no spurious match.
        let rows = AgentKeyCorrelation.merge(
            diskKeys: [noFingerprint],
            agentIdentities: [identity(blob: [5, 5, 5])])
        #expect(rows.count == 2) // one disk-only + one agent-only
        #expect(rows.contains { $0.isOnDiskOnly })
        #expect(rows.contains { $0.diskKey == nil && $0.isLoaded })
    }

    @Test func selectionIDPrefersFingerprintFallsBackToID() {
        let blob: [UInt8] = [3, 1, 4]
        let loaded = AgentKeyCorrelation.merge(
            diskKeys: [diskKey(blob: blob, name: "k")], agentIdentities: [identity(blob: blob)])[0]
        #expect(loaded.selectionID == loaded.fingerprint)
        #expect(!loaded.fingerprint.isEmpty)

        // A fingerprint-less row falls back to its synthetic id.
        let noFp = SSHPublicKey(
            id: UUID(), publicKeyURL: nil,
            privateKeyURL: URL(fileURLWithPath: "/keys/weird"),
            algorithm: "", fingerprint: "", comment: "")
        let row = AgentKeyCorrelation.merge(diskKeys: [noFp], agentIdentities: [])[0]
        #expect(row.selectionID == row.id)
    }

    @Test func matchesFingerprintIsTheSharedCanonicalTest() {
        let blob: [UInt8] = [4, 2, 4, 2]
        let id = identity(blob: blob)
        let fp = AgentKeyCorrelation.fingerprint(of: id)!
        #expect(AgentKeyCorrelation.matchesFingerprint(id, fp))
        #expect(!AgentKeyCorrelation.matchesFingerprint(id, "SHA256:different"))
        // An empty fingerprint must never match (guards the no-fingerprint case).
        #expect(!AgentKeyCorrelation.matchesFingerprint(id, ""))
        // The fingerprint equals what the engine derives from the matching .pub.
        let pubBase64 = Data(blob).base64EncodedString()
        #expect(SSHKeyService.fingerprint(base64Blob: pubBase64) == fp)
    }

    @Test func typeLabelMapsWireNamesToFriendlyLabels() {
        #expect(AgentKeyCorrelation.typeLabel(forKeyType: "ssh-ed25519") == "Ed25519")
        #expect(AgentKeyCorrelation.typeLabel(forKeyType: "ssh-rsa") == "RSA")
        #expect(AgentKeyCorrelation.typeLabel(forKeyType: "rsa-sha2-512") == "RSA")
        #expect(AgentKeyCorrelation.typeLabel(forKeyType: "ecdsa-sha2-nistp256") == "ECDSA")
        #expect(AgentKeyCorrelation.typeLabel(forKeyType: "sk-ssh-ed25519@openssh.com") == "Security Key")
        #expect(AgentKeyCorrelation.typeLabel(forKeyType: "") == "Unknown")
    }

    @Test func agentCommentPreferredWhenDiskCommentEmpty() {
        let blob: [UInt8] = [7, 7, 7]
        var key = diskKey(blob: blob, name: "id_ed25519")
        key = SSHPublicKey(
            id: key.id, publicKeyURL: key.publicKeyURL,
            privateKeyURL: key.privateKeyURL, algorithm: key.algorithm,
            fingerprint: key.fingerprint, comment: "")
        let rows = AgentKeyCorrelation.merge(
            diskKeys: [key], agentIdentities: [identity(blob: blob, comment: "from-agent")])
        #expect(rows[0].comment == "from-agent")
    }
}

/// Exercises the real connect/write/read/framing path of `SSHAgentService`
/// against a one-shot loopback Unix-domain socket — the only coverage of the
/// socket layer (the rest of the suite tests the pure protocol codec). Confirms
/// the actor refactor and socket hardening still round-trip a request/reply.
struct SSHAgentSocketTests {
    /// A throwaway AF_UNIX listener that accepts one connection, reads the framed
    /// request, and writes back `reply` (already framed). Runs the blocking accept
    /// on a background queue. Path is kept under /tmp to respect sun_path's limit.
    private final class FakeAgent: @unchecked Sendable {
        let path: String
        private let fd: Int32
        init(reply: [UInt8]) {
            path = "/tmp/sshagt-\(UUID().uuidString.prefix(8)).sock"
            unlink(path)
            fd = socket(AF_UNIX, SOCK_STREAM, 0)
            var addr = sockaddr_un()
            addr.sun_family = sa_family_t(AF_UNIX)
            _ = withUnsafeMutablePointer(to: &addr.sun_path) { p in
                path.withCString { strncpy(UnsafeMutableRawPointer(p).assumingMemoryBound(to: CChar.self), $0, 103) }
            }
            _ = withUnsafePointer(to: &addr) { p in
                p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            listen(fd, 1)
            let listenFD = fd
            DispatchQueue.global().async {
                let client = accept(listenFD, nil, nil)
                guard client >= 0 else { return }
                var scratch = [UInt8](repeating: 0, count: 4096)
                _ = scratch.withUnsafeMutableBytes { read(client, $0.baseAddress, 4096) }
                _ = reply.withUnsafeBytes { write(client, $0.baseAddress, reply.count) }
                close(client)
            }
        }
        func stop() {
            close(fd)
            unlink(path)
        }
    }

    @Test func roundTripReadsAFramedIdentitiesAnswer() throws {
        // Build a real IDENTITIES_ANSWER with one ed25519 identity, framed.
        let blob = SSHAgentProtocol.string([UInt8]("ssh-ed25519".utf8)) + SSHAgentProtocol.string([1, 2, 3])
        var payload: [UInt8] = [SSHAgentProtocol.identitiesAnswer]
        payload += SSHAgentProtocol.uint32(1) // identity count
        payload += SSHAgentProtocol.string(blob) // key blob
        payload += SSHAgentProtocol.string([UInt8]("me@host".utf8)) // comment
        let reply = SSHAgentProtocol.frame(payload)

        let agent = FakeAgent(reply: reply)
        defer { agent.stop() }

        let response = try SSHAgentService.roundTripForTesting(
            SSHAgentProtocol.requestIdentitiesMessage(), socketPath: agent.path)
        let identities = try SSHAgentProtocol.parseIdentities(response)
        #expect(identities.count == 1)
        #expect(identities[0].comment == "me@host")
        #expect(identities[0].keyType == "ssh-ed25519")
    }

    @Test func connectToMissingSocketThrows() {
        #expect(throws: SSHAgentError.self) {
            _ = try SSHAgentService.roundTripForTesting([0], socketPath: "/tmp/no-such-agent-\(UUID().uuidString).sock")
        }
    }

    /// Exercises the actor-level `listIdentities(socketPath:)` override (added for
    /// per-hop `IdentityAgent`), not just the static `roundTripForTesting` seam —
    /// confirms the override reaches all the way through `send(_:socketPath:)`.
    @Test func listIdentitiesUsesSocketPathOverride() async throws {
        let blob = SSHAgentProtocol.string([UInt8]("ssh-ed25519".utf8)) + SSHAgentProtocol.string([9, 9, 9])
        var payload: [UInt8] = [SSHAgentProtocol.identitiesAnswer]
        payload += SSHAgentProtocol.uint32(1)
        payload += SSHAgentProtocol.string(blob)
        payload += SSHAgentProtocol.string([UInt8]("override@host".utf8))
        let reply = SSHAgentProtocol.frame(payload)

        let agent = FakeAgent(reply: reply)
        defer { agent.stop() }

        // Deliberately don't touch SSH_AUTH_SOCK — the override alone must be
        // enough to reach this throwaway agent.
        let identities = try await SSHAgentService().listIdentities(socketPath: agent.path)
        #expect(identities.count == 1)
        #expect(identities[0].comment == "override@host")
    }

    /// Same override, through `sign(keyBlob:data:flags:socketPath:)` — the path
    /// `AgentAuthDelegate` actually drives during a tunnel handshake.
    @Test func signUsesSocketPathOverride() async throws {
        let sig: [UInt8] = [0xAB, 0xCD, 0xEF]
        let payload: [UInt8] = [SSHAgentProtocol.signResponse] + SSHAgentProtocol.string(sig)
        let reply = SSHAgentProtocol.frame(payload)

        let agent = FakeAgent(reply: reply)
        defer { agent.stop() }

        let result = try await SSHAgentService().sign(keyBlob: [1, 2, 3], data: [4, 5, 6], socketPath: agent.path)
        #expect(result == sig)
    }

    /// A nil `socketPath` (the default parameter) must preserve prior behavior:
    /// fall back to `Self.socketPath` (`SSH_AUTH_SOCK`). Deliberately points
    /// `SSH_AUTH_SOCK` at our throwaway `FakeAgent` for the duration of the test (via
    /// `setenv`/`unsetenv`, restored afterward) rather than relying on
    /// `SSHAgentService.isAvailable` — the previous version of this test early-
    /// returned (asserting nothing) on any machine with a real agent already
    /// running, which is most dev machines and likely CI, making it a silent no-op
    /// there. This version exercises the real fallback path unconditionally.
    @Test func nilSocketPathOverrideFallsBackToDefaultAgent() async throws {
        let blob = SSHAgentProtocol.string([UInt8]("ssh-ed25519".utf8)) + SSHAgentProtocol.string([7, 7, 7])
        var payload: [UInt8] = [SSHAgentProtocol.identitiesAnswer]
        payload += SSHAgentProtocol.uint32(1)
        payload += SSHAgentProtocol.string(blob)
        payload += SSHAgentProtocol.string([UInt8]("default@host".utf8))
        let reply = SSHAgentProtocol.frame(payload)

        let agent = FakeAgent(reply: reply)
        defer { agent.stop() }

        let original = ProcessInfo.processInfo.environment["SSH_AUTH_SOCK"]
        setenv("SSH_AUTH_SOCK", agent.path, 1)
        defer {
            if let original {
                setenv("SSH_AUTH_SOCK", original, 1)
            } else {
                unsetenv("SSH_AUTH_SOCK")
            }
        }

        // No `socketPath:` argument at all — must resolve through `Self.socketPath`
        // (the env var we just pointed at the fake agent) and reach it.
        let identities = try await SSHAgentService().listIdentities()
        #expect(identities.count == 1)
        #expect(identities[0].comment == "default@host")
    }

    /// The other half of the fallback contract: with `SSH_AUTH_SOCK` unset and no
    /// override, the call must fail with `.socketUnavailable` rather than hang or
    /// silently succeed against nothing.
    @Test func nilSocketPathOverrideWithNoEnvVarThrowsSocketUnavailable() async {
        let original = ProcessInfo.processInfo.environment["SSH_AUTH_SOCK"]
        unsetenv("SSH_AUTH_SOCK")
        defer { if let original { setenv("SSH_AUTH_SOCK", original, 1) } }

        await #expect(throws: SSHAgentError.self) {
            _ = try await SSHAgentService().listIdentities()
        }
    }
}

/// Covers the in-app "Add to Agent" serialization: a parsed private key →
/// ADD_IDENTITY body. Uses real generated keys (ed25519/ECDSA) and the RSA test
/// fixture so the wire layout is validated against keys the parser actually produces.
struct AgentAddIdentityTests {
    private func readStr(_ r: inout ByteReader) throws -> [UInt8] { try r.readString() }

    @Test func ed25519BodyRoundTrips() throws {
        let gen = try SSHKeyGenerator.generate(algorithm: .ed25519, comment: "me@host", passphrase: nil)
        let parsed = try OpenSSHPrivateKey.parse(pem: gen.privateKeyPEM)
        let body = try AgentKeySerializer.addIdentityBody(for: parsed, comment: "me@host")

        var r = ByteReader(body)
        #expect(String(decoding: try readStr(&r), as: UTF8.self) == "ssh-ed25519")
        let pub = try readStr(&r)
        let secret = try readStr(&r)
        let comment = String(decoding: try readStr(&r), as: UTF8.self)
        #expect(pub == parsed.publicKey) // ENC(A)
        #expect(pub.count == 32)
        #expect(secret.count == 64) // seed(32) || pub(32)
        #expect(Array(secret.suffix(32)) == pub)
        #expect(comment == "me@host")
    }

    @Test func ecdsaBodyRoundTrips() throws {
        let gen = try SSHKeyGenerator.generate(algorithm: .ecdsaP256, comment: "ec@host", passphrase: nil)
        let parsed = try OpenSSHPrivateKey.parse(pem: gen.privateKeyPEM)
        let body = try AgentKeySerializer.addIdentityBody(for: parsed, comment: "ec@host")

        var r = ByteReader(body)
        #expect(String(decoding: try readStr(&r), as: UTF8.self) == "ecdsa-sha2-nistp256")
        #expect(String(decoding: try readStr(&r), as: UTF8.self) == "nistp256") // curve name
        let point = try readStr(&r)
        #expect(point == parsed.publicKey) // Q
        _ = try readStr(&r) // mpint d (scalar)
        #expect(String(decoding: try readStr(&r), as: UTF8.self) == "ec@host")
    }

    @Test func encryptedKeyDecryptsThenSerializes() throws {
        let gen = try SSHKeyGenerator.generate(algorithm: .ed25519, comment: "k", passphrase: "hunter2")
        let parsed = try OpenSSHPrivateKey.parse(pem: gen.privateKeyPEM, passphrase: "hunter2")
        let body = try AgentKeySerializer.addIdentityBody(for: parsed, comment: "k")
        #expect(!body.isEmpty)
    }

    @Test func rsaParseRetainsIqmpAndBodyHasSixMpints() throws {
        let parsed = try OpenSSHPrivateKey.parse(pem: unencryptedRSA)
        #expect(parsed.rsaIQMP != nil) // iqmp retained for the agent path
        let body = try AgentKeySerializer.addIdentityBody(for: parsed, comment: "rsa@host")

        var r = ByteReader(body)
        #expect(String(decoding: try readStr(&r), as: UTF8.self) == "ssh-rsa")
        for _ in 0..<6 { #expect(!(try readStr(&r)).isEmpty) } // n, e, d, iqmp, p, q
        #expect(String(decoding: try readStr(&r), as: UTF8.self) == "rsa@host")
    }

    @Test func rsaWithoutIqmpThrows() {
        let key = ParsedOpenSSHKey(
            keyType: "ssh-rsa", publicKey: [],
            material: .rsa(n: [1], e: [1], d: [1], p: [1], q: [1]),
            rsaIQMP: nil)
        #expect(throws: OpenSSHKeyError.self) {
            _ = try AgentKeySerializer.addIdentityBody(for: key, comment: "x")
        }
    }

    @Test func mpintPrependsZeroForHighBitAndStripsLeadingZeros() throws {
        // High bit set → a 0x00 sign byte is prepended.
        var r1 = ByteReader(AgentKeySerializer.mpint([0x80, 0x01]))
        #expect(try r1.readString() == [0x00, 0x80, 0x01])
        // Leading zeros trimmed.
        var r2 = ByteReader(AgentKeySerializer.mpint([0x00, 0x00, 0x7F]))
        #expect(try r2.readString() == [0x7F])
        // Zero magnitude → empty mpint (length 0).
        var r3 = ByteReader(AgentKeySerializer.mpint([0x00]))
        #expect(try r3.readString() == [])
    }

    @Test func addIdentityMessageFramesType17() throws {
        let message = SSHAgentProtocol.addIdentityMessage(body: [0xAB])
        var r = ByteReader(message)
        #expect(try r.readUInt32() == 2) // type + 1 body byte
        #expect(try r.readUInt8() == SSHAgentProtocol.addIdentity)
        #expect(SSHAgentProtocol.addIdentity == 17)
    }

    /// The real proof that our ADD_IDENTITY wire format is correct: add a throwaway
    /// generated key to a real ssh-agent, confirm it shows up, then remove it.
    ///
    /// The agent is one this test starts and kills, never the developer's own. An
    /// earlier version talked to `$SSH_AUTH_SOCK` and relied on `defer { Task { … } }`
    /// to unload the key — an unstructured Task that the test process can outrun, so
    /// any throw between the add and the remove left the key behind. A dozen stray
    /// `sshcfgmgr-test` identities piled up that way and one of them ended up in an
    /// App Store screenshot. Killing a private agent cannot leak: its keys only ever
    /// existed in that process's memory.
    @Test func liveAgentAcceptsAndRemovesAGeneratedKey() async throws {
        guard let agent = try ThrowawayAgent.start() else { return } // no ssh-agent binary
        defer { agent.stop() }
        let socket = agent.socketPath

        let gen = try SSHKeyGenerator.generate(
            algorithm: .ed25519,
            comment: "sshcfgmgr-test", passphrase: nil)
        let parsed = try OpenSSHPrivateKey.parse(pem: gen.privateKeyPEM)
        let body = try AgentKeySerializer.addIdentityBody(for: parsed, comment: "sshcfgmgr-test")
        // The ed25519 agent public-key blob (string type · string pub) used to
        // find and remove exactly our key.
        let blob =
            SSHAgentProtocol.string(Array("ssh-ed25519".utf8))
            + SSHAgentProtocol.string(parsed.publicKey)

        let service = SSHAgentService()
        try await service.addIdentity(body: body, socketPath: socket)

        let afterAdd = try await service.listIdentities(socketPath: socket)
        #expect(afterAdd.contains { $0.keyBlob == blob }) // the agent accepted our wire format

        try await service.removeIdentity(keyBlob: blob, socketPath: socket)
        let afterRemove = try await service.listIdentities(socketPath: socket)
        #expect(!afterRemove.contains { $0.keyBlob == blob })
    }

    private let unencryptedRSA = """
        -----BEGIN OPENSSH PRIVATE KEY-----
        b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAABFwAAAAdzc2gtcn
        NhAAAAAwEAAQAAAQEA0W6xEDkrdKfs24OeK5z/iSyjBJkk4ICU48qETI3Ukk+Jc93HDMgK
        o3LFRQt3YkkJdGkGqkAK6ZNQqpMsS6cYWlcbiK+TAjrsf+fdEChjVst8SJ6a7zg9Uewib5
        MOvkiuXDNaOr83i71HKwnMqGPkPkig1WxeYnVB4LBjp2QUQkGhCyOKeML7U6GpgBYVVt6H
        qlxWufolGF6mxC8xJfgDileULX9qayH2urDWRfGC4ufHyUr+ezqHU785bDj+4JMdsW7ybF
        rJnHlFLXifJ4ar3PCEuiCwKX8k8VkrYucHz+G2KcVh+DFVYHj1yZwpCRpJEgqXLGsOIHex
        oaxb4yNyHQAAA8ia9gVVmvYFVQAAAAdzc2gtcnNhAAABAQDRbrEQOSt0p+zbg54rnP+JLK
        MEmSTggJTjyoRMjdSST4lz3ccMyAqjcsVFC3diSQl0aQaqQArpk1CqkyxLpxhaVxuIr5MC
        Oux/590QKGNWy3xInprvOD1R7CJvkw6+SK5cM1o6vzeLvUcrCcyoY+Q+SKDVbF5idUHgsG
        OnZBRCQaELI4p4wvtToamAFhVW3oeqXFa5+iUYXqbELzEl+AOKV5Qtf2prIfa6sNZF8YLi
        58fJSv57OodTvzlsOP7gkx2xbvJsWsmceUUteJ8nhqvc8IS6ILApfyTxWSti5wfP4bYpxW
        H4MVVgePXJnCkJGkkSCpcsaw4gd7GhrFvjI3IdAAAAAwEAAQAAAQBqr7GhKw5ZAcYl2Ll1
        TCfcUBHHIOBpQPcXxy139fQoiD3j+UER4MGSm7+kOYAaYExhsbLEfZVRgUrhadFxxHAibS
        dIjPAdfbjGO24gcgKQz13DfJA+dm6+UcUFA2vKQSoZK8u2C3yXQdeENBy+VwyJMeREdEzs
        aQEjHZfWSKQNT4aQJV8qndVVsBZYnBKeuO2qlpoPG7xUYE0MqQi0RlCoN2PjckKJ7paOwL
        EyZ7zrjR6rmEpjjgZCOxMXMU1Jh+22HXdFhodRwUH87IAhFNq6R1i8IVQpGGgEYLw4WzPj
        +k8HOHQiJrzkLPzkqCTjd0axRXVqvTbiTjk0Bl2D2SwhAAAAgQDMApoJGf3VUx5do5asSp
        jvz1BF82SXDwhuA1Zh/YN2kXoPLqUJVoykuC3fUTAjlhOxAd/vEdpDCbdk58sPQvB3qJrB
        wwjpc5F70NcHiojkbRnIi5iObp+p3F551qDJQMNvtUOCdjmSYVrFIJyMAdVioO7rOxB68S
        D1Bet4f9pWwAAAAIEA/N9CY4/Gv2DXpNJeY+sVq+X5qMjqTz7rljIJ3fdshTLm1jHYS3Y4
        JoPYS3AQSjGBxSc7H7v+njGY3NIioLqrPTiRgpus0MkBsJerNtc4fbPWIxXMSWnP+FosSX
        fxIK1pjpNMSs9slFYMPbO/xtxkoG/so1TdSyY223oyhZkZ+lUAAACBANQF4HeWH6dQNtYS
        +Mc7EJsk2yAPjUZRGQ+REF9yzHNdSnJedoc39GY1JjiAjqIkhQLCB9lxHaNto89C3AxOvK
        B3TpeY7xVHvfHriSskA7WEYES8tMWheahVIbp819t4VdrpBjQ9YaapvvtqBpuM65B5eY7l
        vhq0V51W2F2NmHCpAAAADnJzYS10ZXN0QGxvY2FsAQIDBA==
        -----END OPENSSH PRIVATE KEY-----
        """
}

/// In-memory `PassphraseStoring` so the remember/forget/reload orchestration is
/// testable without a signed keychain.
final class FakePassphraseStore: PassphraseStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: String] = [:]
    init(_ seed: [String: String] = [:]) { items = seed }
    func store(passphrase: String, forKeyPath keyPath: String) throws {
        lock.lock()
        defer { lock.unlock() }
        items[keyPath] = passphrase
    }
    func passphrase(forKeyPath keyPath: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return items[keyPath]
    }
    func remove(forKeyPath keyPath: String) {
        lock.lock()
        defer { lock.unlock() }
        items[keyPath] = nil
    }
    func allKeyPaths() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return Array(items.keys)
    }
}

@MainActor
struct RememberKeyAcrossRebootsTests {
    private func store(seed: [String: String] = [:]) -> (ConfigStore, FakePassphraseStore) {
        let fake = FakePassphraseStore(seed)
        let cfg = ConfigStore(settings: AppSettings(database: nil), passphraseStore: fake)
        return (cfg, fake)
    }

    private func key(named name: String) -> SSHPublicKey {
        SSHPublicKey(
            id: UUID(),
            publicKeyURL: URL(fileURLWithPath: "/keys/\(name).pub"),
            privateKeyURL: URL(fileURLWithPath: "/keys/\(name)"),
            algorithm: "ssh-ed25519", fingerprint: "SHA256:x", comment: "")
    }

    @Test func initLoadsRememberedNamesFromStore() {
        let (cfg, _) = store(seed: ["id_ed25519": "", "work": "secret"])
        #expect(cfg.rememberedKeyNames == ["id_ed25519", "work"])
        #expect(cfg.isRememberedAcrossReboots(key(named: "work")))
        #expect(!cfg.isRememberedAcrossReboots(key(named: "other")))
    }

    @Test func forgetRemovesFromStoreAndSet() {
        let (cfg, fake) = store(seed: ["id_ed25519": "", "work": "secret"])
        cfg.forgetKeyAcrossReboots(key(named: "work"))
        #expect(!cfg.isRememberedAcrossReboots(key(named: "work")))
        #expect(cfg.rememberedKeyNames == ["id_ed25519"])
        #expect(Set(fake.allKeyPaths()) == ["id_ed25519"])
    }

    @Test func forgetUnknownKeyIsHarmless() {
        let (cfg, _) = store(seed: ["id_ed25519": ""])
        cfg.forgetKeyAcrossReboots(key(named: "not-remembered"))
        #expect(cfg.rememberedKeyNames == ["id_ed25519"])
    }
}

struct SSHAgentServiceCommandTests {
    private func key(hasPrivate: Bool) -> SSHPublicKey {
        SSHPublicKey(
            id: UUID(),
            publicKeyURL: URL(fileURLWithPath: "/keys/id_ed25519.pub"),
            privateKeyURL: hasPrivate ? URL(fileURLWithPath: "/keys/id_ed25519") : nil,
            algorithm: "ssh-ed25519", fingerprint: "SHA256:x", comment: "")
    }

    @Test func addCommandIncludesKeychainFlagWhenRequested() {
        let command = SSHAgentService.addCommand(for: key(hasPrivate: true), useKeychain: true)
        #expect(command?.contains("--apple-use-keychain") == true)
        #expect(command?.hasPrefix("ssh-add ") == true)
    }

    @Test func addCommandOmitsKeychainFlagByDefault() {
        let command = SSHAgentService.addCommand(for: key(hasPrivate: true), useKeychain: false)
        #expect(command?.contains("--apple-use-keychain") == false)
    }

    @Test func addCommandNilWithoutPrivateKey() {
        #expect(SSHAgentService.addCommand(for: key(hasPrivate: false), useKeychain: true) == nil)
    }

    /// A key path outside the home directory stays literal, so `addCommand` must
    /// quote it. Builds a key under /tmp so `identityFilePath` doesn't ~-rewrite it.
    private func tmpKey(named name: String) -> SSHPublicKey {
        SSHPublicKey(
            id: UUID(),
            publicKeyURL: URL(fileURLWithPath: "/tmp/agenttest/\(name).pub"),
            privateKeyURL: URL(fileURLWithPath: "/tmp/agenttest/\(name)"),
            algorithm: "ssh-ed25519", fingerprint: "SHA256:x", comment: "")
    }

    @Test func addCommandQuotesPathWithSpace() {
        // Regression for review finding C1: an unquoted path with a space loads the
        // wrong files. The whole path must be a single shell word.
        let command = SSHAgentService.addCommand(for: tmpKey(named: "work key"), useKeychain: false)
        #expect(command == "ssh-add '/tmp/agenttest/work key'")
    }

    @Test func addCommandQuotesShellMetacharacters() {
        // A hostile/odd key filename must not become a shell-injection vector.
        let command = SSHAgentService.addCommand(for: tmpKey(named: "a;rm -rf ~"), useKeychain: false)
        #expect(command == "ssh-add '/tmp/agenttest/a;rm -rf ~'")
    }

    @Test func shellQuoteEscapesEmbeddedSingleQuote() {
        #expect(SSHAgentService.shellQuote("a'b") == "'a'\\''b'")
    }

    @Test func shellQuoteKeepsTildeOutsideQuotes() {
        // ~/ must stay unquoted so the shell still expands it; the rest is quoted.
        #expect(SSHAgentService.shellQuote("~/.ssh/id key") == "~/'.ssh/id key'")
        #expect(SSHAgentService.shellQuote("~") == "~")
    }

    // MARK: - Per-operation receive timeout (audit #23)

    /// 1Password/Secretive hold a SIGN_REQUEST reply open until the user responds
    /// to an approval/Touch ID prompt, routinely past the 5s bound every other
    /// operation uses — a signed reply arriving at t=6s must not look like a
    /// wedged agent (`EAGAIN` → auth failure) even though the user just approved.
    @Test func signGetsALongReceiveTimeout() {
        #expect(SSHAgentService.receiveTimeoutSeconds(for: .sign) > 30)
    }

    /// Every other operation keeps the short bound — a wedged or hostile agent on
    /// LIST/ADD/REMOVE must still fail fast (finding H3), since none of those
    /// legitimately block on a human prompt.
    @Test func nonSignOperationsKeepTheShortTimeout() {
        #expect(SSHAgentService.receiveTimeoutSeconds(for: .other) == 5)
    }
}

/// A private `ssh-agent` process that lives only as long as one test.
///
/// `-D` keeps it in the foreground, which is the whole point: with ssh-agent's
/// default fork-and-daemonise behaviour the `Process` handle exits immediately and
/// the real agent survives as an orphan holding whatever the test added. In
/// foreground mode the handle *is* the agent, so `terminate()` takes its keys with it.
private struct ThrowawayAgent {
    let socketPath: String
    private let process: Process
    private let directory: URL

    /// Starts an agent, or returns nil when there is no `ssh-agent` to start (a
    /// container image without OpenSSH) so the caller can skip rather than fail.
    static func start() throws -> ThrowawayAgent? {
        let executable = "/usr/bin/ssh-agent"
        guard FileManager.default.isExecutableFile(atPath: executable) else { return nil }

        // Keep the path short: a Unix-domain socket address caps out around 104 bytes
        // and the temp directory already spends about half of that.
        let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("sshcm-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let socketPath = directory.appendingPathComponent("s").path

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["-D", "-a", socketPath]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()

        // The socket appears a beat after exec; poll rather than guess a sleep.
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline, !FileManager.default.fileExists(atPath: socketPath) {
            usleep(20_000)
        }
        guard FileManager.default.fileExists(atPath: socketPath) else {
            process.terminate()
            try? FileManager.default.removeItem(at: directory)
            return nil
        }
        return ThrowawayAgent(socketPath: socketPath, process: process, directory: directory)
    }

    func stop() {
        process.terminate()
        process.waitUntilExit()
        try? FileManager.default.removeItem(at: directory)
    }
}
