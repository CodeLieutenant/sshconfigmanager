//===----------------------------------------------------------------------===//
//
// This file is part of the vendored, patched swift-nio-ssh. See Vendor/PATCH.md.
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import Crypto
import NIOCore
import XCTest

@testable import NIOSSH

/// The `packet_length` header is read before anything authenticates it. These pin that a
/// peer cannot use it to crash us or to make us buffer without bound.
///
/// Both failures were reachable from the first packet of a connection, before key exchange
/// and therefore before the peer has proved anything whatsoever.
final class PacketLengthBoundTests: XCTestCase {
    private func keys(for scheme: NIOSSHTransportProtection.Type) -> NIOSSHSessionKeys {
        NIOSSHSessionKeys(
            initialInboundIV: .init(randomBytes: scheme.keySizes.ivSize),
            initialOutboundIV: .init(randomBytes: scheme.keySizes.ivSize),
            inboundEncryptionKey: SymmetricKey(data: [UInt8](randomBytes: scheme.keySizes.encryptionKeySize)),
            outboundEncryptionKey: SymmetricKey(data: [UInt8](randomBytes: scheme.keySizes.encryptionKeySize)),
            inboundMACKey: SymmetricKey(data: [UInt8](randomBytes: scheme.keySizes.macKeySize)),
            outboundMACKey: SymmetricKey(data: [UInt8](randomBytes: scheme.keySizes.macKeySize))
        )
    }

    /// A parser past the version exchange, optionally encrypted.
    private func parser(protection: NIOSSHTransportProtection? = nil) throws -> SSHPacketParser {
        var parser = SSHPacketParser(isServer: false, allocator: ByteBufferAllocator())
        var version = ByteBufferAllocator().buffer(capacity: 32)
        version.writeString("SSH-2.0-Test\r\n")
        parser.append(bytes: &version)
        _ = try parser.nextPacket()
        if let protection { parser.addEncryption(protection) }
        return parser
    }

    private func feed(_ parser: inout SSHPacketParser, length: UInt32, trailing: Int = 64) {
        var buffer = ByteBufferAllocator().buffer(capacity: trailing + 4)
        buffer.writeInteger(length)
        buffer.writeBytes([UInt8](repeating: 0, count: trailing))
        parser.append(bytes: &buffer)
    }

    /// The crash. `decryptLength` returns `length + UInt32(macBytes)`; at `UInt32.max` that
    /// addition overflows, and Swift traps rather than wrapping — one packet from a
    /// malicious server took the whole process down with SIGTRAP, no error, no reconnect.
    func testAnOverflowingLengthThrowsRatherThanTrapping() throws {
        let scheme = AES128GCMOpenSSHTransportProtection.self
        var parser = try self.parser(protection: try scheme.init(initialKeys: self.keys(for: scheme)))
        self.feed(&parser, length: .max)

        XCTAssertThrowsError(try parser.nextPacket())
    }

    /// Every length within a MAC's width of the top overflows, so check the whole window
    /// rather than only `UInt32.max`. The window is as wide as the largest `macBytes` we
    /// now negotiate — 64, for `hmac-sha2-512`.
    func testTheWholeOverflowWindowThrows() throws {
        let scheme = AES256CTRSHA512TransportProtection.self
        for offset in 0..<UInt32(scheme.keySizes.macKeySize) {
            var parser = try self.parser(protection: try scheme.init(initialKeys: self.keys(for: scheme)))
            self.feed(&parser, length: UInt32.max - offset)
            XCTAssertThrowsError(
                try parser.nextPacket(),
                "length \(UInt32.max - offset) should be refused, not added to macBytes")
        }
    }

    /// The buffering half: a length that does not overflow but names gigabytes was believed
    /// and waited on. This one used to "succeed" by returning nil and holding the
    /// connection open forever.
    func testAnAbsurdButNonOverflowingLengthIsRefused() throws {
        let scheme = AES128GCMOpenSSHTransportProtection.self
        var parser = try self.parser(protection: try scheme.init(initialKeys: self.keys(for: scheme)))
        self.feed(&parser, length: 0xFFFF_FF00)

        XCTAssertThrowsError(try parser.nextPacket())
    }

    /// The cleartext path runs before key exchange, so it faces a completely unproven peer.
    func testTheCleartextPathIsBoundedToo() throws {
        var parser = try self.parser()
        self.feed(&parser, length: .max)

        XCTAssertThrowsError(try parser.nextPacket())
    }

    /// The boundary, from both sides: one byte over is refused, and the limit itself is
    /// still accepted (returns nil, waiting for the rest) so the bound cannot silently
    /// creep below what we advertise.
    func testTheBoundIsExclusiveAtTheRightPlace() throws {
        var overLimit = try self.parser()
        self.feed(&overLimit, length: Constants.maximumPacketLength + 1)
        XCTAssertThrowsError(try overLimit.nextPacket())

        var atLimit = try self.parser()
        self.feed(&atLimit, length: Constants.maximumPacketLength)
        XCTAssertNoThrow(XCTAssertNil(try atLimit.nextPacket()))
    }

    /// The bound must not be below the `maximumPacketSize` this implementation advertises
    /// when it opens a channel, or we would refuse traffic we invited.
    func testTheBoundCoversWhatWeAdvertiseOnAChannel() {
        XCTAssertGreaterThanOrEqual(Constants.maximumPacketLength, 1 << 24)
    }
}
