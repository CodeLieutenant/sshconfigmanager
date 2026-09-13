//
//  OpenSSHInteropTests.swift
//  SSHConfigMacUITests
//
//  Wire-format coverage against a real OpenSSH server, not against ourselves.
//
//  Every other test of the key exchange and transport ciphers drives this client against
//  this client. That proves self-consistency and nothing else: an exchange hash that folds
//  `K` in the wrong way, or a cipher whose framing is subtly off, round-trips perfectly
//  because both ends make the identical mistake. Only a second implementation can tell us.
//
//  `mlkem768x25519-sha256` is the reason this file exists. Unlike every ECDH method it
//  feeds `K` into the exchange hash and the key derivation as an SSH *string* rather than
//  an mpint, and it is now offered *first* — so getting it wrong breaks every connection to
//  an OpenSSH 9.9+ server, and breaks it at signature verification where the error says
//  nothing useful. The test cannot pass unless our exchange hash byte-for-byte matches the
//  one sshd signed.
//
//  Each test starts a private sshd on loopback, restricted to exactly one algorithm, with a
//  throwaway host key and a single authorised key. Nothing touches the user's ssh
//  configuration, no system service is involved, and the whole thing is deleted afterwards.
//  Skipped automatically when the host has no sshd, or an sshd too old for the algorithm.
//

import Foundation
import NIOConcurrencyHelpers
import Network
import SSHConfigCore
import SSHConfigEngine
import Testing

@testable import SSHConfigMacUI

// MARK: - Harness

/// A private OpenSSH server, restricted to the algorithms a test wants to pin.
private final class LocalSSHD: @unchecked Sendable {
    let port: Int
    let clientPEM: String
    let username: String
    private let process: Process
    private let directory: URL

    private init(port: Int, clientPEM: String, username: String, process: Process, directory: URL) {
        self.port = port
        self.clientPEM = clientPEM
        self.username = username
        self.process = process
        self.directory = directory
    }

    static let sshdPath = "/usr/sbin/sshd"

    /// Whether this host can run the tests at all: an sshd binary, and a `ssh` that knows
    /// the algorithm. Both are checked because a Mac can have one without the other.
    static func supports(kex: String? = nil, cipher: String? = nil, mac: String? = nil) -> Bool {
        guard FileManager.default.isExecutableFile(atPath: sshdPath) else { return false }
        if let kex, !query("kex").contains(kex) { return false }
        if let cipher, !query("cipher").contains(cipher) { return false }
        if let mac, !query("mac").contains(mac) { return false }
        return true
    }

    /// `ssh -Q <what>` — the supported-algorithm list of the OpenSSH on this machine.
    ///
    /// Cached, because every `.enabled(if:)` trait in this file calls `supports` and the
    /// answer cannot change mid-run. Uncached, one `swift test` invocation spawned dozens
    /// of `ssh -Q` processes off the swift-testing thread pool.
    private static let queryCache = NIOLockedValueBox<[String: Set<String>]>([:])

    private static func query(_ what: String) -> Set<String> {
        if let cached = queryCache.withLockedValue({ $0[what] }) { return cached }
        let answer: Set<String> =
            run("/usr/bin/ssh", ["-Q", what])
            .map { Set($0.split(whereSeparator: \.isNewline).map(String.init)) } ?? []
        queryCache.withLockedValue { $0[what] = answer }
        return answer
    }

    /// Runs a command and returns its stdout, capturing through a temporary *file* rather
    /// than a `Pipe`.
    ///
    /// `Pipe` + `readDataToEndOfFile()` blocks the calling thread until the child closes
    /// its end. Swift Testing runs test bodies on the cooperative concurrency pool, and
    /// blocking those threads on child-process I/O deadlocks the whole run — the same
    /// failure mode as waiting on an `NWListener` callback in `freePort()`. A file has no
    /// buffer to fill and no reader to schedule, so `waitUntilExit()` is the only wait.
    @discardableResult
    private static func run(_ path: String, _ arguments: [String]) -> String? {
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("interop-run-\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: output.path, contents: nil) else { return nil }
        defer { try? FileManager.default.removeItem(at: output) }

        guard let handle = try? FileHandle(forWritingTo: output) else { return nil }
        defer { try? handle.close() }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardOutput = handle
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return try? String(contentsOf: output, encoding: .utf8)
    }

    /// An unused loopback port, found with plain BSD sockets rather than `NWListener`: the
    /// Network framework is callback-driven, and blocking an async test's thread on a
    /// semaphore waiting for one starves the cooperative pool.
    ///
    /// Racy in principle — the socket closes before sshd binds — but the window is
    /// microseconds and the suite runs `--no-parallel`.
    private static func freePort() throws -> Int {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw TestFailure("could not open a socket to reserve a port") }
        defer { close(descriptor) }

        var reuse: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0 // let the kernel choose
        address.sin_addr.s_addr = inet_addr("127.0.0.1")

        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
        guard bound else { throw TestFailure("could not bind a loopback port for sshd") }

        var assigned = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &assigned) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(descriptor, $0, &length) == 0
            }
        }
        guard named else { throw TestFailure("could not read back the reserved port") }
        return Int(UInt16(bigEndian: assigned.sin_port))
    }

    /// Brings up sshd offering *only* what is passed. Anything left nil is left at the
    /// server's own default, so a test pins one dimension at a time.
    static func start(
        kex: String? = nil, ciphers: String? = nil, macs: String? = nil,
        allowTcpForwarding: Bool = true
    ) throws -> LocalSSHD {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("sshd-interop-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)

        // A throwaway host key, and a throwaway client key authorised to use it. Generated
        // rather than checked in, so nothing here is ever a credential.
        let hostKey = directory.appendingPathComponent("host_ed25519").path
        guard run("/usr/bin/ssh-keygen", ["-q", "-t", "ed25519", "-f", hostKey, "-N", "", "-C", "interop-host"]) != nil
        else {
            throw TestFailure("ssh-keygen could not create a host key")
        }
        let clientKey = directory.appendingPathComponent("client_ed25519").path
        guard
            run("/usr/bin/ssh-keygen", ["-q", "-t", "ed25519", "-f", clientKey, "-N", "", "-C", "interop-client"])
                != nil,
            let publicKey = try? String(contentsOfFile: clientKey + ".pub", encoding: .utf8)
        else {
            throw TestFailure("ssh-keygen could not create a client key")
        }

        let authorizedKeys = directory.appendingPathComponent("authorized_keys")
        try publicKey.write(to: authorizedKeys, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: authorizedKeys.path)

        let port = try freePort()
        let username = NSUserName()
        var configuration = """
            Port \(port)
            ListenAddress 127.0.0.1
            HostKey \(hostKey)
            AuthorizedKeysFile \(authorizedKeys.path)
            AllowUsers \(username)
            StrictModes no
            UsePAM no
            PasswordAuthentication no
            KbdInteractiveAuthentication no
            PubkeyAuthentication yes
            AllowTcpForwarding \(allowTcpForwarding ? "yes" : "no")
            PidFile none
            LogLevel DEBUG1

            """
        if let kex { configuration += "KexAlgorithms \(kex)\n" }
        if let ciphers { configuration += "Ciphers \(ciphers)\n" }
        if let macs { configuration += "MACs \(macs)\n" }

        let configurationURL = directory.appendingPathComponent("sshd_config")
        try configuration.write(to: configurationURL, atomically: true, encoding: .utf8)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: sshdPath)
        process.arguments = [
            "-f", configurationURL.path,
            "-E", directory.appendingPathComponent("sshd.log").path,
            "-D",
        ]
        try process.run()

        let server = LocalSSHD(
            port: port,
            clientPEM: try String(contentsOfFile: clientKey, encoding: .utf8),
            username: username,
            process: process,
            directory: directory)

        guard server.waitUntilListening() else {
            server.shutdown()
            throw TestFailure("sshd did not start listening on \(port): \(server.log)")
        }
        return server
    }

    /// sshd is ready when the port accepts a connection. Polled rather than slept on, so a
    /// slow machine does not turn into a flaky test.
    private func waitUntilListening(timeout: TimeInterval = 10) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            guard self.process.isRunning else { return false }
            let socket = socket(AF_INET, SOCK_STREAM, 0)
            defer { close(socket) }
            var address = sockaddr_in()
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = UInt16(self.port).bigEndian
            address.sin_addr.s_addr = inet_addr("127.0.0.1")
            let connected = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    connect(socket, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
                }
            }
            if connected { return true }
            usleep(100_000)
        }
        return false
    }

    /// sshd's own log, so a failure says why rather than "did not connect". At `DEBUG1` it
    /// also names what the server settled on, which is the only report of the negotiated
    /// algorithms that does not come from the code under test.
    var log: String {
        (try? String(contentsOf: self.directory.appendingPathComponent("sshd.log"), encoding: .utf8)) ?? ""
    }

    /// Waits for a line to appear, since sshd writes its log as it goes and the assertion
    /// can otherwise run a beat ahead of the flush.
    func waitForLog(_ substring: String, timeout: TimeInterval = 5) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if self.log.contains(substring) { return true }
            usleep(50_000)
        }
        return false
    }

    /// Stops the server, without `waitUntilExit()`.
    ///
    /// `waitUntilExit()` blocks the calling thread until Foundation reaps the child, and
    /// Swift Testing runs test bodies on the cooperative pool — the hazard `run()` and
    /// `freePort()` are already written around. Under `--no-parallel` that pool is one
    /// thread wide, so a reap that does not report parks the entire run: the process is
    /// gone, the wait never returns, and every later test simply never starts.
    ///
    /// Poll a deadline instead. The wait stays bounded, and a stuck reap costs seconds
    /// rather than the suite.
    func shutdown() {
        if self.process.isRunning { self.process.terminate() }
        let deadline = Date().addingTimeInterval(5)
        while self.process.isRunning, Date() < deadline { usleep(20_000) }
        try? FileManager.default.removeItem(at: self.directory)
    }
}

// MARK: - Tests

struct OpenSSHInteropTests {
    /// Opens a tunnel through `server` to a loopback echo service and asserts the bytes
    /// come back. Reaching the echo means the handshake, the key derivation, the transport
    /// cipher and a `direct-tcpip` channel all agreed with OpenSSH.
    private func assertTunnelWorks(
        through server: LocalSSHD,
        kexAlgorithms: [String] = [],
        ciphers: [String] = [],
        macs: [String] = []
    ) async throws {
        let (echo, echoPort) = try await startEchoServer()
        defer { echo.cancel() }

        let connection = try NIOTunnelEngine.makeConnectionForTesting(
            pem: server.clientPEM, passphrase: nil,
            sshHost: "127.0.0.1", sshPort: server.port, username: server.username,
            bindHost: "127.0.0.1", bindPort: 0,
            targetHost: "127.0.0.1", targetPort: echoPort,
            ciphers: ciphers, macs: macs, kexAlgorithms: kexAlgorithms)
        defer { connection.shutdown() }

        let outcome = await awaitTunnelStart(connection, timeout: 30)
        switch outcome {
        case nil:
            throw TestFailure("tunnel did not become active in 30s. sshd log:\n\(server.log)")
        case .failed(let reason):
            throw TestFailure("tunnel failed: \(reason). sshd log:\n\(server.log)")
        case .active:
            break
        }

        let localPort = try #require(connection.boundPort)
        let payload = Data("interop round trip".utf8)
        let reply = await roundTrip(localPort: localPort, send: payload, expect: payload.count)
        #expect(reply == payload, "no echo back through the tunnel. sshd log:\n\(server.log)")
    }

    // MARK: A refused forward has to say so

    /// `AllowTcpForwarding no` is the one failure the tunnel cannot report as a failed
    /// connect: the SSH link is up, the listener is bound, and the tunnel is active. Every
    /// client connection is then accepted and closed with zero bytes — a browser calls that
    /// `NS_ERROR_NET_EMPTY_RESPONSE` — so the log line is the only diagnosis there is.
    @Test(.enabled(if: LocalSSHD.supports()))
    func aRefusedForwardIsReported() async throws {
        let server = try LocalSSHD.start(allowTcpForwarding: false)
        defer { server.shutdown() }

        let (echo, echoPort) = try await startEchoServer()
        defer { echo.cancel() }

        let connection = try NIOTunnelEngine.makeConnectionForTesting(
            pem: server.clientPEM, passphrase: nil,
            sshHost: "127.0.0.1", sshPort: server.port, username: server.username,
            bindHost: "127.0.0.1", bindPort: 0,
            targetHost: "127.0.0.1", targetPort: echoPort)
        let logged = NIOLockedValueBox<[String]>([])
        connection.setEventHandler { event in
            if case .log(_, let message) = event { logged.withLockedValue { $0.append(message) } }
        }
        defer { connection.shutdown() }

        switch await awaitTunnelStart(connection, timeout: 30) {
        case nil: throw TestFailure("tunnel did not become active in 30s. sshd log:\n\(server.log)")
        case .failed(let reason): throw TestFailure("tunnel failed: \(reason). sshd log:\n\(server.log)")
        case .active: break
        }

        let localPort = try #require(connection.boundPort)
        let reply = await roundTrip(localPort: localPort, send: Data("ping".utf8), expect: 4, timeout: 5)
        #expect(reply == nil, "the server has forwarding off, so nothing should come back")

        let lines = logged.withLockedValue { $0 }
        #expect(
            lines.contains { $0.contains("refused the forward to 127.0.0.1:\(echoPort)") },
            "the refusal was never logged: \(lines)")
    }

    // MARK: The suite must actually run

    /// A skipped test and a passing test look identical in a CI log. Every test below is
    /// gated on the host having an `sshd` new enough for the algorithm it needs, so a
    /// runner image that ships an older OpenSSH would silently delete all of this
    /// coverage — and the build would stay green while nothing checked the wire format.
    ///
    /// `SSHCM_REQUIRE_INTEROP=1`, which CI sets, turns "cannot run" into "failed". Left
    /// unset locally, so a machine without `sshd` is not a broken checkout.
    @Test func theInteropSuiteIsRunnableWhereItIsRequired() throws {
        guard ProcessInfo.processInfo.environment["SSHCM_REQUIRE_INTEROP"] == "1" else { return }

        var missing: [String] = []
        if !FileManager.default.isExecutableFile(atPath: LocalSSHD.sshdPath) {
            missing.append("no sshd at \(LocalSSHD.sshdPath)")
        }
        for kex in ["mlkem768x25519-sha256", "curve25519-sha256"] where !LocalSSHD.supports(kex: kex) {
            missing.append("sshd cannot speak \(kex)")
        }
        for cipher in ["aes256-ctr", "aes256-gcm@openssh.com", "chacha20-poly1305@openssh.com"]
        where !LocalSSHD.supports(cipher: cipher) {
            missing.append("sshd cannot speak \(cipher)")
        }

        #expect(
            missing.isEmpty,
            """
            SSHCM_REQUIRE_INTEROP is set but this host cannot run the interop suite, \
            so the wire-format coverage would have been skipped without failing: \
            \(missing.joined(separator: "; ")). \
            Either the runner image regressed, or the requirement should be dropped \
            deliberately rather than by accident.
            """)
    }

    // MARK: Key exchange

    /// The one that matters. `K` is hashed as an SSH string here, not as an mpint, and the
    /// exchange hash covers the ML-KEM encapsulation key and ciphertext verbatim. If any of
    /// that disagrees with OpenSSH, the host key signature fails to verify and no tunnel
    /// comes up — there is no way for this to pass on a self-consistent-but-wrong build.
    @Test(.enabled(if: LocalSSHD.supports(kex: "mlkem768x25519-sha256")))
    func mlkemHybridInteroperatesWithOpenSSH() async throws {
        let server = try LocalSSHD.start(kex: "mlkem768x25519-sha256")
        defer { server.shutdown() }
        try await assertTunnelWorks(through: server, kexAlgorithms: ["mlkem768x25519-sha256"])
    }

    /// The client must reach for the hybrid on its own when the server offers a choice —
    /// that is the whole point of putting it first in the offer. Read out of sshd's log
    /// rather than our own, so the code under test is not the one grading itself.
    @Test(.enabled(if: LocalSSHD.supports(kex: "mlkem768x25519-sha256")))
    func theHybridIsChosenWithoutBeingForced() async throws {
        let server = try LocalSSHD.start(kex: "mlkem768x25519-sha256,curve25519-sha256")
        defer { server.shutdown() }
        // No client-side override: whatever it prefers is what gets used.
        try await assertTunnelWorks(through: server)
        #expect(
            server.waitForLog("kex: algorithm: mlkem768x25519-sha256"),
            "sshd did not report the hybrid:\n\(server.log)")
    }

    /// The documented cipher ordering, confirmed by the peer: `chacha20-poly1305@openssh.com`
    /// is offered but sits behind AES-GCM, because its Poly1305 is pure Swift. A server with
    /// no restrictions must therefore land on AES-GCM.
    @Test(.enabled(if: LocalSSHD.supports(cipher: "chacha20-poly1305@openssh.com")))
    func aesGCMIsPreferredOverChaCha20WhenTheServerOffersBoth() async throws {
        let server = try LocalSSHD.start(
            kex: "curve25519-sha256", ciphers: "chacha20-poly1305@openssh.com,aes256-gcm@openssh.com")
        defer { server.shutdown() }
        try await assertTunnelWorks(through: server)
        #expect(
            server.waitForLog("cipher: aes256-gcm@openssh.com"),
            "expected AES-GCM to win the cipher negotiation:\n\(server.log)")
    }

    /// The control. If this fails too, the harness is broken rather than ML-KEM — without
    /// it a red hybrid test cannot be told apart from a red test machine.
    @Test(.enabled(if: LocalSSHD.supports(kex: "curve25519-sha256")))
    func ecdhStillInteroperates() async throws {
        let server = try LocalSSHD.start(kex: "curve25519-sha256")
        defer { server.shutdown() }
        try await assertTunnelWorks(through: server, kexAlgorithms: ["curve25519-sha256"])
    }

    /// A server with no post-quantum method must still connect. The hybrid is offered
    /// first, so a bad fallback would be invisible in the tests above.
    @Test(.enabled(if: LocalSSHD.supports(kex: "diffie-hellman-group14-sha256")))
    func fallsBackWhenTheServerHasNoMethodWeOfferFirst() async throws {
        let server = try LocalSSHD.start(kex: "curve25519-sha256,diffie-hellman-group14-sha256")
        defer { server.shutdown() }
        try await assertTunnelWorks(through: server)
    }

    // MARK: KEXINIT capture

    /// `KexInitParser` validates the packet strictly — every field bounded by the declared
    /// length, and exactly the declared padding left over. Every other test of it parses a
    /// packet this repository built, which cannot say whether OpenSSH agrees about the
    /// layout. This one parses what a real sshd actually sent.
    @Test(.enabled(if: LocalSSHD.supports(cipher: "aes256-ctr", mac: "hmac-sha2-512")))
    func capturesTheAlgorithmsARealServerOffers() async throws {
        // A deliberately odd set, so a passing test cannot be a coincidence of defaults.
        let server = try LocalSSHD.start(
            kex: "curve25519-sha256", ciphers: "aes256-ctr", macs: "hmac-sha2-512")
        defer { server.shutdown() }

        let result = await HostKeyScanner.scan(host: "127.0.0.1", port: server.port, timeout: 15)
        guard case .success(let probe) = result else {
            throw TestFailure("scan failed: \(result). sshd log:\n\(server.log)")
        }

        #expect(probe.offer.isEmpty == false, "no KEXINIT captured from a real sshd")
        #expect(probe.offer.ciphers == ["aes256-ctr"])
        #expect(probe.offer.macs == ["hmac-sha2-512"])
        #expect(probe.offer.keyExchange.contains("curve25519-sha256"))
        #expect(probe.offer.hostKey.isEmpty == false)
    }

    /// A server offering something broken is the whole point of the capture — the tunnel
    /// never negotiates a weak algorithm, so this is the only place one can be seen.
    @Test(.enabled(if: LocalSSHD.supports(cipher: "aes128-cbc")))
    func reportsWeakAlgorithmsARealServerStillAccepts() async throws {
        let server = try LocalSSHD.start(ciphers: "aes128-cbc,aes256-gcm@openssh.com")
        defer { server.shutdown() }

        let result = await HostKeyScanner.scan(host: "127.0.0.1", port: server.port, timeout: 15)
        guard case .success(let probe) = result else {
            throw TestFailure("scan failed: \(result). sshd log:\n\(server.log)")
        }

        #expect(probe.offer.ciphers.contains("aes128-cbc"))
        #expect(
            probe.offer.weaknesses.contains { $0.name == "aes128-cbc" },
            "CBC should be flagged: \(probe.offer.weaknesses.map(\.name))")
    }

    // MARK: Transport ciphers

    // Every cipher test below pins the key exchange to `curve25519-sha256`. Without that,
    // the client picks the ML-KEM hybrid first and a key-exchange defect turns every cipher
    // test red too — the suite stops saying *which* layer broke.

    /// AES-GCM: the only cipher this fork shipped before, so it is the baseline the others
    /// are judged against.
    @Test(.enabled(if: LocalSSHD.supports(cipher: "aes256-gcm@openssh.com")))
    func aesGCMInteroperates() async throws {
        let server = try LocalSSHD.start(kex: "curve25519-sha256", ciphers: "aes256-gcm@openssh.com")
        defer { server.shutdown() }
        try await assertTunnelWorks(through: server, ciphers: ["aes256-gcm@openssh.com"])
    }

    /// AES-CTR with encrypt-then-MAC. The length field stays in clear and the MAC covers
    /// the ciphertext, so the padding is computed over a different region than the
    /// encrypt-and-MAC case below — a framing mistake shows up here and nowhere else.
    @Test(
        .enabled(
            if: LocalSSHD.supports(cipher: "aes256-ctr", mac: "hmac-sha2-512-etm@openssh.com")))
    func aesCTREncryptThenMACInteroperates() async throws {
        let server = try LocalSSHD.start(
            kex: "curve25519-sha256", ciphers: "aes256-ctr", macs: "hmac-sha2-512-etm@openssh.com")
        defer { server.shutdown() }
        try await assertTunnelWorks(
            through: server, ciphers: ["aes256-ctr"], macs: ["hmac-sha2-512-etm@openssh.com"])
    }

    /// AES-CTR with RFC 4253 encrypt-and-MAC: the length field is encrypted, the MAC covers
    /// the plaintext, and the counter has to survive `decryptFirstBlock` taking the leading
    /// block before the rest of the packet arrives.
    @Test(.enabled(if: LocalSSHD.supports(cipher: "aes256-ctr", mac: "hmac-sha2-256")))
    func aesCTREncryptAndMACInteroperates() async throws {
        let server = try LocalSSHD.start(
            kex: "curve25519-sha256", ciphers: "aes256-ctr", macs: "hmac-sha2-256")
        defer { server.shutdown() }
        try await assertTunnelWorks(through: server, ciphers: ["aes256-ctr"], macs: ["hmac-sha2-256"])
    }

    /// `hmac-sha2-512` wants a 64-byte integrity key, which is more than the key exchange's
    /// hash produces in one round. This is the only test that exercises the RFC 4253 § 7.2
    /// extension step against a peer that computed the same key independently.
    @Test(.enabled(if: LocalSSHD.supports(cipher: "aes128-ctr", mac: "hmac-sha2-512")))
    func aesCTRWithAnOversizedMACKeyInteroperates() async throws {
        let server = try LocalSSHD.start(
            kex: "curve25519-sha256", ciphers: "aes128-ctr", macs: "hmac-sha2-512")
        defer { server.shutdown() }
        try await assertTunnelWorks(through: server, ciphers: ["aes128-ctr"], macs: ["hmac-sha2-512"])
    }

    /// `chacha20-poly1305@openssh.com` is assembled here from a ChaCha20 keystream and a
    /// third-party Poly1305 rather than taken whole from a library, and it is not the RFC
    /// 8439 AEAD. This is the only check that the assembly matches what OpenSSH does.
    @Test(.enabled(if: LocalSSHD.supports(cipher: "chacha20-poly1305@openssh.com")))
    func chaCha20Poly1305Interoperates() async throws {
        let server = try LocalSSHD.start(kex: "curve25519-sha256", ciphers: "chacha20-poly1305@openssh.com")
        defer { server.shutdown() }
        try await assertTunnelWorks(through: server, ciphers: ["chacha20-poly1305@openssh.com"])
    }

    /// The hybrid and the new ciphers together, since they are negotiated independently and
    /// each combination derives its keys from a different hash.
    @Test(
        .enabled(
            if: LocalSSHD.supports(kex: "mlkem768x25519-sha256", cipher: "aes256-ctr", mac: "hmac-sha2-512")))
    func theHybridInteroperatesWithAESCTR() async throws {
        let server = try LocalSSHD.start(
            kex: "mlkem768x25519-sha256", ciphers: "aes256-ctr", macs: "hmac-sha2-512")
        defer { server.shutdown() }
        try await assertTunnelWorks(
            through: server, kexAlgorithms: ["mlkem768x25519-sha256"],
            ciphers: ["aes256-ctr"], macs: ["hmac-sha2-512"])
    }

    // MARK: Helpers

    /// Loopback TCP echo, the far end of every tunnel above.
    private func startEchoServer() async throws -> (NWListener, Int) {
        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .loopback
        let listener = try NWListener(using: parameters, on: .any)
        listener.newConnectionHandler = { connection in
            connection.start(queue: .global())
            @Sendable func pump() {
                connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, _ in
                    if let data, !data.isEmpty {
                        connection.send(content: data, completion: .idempotent)
                    }
                    if isComplete { connection.cancel() } else { pump() }
                }
            }
            pump()
        }
        let port = await awaitResult(timeout: 5) { (finish: @escaping @Sendable (Int?) -> Void) in
            listener.stateUpdateHandler = { if case .ready = $0 { finish(listener.port.map { Int($0.rawValue) }) } }
            listener.start(queue: .global())
        }
        guard let port else {
            listener.cancel()
            throw TestFailure("echo server did not start")
        }
        return (listener, port)
    }

    /// Sends `send` to a loopback port and reads `expect` bytes back.
    private func roundTrip(localPort: Int, send: Data, expect: Int, timeout: TimeInterval = 20) async -> Data? {
        let connection = NWConnection(
            host: "127.0.0.1", port: NWEndpoint.Port(rawValue: UInt16(localPort))!, using: .tcp)
        let result = await awaitResult(timeout: timeout) { finish in
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    connection.send(
                        content: send,
                        completion: .contentProcessed { _ in
                            connection.receive(minimumIncompleteLength: expect, maximumLength: expect) {
                                data, _, _, _ in
                                finish(data)
                            }
                        })
                case .failed:
                    finish(nil)
                default:
                    break
                }
            }
            connection.start(queue: .global())
        }
        connection.cancel()
        return result
    }
}
