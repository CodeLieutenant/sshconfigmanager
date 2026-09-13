//
//  StrictServerAlgorithmTests.swift
//  SSHConfigMacUITests
//
//  Strict mode cannot be exercised against a real server: this engine only implements
//  strong algorithms, so it can never negotiate a weak one no matter what the peer offers.
//  That is a good property, and it is exactly why the refusal path needs a test that feeds
//  the handler a negotiation directly — otherwise the code would never run until the day
//  someone adds a weak cipher.
//

import Foundation
import NIOCore
import NIOEmbedded
import NIOSSH
import SSHConfigCore
import SSHConfigEngine
import Testing

@testable import SSHConfigMacUI

struct StrictServerAlgorithmTests {
    private func fire(
        _ negotiated: NIOSSHNegotiatedAlgorithms, refuseWeak: Bool
    ) throws -> (failed: Bool, lines: [(TunnelLogLevel, String)]) {
        let channel = EmbeddedChannel()
        let promise = channel.eventLoop.makePromise(of: Void.self)
        let box = LogBox()
        try channel.pipeline.syncOperations.addHandler(
            UserAuthWaitHandler(
                promise: promise, host: "server.example",
                log: { level, message in box.add(level, message) },
                refuseWeak: refuseWeak))

        channel.pipeline.fireUserInboundEventTriggered(negotiated)

        var failed = false
        promise.futureResult.whenFailure { _ in failed = true }
        // Nothing else completes the promise in this test; succeed it so it is not leaked.
        if !failed { promise.succeed(()) }
        _ = try? channel.finish()
        return (failed, box.all)
    }

    private static let weak = NIOSSHNegotiatedAlgorithms(
        keyExchange: "diffie-hellman-group14-sha1", hostKey: "ssh-ed25519",
        cipher: "aes256-gcm@openssh.com", mac: "<implicit>")
    private static let strong = NIOSSHNegotiatedAlgorithms(
        keyExchange: "mlkem768x25519-sha256", hostKey: "ssh-ed25519",
        cipher: "aes256-gcm@openssh.com", mac: "<implicit>")

    @Test func logsTheNegotiatedSummaryEvenWhenEverythingIsStrong() throws {
        let result = try fire(Self.strong, refuseWeak: false)
        #expect(result.failed == false)
        #expect(result.lines.contains { $0.1.contains("negotiated mlkem768x25519-sha256") })
        // A healthy connection must produce no warning line at all.
        #expect(result.lines.allSatisfy { $0.0 != .error })
    }

    @Test func warnsButConnectsWhenStrictIsOff() throws {
        let result = try fire(Self.weak, refuseWeak: false)
        #expect(result.failed == false)
        #expect(result.lines.contains { $0.1.contains("diffie-hellman-group14-sha1") })
    }

    @Test func refusesWhenStrictIsOn() throws {
        let result = try fire(Self.weak, refuseWeak: true)
        #expect(result.failed)
        let refusal = result.lines.first { $0.1.hasPrefix("Refused") }
        #expect(refusal != nil)
        // The message has to name the algorithm and the way out, because the only fixes
        // are the server's configuration or this setting.
        #expect(refusal?.1.contains("diffie-hellman-group14-sha1") == true)
        #expect(refusal?.1.contains("Settings") == true)
    }

    /// An AEAD cipher negotiates no MAC. `<implicit>` is not an algorithm and must not be
    /// judged as one, or every healthy modern connection would be flagged.
    @Test func doesNotJudgeTheImplicitMAC() throws {
        let result = try fire(Self.strong, refuseWeak: true)
        #expect(result.failed == false)
    }
}

private final class LogBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [(TunnelLogLevel, String)] = []
    func add(_ level: TunnelLogLevel, _ message: String) {
        lock.lock()
        storage.append((level, message))
        lock.unlock()
    }
    var all: [(TunnelLogLevel, String)] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}
