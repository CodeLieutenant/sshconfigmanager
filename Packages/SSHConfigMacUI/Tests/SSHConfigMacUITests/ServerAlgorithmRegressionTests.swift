//
//  ServerAlgorithmRegressionTests.swift
//  SSHConfigMacUITests
//
//  Regression coverage for the server-algorithm audit work, one test per defect. Each one
//  fails against the code as it was written, which is the only reason it is here.
//

import Foundation
import NIOConcurrencyHelpers
import NIOCore
import NIOEmbedded
import NIOSSH
import SSHConfigCore
import SSHConfigEngine
import SSHConfigServices
import Testing

@testable import SSHConfigMacUI

// MARK: - Pre-load settings race

@MainActor
struct ServerAlgorithmSettingsRestoreTests {
    private func makeDatabase() -> AppDatabase {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("server-algo-settings-\(UUID().uuidString).store")
        return AppDatabase.testDatabase(at: url)
    }

    /// `load()` skips any setting the user changed before the database answered, keyed per
    /// setting. The two server-algorithm toggles were restored inside the *orphaned keys*
    /// guard, so touching that unrelated toggle during launch silently reverted both of
    /// them to their defaults.
    @Test func aPreLoadEditToOneAuditToggleDoesNotBlockTheOthers() async {
        let database = makeDatabase()

        let seed = AppSettings(database: database)
        await seed.waitUntilLoaded()
        seed.auditServerAlgorithms = false
        seed.strictServerAlgorithms = true
        seed.auditOrphanedKeys = true
        await seed.waitForPendingWrites()

        // Change one unrelated audit toggle before the load lands. No await in between, so
        // this is guaranteed to run while `loaded` is still false.
        let reopened = AppSettings(database: database)
        reopened.auditOrphanedKeys = false
        await reopened.waitUntilLoaded()

        #expect(reopened.auditOrphanedKeys == false) // the user's pre-load edit survives
        #expect(reopened.auditServerAlgorithms == false) // …and the stored values still load
        #expect(reopened.strictServerAlgorithms == true)
    }

    /// The mirror image: editing a server-algorithm toggle before load must survive too.
    @Test func aPreLoadEditToAServerAlgorithmToggleSurvives() async {
        let database = makeDatabase()

        let seed = AppSettings(database: database)
        await seed.waitUntilLoaded()
        seed.strictServerAlgorithms = false
        await seed.waitForPendingWrites()

        let reopened = AppSettings(database: database)
        reopened.strictServerAlgorithms = true
        await reopened.waitUntilLoaded()

        #expect(reopened.strictServerAlgorithms == true)
    }
}

// MARK: - Strict mode

struct StrictModeEnforcementTests {
    private static let weak = NIOSSHNegotiatedAlgorithms(
        keyExchange: "diffie-hellman-group1-sha1",
        hostKey: "ssh-ed25519",
        cipher: "aes256-gcm@openssh.com",
        mac: "<implicit>")

    private static let strong = NIOSSHNegotiatedAlgorithms(
        keyExchange: "curve25519-sha256",
        hostKey: "ssh-ed25519",
        cipher: "aes256-gcm@openssh.com",
        mac: "<implicit>")

    /// Builds an *active* channel carrying just the handler under test, plus the promise it
    /// fails. Connecting matters: a fresh `EmbeddedChannel` reports `isActive == false`, so
    /// a test that skips this passes whether or not the handler ever closes anything.
    private static func channel(refuseWeak: Bool) throws -> (EmbeddedChannel, EventLoopPromise<Void>) {
        let channel = EmbeddedChannel()
        let promise = channel.eventLoop.makePromise(of: Void.self)
        try channel.pipeline.syncOperations.addHandler(
            UserAuthWaitHandler(promise: promise, host: "example.com", refuseWeak: refuseWeak))
        try channel.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 22)).wait()
        #expect(channel.isActive == true)
        return (channel, promise)
    }

    /// Strict mode must close the connection, not only fail a promise. Failing the promise
    /// alone left the channel open and relied entirely on the connect path unwinding.
    @Test func strictModeClosesTheChannelOnAWeakHandshake() throws {
        let (channel, promise) = try Self.channel(refuseWeak: true)
        promise.futureResult.whenFailure { _ in }

        channel.pipeline.fireUserInboundEventTriggered(Self.weak)
        channel.embeddedEventLoop.run()

        #expect(channel.isActive == false)
    }

    /// The defect: after user auth succeeds the promise is already resolved, so `fail` is a
    /// no-op. A rekey that lands on a weak algorithm was therefore logged and carried.
    /// Closing the channel is what makes strict mode mean something at rekey time.
    @Test func strictModeStillStopsAWeakRekeyAfterAuthSucceeded() throws {
        let (channel, promise) = try Self.channel(refuseWeak: true)
        promise.futureResult.whenFailure { _ in }

        // Initial handshake: strong, then user auth completes and resolves the promise.
        channel.pipeline.fireUserInboundEventTriggered(Self.strong)
        channel.pipeline.fireUserInboundEventTriggered(UserAuthSuccessEvent())
        channel.embeddedEventLoop.run()
        #expect(channel.isActive == true)

        // Rekey lands on something weak. The promise cannot be failed again.
        channel.pipeline.fireUserInboundEventTriggered(Self.weak)
        channel.embeddedEventLoop.run()

        #expect(channel.isActive == false)
    }

    /// Off by default: a weak handshake is reported, never enforced.
    @Test func withoutStrictModeAWeakHandshakeIsOnlyReported() throws {
        let (channel, promise) = try Self.channel(refuseWeak: false)
        promise.futureResult.whenFailure { _ in }

        channel.pipeline.fireUserInboundEventTriggered(Self.weak)
        channel.embeddedEventLoop.run()

        #expect(channel.isActive == true)
        _ = try? channel.finish()
    }

    /// A clean handshake is never interfered with, strict mode or not.
    @Test func aStrongHandshakeSurvivesStrictMode() throws {
        let (channel, promise) = try Self.channel(refuseWeak: true)
        promise.futureResult.whenFailure { _ in }

        channel.pipeline.fireUserInboundEventTriggered(Self.strong)
        channel.embeddedEventLoop.run()

        #expect(channel.isActive == true)
        _ = try? channel.finish()
    }
}

// MARK: - KEXINIT capture

struct KexInitBannerTests {
    /// A minimal but well-formed KEXINIT carrying one recognisable name per list.
    private static func kexInitPacket() -> [UInt8] {
        var body = ByteBufferAllocator().buffer(capacity: 256)
        body.writeInteger(UInt8(4)) // padding length
        body.writeInteger(KexInitParser.messageID)
        body.writeBytes([UInt8](repeating: 0, count: 16)) // cookie

        let lists = [
            "curve25519-sha256", "ssh-ed25519",
            "aes256-gcm@openssh.com", "3des-cbc",
            "hmac-sha2-256", "hmac-md5",
            "none", "none",
            "", "",
        ]
        for list in lists {
            let bytes = Array(list.utf8)
            body.writeInteger(UInt32(bytes.count))
            body.writeBytes(bytes)
        }
        body.writeInteger(UInt8(0)) // first_kex_packet_follows
        body.writeInteger(UInt32(0)) // reserved
        body.writeBytes([UInt8](repeating: 0, count: 4)) // padding

        var packet = ByteBufferAllocator().buffer(capacity: body.readableBytes + 4)
        packet.writeInteger(UInt32(body.readableBytes))
        packet.writeBuffer(&body)
        return Array(packet.readableBytesView)
    }

    private static func capture(_ bytes: [UInt8]) -> PeerAlgorithmOffer? {
        let box = NIOLockedValueBox<PeerAlgorithmOffer?>(nil)
        let channel = EmbeddedChannel()
        try! channel.pipeline.syncOperations.addHandler(
            KexInitCaptureHandler { offer in box.withLockedValue { $0 = offer } })

        var buffer = channel.allocator.buffer(capacity: bytes.count)
        buffer.writeBytes(bytes)
        try? channel.writeInbound(buffer)
        _ = try? channel.finish()
        return box.withLockedValue { $0 }
    }

    @Test func capturesAnOfferAfterAPlainVersionLine() throws {
        let stream = Array("SSH-2.0-OpenSSH_9.6\r\n".utf8) + Self.kexInitPacket()
        let offer = try #require(Self.capture(stream))
        #expect(offer.ciphers.contains("3des-cbc"))
        #expect(offer.macs.contains("hmac-md5"))
    }

    /// RFC 4253 § 4.2 lets a server send any number of lines before its version string, and
    /// hardened servers commonly do. Looking only at the front of the buffer parked the
    /// reader on the banner forever, so the capture silently produced nothing on exactly
    /// the servers this feature exists to inspect.
    @Test func capturesAnOfferBehindAPreAuthBanner() throws {
        let banner =
            "***************************************\r\n"
            + "  Authorised access only. Sessions are logged.\r\n"
            + "***************************************\r\n"
        let stream = Array(banner.utf8) + Array("SSH-2.0-OpenSSH_9.6\r\n".utf8) + Self.kexInitPacket()

        let offer = try #require(Self.capture(stream))
        #expect(offer.keyExchange == ["curve25519-sha256"])
        #expect(offer.hostKey == ["ssh-ed25519"])
        #expect(offer.ciphers.contains("3des-cbc"))
        #expect(offer.weaknesses.isEmpty == false)
    }

    /// Bare newlines, no carriage return — permitted by the same paragraph, and what a
    /// hand-written banner file usually contains.
    @Test func capturesAnOfferBehindABannerWithBareNewlines() throws {
        let stream =
            Array("welcome\nto the machine\n".utf8)
            + Array("SSH-2.0-OpenSSH_9.6\n".utf8) + Self.kexInitPacket()
        let offer = try #require(Self.capture(stream))
        #expect(offer.hostKey == ["ssh-ed25519"])
    }

    /// The banner and the packet arriving in separate reads must work the same way.
    @Test func capturesAnOfferSplitAcrossReads() throws {
        let box = NIOLockedValueBox<PeerAlgorithmOffer?>(nil)
        let channel = EmbeddedChannel()
        try channel.pipeline.syncOperations.addHandler(
            KexInitCaptureHandler { offer in box.withLockedValue { $0 = offer } })

        for chunk in [
            Array("banner line one\r\n".utf8),
            Array("SSH-2.0-Op".utf8),
            Array("enSSH_9.6\r\n".utf8),
            Array(Self.kexInitPacket().prefix(10)),
            Array(Self.kexInitPacket().dropFirst(10)),
        ] {
            var buffer = channel.allocator.buffer(capacity: chunk.count)
            buffer.writeBytes(chunk)
            try channel.writeInbound(buffer)
        }
        _ = try? channel.finish()

        let offer = try #require(box.withLockedValue { $0 })
        #expect(offer.keyExchange == ["curve25519-sha256"])
    }

    /// A peer that never sends a version line must not grow the buffer without bound.
    @Test func stopsBufferingAPeerThatNeverSendsAVersionLine() throws {
        let noise = [UInt8](repeating: UInt8(ascii: "x"), count: 96 * 1024)
        #expect(Self.capture(noise) == nil)
    }

    /// A KEXINIT whose header understates its own size used to keep reading past the packet
    /// boundary, because each field was bounded by the buffer rather than by the packet. A
    /// second packet's bytes then became "algorithms the server offers".
    @Test func doesNotReadNamesPastTheDeclaredPacketLength() throws {
        var truncated = Self.kexInitPacket()
        // Shrink the declared length so the name-lists run off the end of the packet, then
        // append a second packet for the old code to wander into.
        let shortened = UInt32(truncated.count - 4 - 40)
        withUnsafeBytes(of: shortened.bigEndian) { truncated.replaceSubrange(0..<4, with: $0) }

        let stream = Array("SSH-2.0-OpenSSH_9.6\r\n".utf8) + truncated + Self.kexInitPacket()
        #expect(Self.capture(stream) == nil)
    }

    /// The layout is fixed by RFC 4253 § 7.1, so leftover bytes inside the packet mean the
    /// parse landed somewhere other than where it thinks.
    @Test func rejectsAPacketWithTrailingBytesInsideIt() throws {
        var padded = Self.kexInitPacket()
        let inflated = UInt32(padded.count - 4 + 16)
        withUnsafeBytes(of: inflated.bigEndian) { padded.replaceSubrange(0..<4, with: $0) }
        padded.append(contentsOf: [UInt8](repeating: 0, count: 16))

        let stream = Array("SSH-2.0-OpenSSH_9.6\r\n".utf8) + padded
        #expect(Self.capture(stream) == nil)
    }

    /// A truncated packet must stay pending, not parse. Feeding the first half alone should
    /// yield nothing at all rather than a partial offer.
    @Test func aHalfDeliveredPacketYieldsNothing() throws {
        let packet = Self.kexInitPacket()
        let stream = Array("SSH-2.0-OpenSSH_9.6\r\n".utf8) + Array(packet.prefix(packet.count / 2))
        #expect(Self.capture(stream) == nil)
    }
}

// MARK: - Known-host key blob

struct KnownHostKeyBlobTests {
    /// The blob is located by finding the key-type field, because an `@marker` shifts every
    /// column along by one. Making it a stored property must not change that.
    @Test func findsTheBlobWithAndWithoutAMarker() {
        let plain = KnownHostsService.parse("example.com ssh-ed25519 AAAABBBBCCCC comment\n")
        #expect(plain.first?.keyBlobBase64 == "AAAABBBBCCCC")

        let marked = KnownHostsService.parse("@cert-authority example.com ssh-ed25519 AAAABBBBCCCC\n")
        #expect(marked.first?.keyBlobBase64 == "AAAABBBBCCCC")

        let revoked = KnownHostsService.parse("@revoked [example.com]:2222 ssh-rsa DDDDEEEE\n")
        #expect(revoked.first?.keyBlobBase64 == "DDDDEEEE")
    }
}
