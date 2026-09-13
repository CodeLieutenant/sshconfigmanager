//
//  SSHErrorTextTests.swift
//  sshconfigmanagerTests
//
//  A failed tunnel used to report "The operation couldn't be completed.
//  (NIOPosix.NIOConnectionError error 1.)" — Foundation's bridging of a plain
//  `Error` struct — while the real cause (connection refused, host unreachable,
//  port already bound) sat one unwrap away. These pin the readable wording.
//

import Foundation
import NIOCore
import NIOPosix
import SSHConfigEngine
import Testing

@testable import SSHConfigMacUI

struct SSHErrorTextTests {
    /// The whole point: never emit Foundation's opaque wrapper for a NIO error.
    private func isOpaqueFoundationWrapper(_ text: String) -> Bool {
        text.contains("The operation couldn") || text.contains("error 1.)")
    }

    @Test func ioErrorReportsTheSystemWording() {
        let refused = IOError(errnoCode: ECONNREFUSED, reason: "connect")
        let text = SSHErrorText.describe(refused)
        #expect(text == "Connection refused")
        #expect(!isOpaqueFoundationWrapper(text))
    }

    /// The one that actually bit: a refused TCP connect arrives wrapped in
    /// `NIOConnectionError`, whose `localizedDescription` IS the opaque Foundation
    /// wrapper (unlike `IOError`, which defines its own). Built by really connecting
    /// to a closed local port, since the type has no public initializer.
    @Test func realConnectFailureNamesHostPortAndCause() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        do {
            _ = try await ClientBootstrap(group: group)
                .connectTimeout(.seconds(2))
                .connect(host: "127.0.0.1", port: 9)
                .get()
            Issue.record("expected the connect to fail")
        } catch {
            let text = SSHErrorText.describe(error)
            #expect(text.contains("127.0.0.1:9"))
            #expect(!isOpaqueFoundationWrapper(text))
            // The premise this whole type exists for.
            #expect(isOpaqueFoundationWrapper(error.localizedDescription))
        }
        try? await group.shutdownGracefully()
    }

    @Test func addressInUseSurfacesAsSuchForTheBindHint() {
        let inUse = IOError(errnoCode: EADDRINUSE, reason: "bind")
        #expect(SSHErrorText.describe(inUse) == "Address already in use")
    }

    /// `bindErrorMessage` keys off the wording, so a port clash must produce the
    /// actionable message rather than the raw errno.
    @Test func bindErrorMessageExplainsAPortClash() {
        let message = NIOTunnelConnection.bindErrorMessage(
            IOError(errnoCode: EADDRINUSE, reason: "bind"), host: "127.0.0.1", port: 3000)
        #expect(message.contains("already in use"))
        #expect(message.contains("3000"))
        #expect(!isOpaqueFoundationWrapper(message))
    }

    @Test func bindErrorMessageExplainsAPrivilegedPort() {
        let message = NIOTunnelConnection.bindErrorMessage(
            IOError(errnoCode: EACCES, reason: "bind"), host: "127.0.0.1", port: 443)
        #expect(message.contains("elevated privileges"))
    }

    @Test func connectTimeoutNamesTheTimeout() {
        let text = SSHErrorText.describe(ChannelError.connectTimeout(.seconds(30)))
        #expect(text.contains("30s"))
        #expect(text.contains("ConnectTimeout"))
    }

    /// Our own errors already carry good wording — don't paraphrase them.
    @Test func localizedErrorsPassThroughUnchanged() {
        let auth = HopAuthenticationError(
            message: "Authentication failed for bastion:22 — the server rejected every offered credential.")
        #expect(SSHErrorText.describe(auth) == auth.message)
        #expect(SSHErrorText.describe(SSHHopChainError.hopFailed(auth)) == auth.message)
    }

    /// The wrapper must unwrap: a hop failure carrying a NIO error reports the NIO
    /// error's readable text, not the wrapper's own bridged description.
    @Test func hopFailedUnwrapsToTheUnderlyingCause() {
        let wrapped = SSHHopChainError.hopFailed(IOError(errnoCode: EHOSTUNREACH, reason: "connect"))
        #expect(SSHErrorText.describe(wrapped) == "No route to host")
    }
}
