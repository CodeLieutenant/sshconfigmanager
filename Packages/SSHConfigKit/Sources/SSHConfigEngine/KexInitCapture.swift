//
//  KexInitCapture.swift
//  SSHConfigMacUI
//
//  Reads the algorithm lists a server advertises, straight off the wire.
//
//  This is the only view that catches a server which *supports* something broken. The
//  negotiated audit cannot: this engine implements nothing weak, so it would never agree to
//  `3des-cbc` or `hmac-sha1` no matter what the peer offers — which is good, and also means
//  a server happily accepting them elsewhere looks clean from here.
//
//  SSH_MSG_KEXINIT is the first binary packet after the version exchange and it is sent
//  before any keys exist, so it is plaintext. Sitting in front of `NIOSSHHandler` and
//  parsing a copy costs one packet and changes nothing about the handshake.
//
//  Packet layout (RFC 4253 § 6 and § 7.1), all lengths big-endian:
//    uint32 packet_length · byte padding_length · byte msg_id(20) · byte[16] cookie
//    · 10 × name-list (uint32 length + comma-separated ASCII) · boolean · uint32
//

import Foundation
import NIOCore
import SSHConfigCore

/// The algorithm lists a peer advertised, in its own preference order.
public struct PeerAlgorithmOffer: Sendable, Equatable {
    public var keyExchange: [String] = []
    public var hostKey: [String] = []
    /// Client-to-server and server-to-client are almost always identical; the UI shows one
    /// list, so keep the server-to-client direction, which is what it sends us.
    public var ciphers: [String] = []
    public var macs: [String] = []

    public init(
        keyExchange: [String] = [], hostKey: [String] = [],
        ciphers: [String] = [], macs: [String] = []
    ) {
        self.keyExchange = keyExchange
        self.hostKey = hostKey
        self.ciphers = ciphers
        self.macs = macs
    }

    /// Every offered algorithm judged, worst first. Host keys are judged as signature
    /// algorithm names, because that is what a KEXINIT list contains.
    public var weaknesses: [ServerAlgorithmAudit.Verdict] {
        var verdicts: [ServerAlgorithmAudit.Verdict] = []
        verdicts += self.keyExchange.map { ServerAlgorithmAudit.verdict(role: .keyExchange, name: $0) }
        verdicts += self.hostKey.map { ServerAlgorithmAudit.hostKeyVerdict(type: $0) }
        verdicts += self.ciphers.map { ServerAlgorithmAudit.verdict(role: .cipher, name: $0) }
        verdicts += self.macs.map { ServerAlgorithmAudit.verdict(role: .mac, name: $0) }
        return ServerAlgorithmAudit.weaknesses(in: verdicts)
    }

    /// All four lists with every entry's verdict, for the detail view.
    public func verdicts(for role: ServerAlgorithmAudit.Role) -> [ServerAlgorithmAudit.Verdict] {
        switch role {
        case .keyExchange: return self.keyExchange.map { ServerAlgorithmAudit.verdict(role: .keyExchange, name: $0) }
        case .hostKey: return self.hostKey.map { ServerAlgorithmAudit.hostKeyVerdict(type: $0) }
        case .cipher: return self.ciphers.map { ServerAlgorithmAudit.verdict(role: .cipher, name: $0) }
        case .mac: return self.macs.map { ServerAlgorithmAudit.verdict(role: .mac, name: $0) }
        }
    }

    public var isEmpty: Bool {
        self.keyExchange.isEmpty && self.hostKey.isEmpty && self.ciphers.isEmpty && self.macs.isEmpty
    }
}

/// Parses a peer's `SSH_MSG_KEXINIT`. Split from the handler so it is testable against a
/// captured packet without a channel.
public enum KexInitParser {
    public static let messageID: UInt8 = 20

    /// Returns nil unless `packet` is a complete, well-formed KEXINIT. Every read is
    /// bounds-checked: this runs on bytes from an unauthenticated peer, before any key
    /// exchange has happened, so a malformed packet must be ignored rather than trusted.
    public static func parse(_ packet: ByteBuffer) -> PeerAlgorithmOffer? {
        var buffer = packet
        // Slice the declared packet out first, and read only from that. Bounding each
        // field by the whole buffer instead let a truncated KEXINIT keep reading into
        // whatever bytes happened to follow it, and report algorithm names assembled
        // from the next packet.
        guard let packetLength = buffer.readInteger(as: UInt32.self),
            packetLength >= 2,
            var body = buffer.readSlice(length: Int(packetLength)),
            let paddingLength = body.readInteger(as: UInt8.self),
            let messageID = body.readInteger(as: UInt8.self), messageID == Self.messageID,
            body.readSlice(length: 16) != nil // cookie
        else { return nil }

        // Ten name-lists in a fixed order; we keep four of them.
        var lists: [[String]] = []
        for _ in 0..<10 {
            guard let list = readNameList(&body) else { return nil }
            lists.append(list)
        }

        // first_kex_packet_follows, then the reserved uint32. What is left has to be
        // exactly the padding the header declared — RFC 4253 § 7.1 fixes this layout, so
        // anything else means we did not parse what we think we parsed.
        guard body.readInteger(as: UInt8.self) != nil,
            body.readInteger(as: UInt32.self) != nil,
            body.readableBytes == Int(paddingLength)
        else { return nil }

        return PeerAlgorithmOffer(
            keyExchange: lists[0],
            hostKey: lists[1],
            // 2/3 are the cipher lists (c→s, s→c), 4/5 the MACs, 6/7 compression,
            // 8/9 languages. The server-to-client direction is what it sends us.
            ciphers: lists[3],
            macs: lists[5])
    }

    private static func readNameList(_ buffer: inout ByteBuffer) -> [String]? {
        guard let length = buffer.readInteger(as: UInt32.self),
            length <= UInt32(buffer.readableBytes),
            let bytes = buffer.readSlice(length: Int(length))
        else { return nil }
        let text = String(buffer: bytes)
        guard !text.isEmpty else { return [] }
        return text.split(separator: ",").map(String.init)
    }
}

/// Copies the peer's KEXINIT out of the inbound stream and hands it to `onOffer`, then
/// stops looking. Forwards every byte untouched.
public final class KexInitCaptureHandler: ChannelInboundHandler, @unchecked Sendable {
    public typealias InboundIn = ByteBuffer
    public typealias InboundOut = ByteBuffer

    /// A KEXINIT is a couple of kilobytes. Anything much larger means this is not the
    /// packet we are looking for, and holding on to it helps nobody.
    private static let maximumBuffered = 64 * 1024

    private let onOffer: @Sendable (PeerAlgorithmOffer) -> Void
    private var done = false
    /// Whether the peer's version line has been consumed. Until it has, `pending` starts
    /// with text lines rather than a binary packet.
    private var sawVersionLine = false
    /// The version line and the first packet can arrive in one read, or split across
    /// several. Accumulate until a whole packet is present.
    private var pending = ByteBuffer()

    public init(onOffer: @escaping @Sendable (PeerAlgorithmOffer) -> Void) {
        self.onOffer = onOffer
    }

    public func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let buffer = self.unwrapInboundIn(data)
        if !self.done {
            var copy = buffer
            self.pending.writeBuffer(&copy)
            self.consume()
        }
        context.fireChannelRead(data)
    }

    private func consume() {
        if !self.sawVersionLine {
            guard self.skipToEndOfVersionLine() else {
                if self.pending.readableBytes > Self.maximumBuffered { self.stop() }
                return
            }
            self.pending.discardReadBytes()
        }

        if let offer = KexInitParser.parse(self.pending) {
            self.stop()
            self.onOffer(offer)
            return
        }
        if self.pending.readableBytes > Self.maximumBuffered { self.stop() }
    }

    /// Drops every line up to and including the peer's version line, returning false while
    /// that line has not fully arrived.
    ///
    /// RFC 4253 § 4.2 lets a server send any number of other lines before its version
    /// string, and hardened servers commonly do — a pre-auth banner. Looking only at the
    /// front of the buffer parked the reader on the banner forever, so on exactly those
    /// servers the capture silently produced nothing.
    private func skipToEndOfVersionLine() -> Bool {
        while true {
            let view = self.pending.readableBytesView
            guard let newline = view.firstIndex(of: UInt8(ascii: "\n")) else { return false }
            let isVersion = view.starts(with: "SSH-".utf8)
            self.pending.moveReaderIndex(forwardBy: view.distance(from: view.startIndex, to: newline) + 1)
            if isVersion {
                self.sawVersionLine = true
                return true
            }
        }
    }

    private func stop() {
        self.done = true
        self.pending = ByteBuffer()
    }
}
