//
//  SSHChannelHandlers.swift
//  sshconfigmanager
//
//  NIO channel handlers: SSH data wrap/unwrap, byte-glue between channels, SOCKS5.
//  Split out of NIOTunnelEngine.swift.
//

import Crypto
import Foundation
import NIOCore
import NIOPosix
import NIOSSH
import NIOSSHRSA
import SSHConfigCore
import SSHConfigCrypto

// MARK: - Channel glue (adapted from the swift-nio-ssh NIOSSHClient example)

/// Wraps/unwraps raw bytes into `SSHChannelData` on the SSH child channel.
public nonisolated final class SSHWrapperHandler: ChannelDuplexHandler {
    public typealias InboundIn = SSHChannelData
    public typealias InboundOut = ByteBuffer
    public typealias OutboundIn = ByteBuffer
    public typealias OutboundOut = SSHChannelData

    /// Counter for forward-data channels; nil when bridging inner-hop SSH transport
    /// (ProxyJump), whose bytes aren't user throughput.
    private let counter: ByteCounter?
    public init(counter: ByteCounter?) { self.counter = counter }

    public func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let data = unwrapInboundIn(data)
        guard case .channel = data.type, case .byteBuffer(let buffer) = data.data else {
            context.fireErrorCaught(SSHForwardError.invalidData)
            return
        }
        counter?.addIn(buffer.readableBytes) // bytes arriving from the SSH link
        context.fireChannelRead(wrapInboundOut(buffer))
    }

    public func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        let buffer = unwrapOutboundIn(data)
        counter?.addOut(buffer.readableBytes) // bytes leaving toward the SSH link
        context.write(wrapOutboundOut(SSHChannelData(type: .channel, data: .byteBuffer(buffer))), promise: promise)
    }
}

/// Pumps data bidirectionally between two channels (local socket ↔ SSH channel).
public nonisolated final class GlueHandler {
    private var partner: GlueHandler?
    private var context: ChannelHandlerContext?
    private var pendingRead = false

    private init() {}

    public static func matchedPair() -> (GlueHandler, GlueHandler) {
        let first = GlueHandler()
        let second = GlueHandler()
        first.partner = second
        second.partner = first
        return (first, second)
    }

    private func partnerWrite(_ data: NIOAny) { context?.write(data, promise: nil) }
    private func partnerFlush() { context?.flush() }
    private func partnerWriteEOF() { context?.close(mode: .output, promise: nil) }
    private func partnerCloseFull() { context?.close(promise: nil) }
    private func partnerBecameWritable() {
        if pendingRead {
            pendingRead = false
            context?.read()
        }
    }
    private var partnerWritable: Bool { context?.channel.isWritable ?? false }
}

extension GlueHandler: ChannelDuplexHandler {
    public typealias InboundIn = NIOAny
    public typealias OutboundIn = NIOAny
    public typealias OutboundOut = NIOAny

    public func handlerAdded(context: ChannelHandlerContext) {
        self.context = context
        if context.channel.isWritable { partner?.partnerBecameWritable() }
    }

    public func handlerRemoved(context: ChannelHandlerContext) {
        self.context = nil
        partner = nil
    }

    public func channelRead(context: ChannelHandlerContext, data: NIOAny) { partner?.partnerWrite(data) }
    public func channelReadComplete(context: ChannelHandlerContext) { partner?.partnerFlush() }
    public func channelInactive(context: ChannelHandlerContext) { partner?.partnerCloseFull() }

    public func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if let event = event as? ChannelEvent, case .inputClosed = event {
            partner?.partnerWriteEOF()
        }
    }

    public func errorCaught(context: ChannelHandlerContext, error: Error) { partner?.partnerCloseFull() }

    public func channelWritabilityChanged(context: ChannelHandlerContext) {
        if context.channel.isWritable { partner?.partnerBecameWritable() }
    }

    public func read(context: ChannelHandlerContext) {
        if let partner, partner.partnerWritable {
            context.read()
        } else {
            pendingRead = true
        }
    }
}

// MARK: - SOCKS5 inbound handler (dynamic -D forwards)

/// Handles the SOCKS5 greeting + CONNECT on a locally-accepted connection, opens
/// a direct-tcpip channel to the requested target, then removes itself and lets
/// the glue handlers pump data. (No-auth only; the common case where the client
/// waits for the reply before sending data.)
// @unchecked Sendable: a NIO channel handler runs confined to its channel's event
// loop, so its buffer/state is never accessed concurrently.
public nonisolated final class SOCKS5InboundHandler: ChannelInboundHandler, RemovableChannelHandler, @unchecked Sendable
{
    public typealias InboundIn = ByteBuffer

    private enum State { case greeting, request, connecting, done }
    private var state: State = .greeting
    private var buffer: [UInt8] = []
    private let handlerBox: NIOLoopBoundBox<NIOSSHHandler>
    private let counter: ByteCounter
    private let log: @Sendable (TunnelLogLevel, String) -> Void

    public init(
        handlerBox: NIOLoopBoundBox<NIOSSHHandler>, counter: ByteCounter,
        log: @escaping @Sendable (TunnelLogLevel, String) -> Void = { _, _ in }
    ) {
        self.handlerBox = handlerBox
        self.counter = counter
        self.log = log
    }

    public func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let input = unwrapInboundIn(data)
        buffer.append(contentsOf: input.readableBytesView)
        advance(channel: context.channel)
    }

    private func advance(channel: Channel) {
        switch state {
        case .greeting:
            do {
                let acceptable = try SOCKS5.parseGreeting(buffer)
                buffer.removeFirst(2 + Int(buffer[1]))
                guard acceptable else {
                    send([SOCKS5.version, 0xFF], on: channel) // no acceptable methods
                    channel.close(promise: nil)
                    return
                }
                send(SOCKS5.methodSelection(), on: channel)
                state = .request
                advance(channel: channel) // a request may already be buffered
            } catch SOCKS5.ParseError.incomplete {
            } catch { channel.close(promise: nil) }

        case .request:
            do {
                let target = try SOCKS5.parseConnectRequest(buffer)
                let (targetHost, targetPort) = (target.host, target.port)
                buffer.removeFirst(SOCKS5.connectRequestLength(buffer)) // drop the consumed request
                let earlyData = buffer // any pipelined client bytes
                buffer = []
                state = .connecting
                NIOTunnelConnection.openDirectTCPIP(
                    from: channel, handlerBox: handlerBox,
                    targetHost: target.host, targetPort: target.port,
                    counter: counter, initialData: earlyData
                ).whenComplete { result in
                    switch result {
                    case .success(let childChannel):
                        // `channelRead` above keeps appending to `buffer` even while
                        // `.connecting` (that state's `advance()` case is a no-op, by
                        // design, since there's nowhere to send bytes yet) — so
                        // anything a pipelining/optimistic-data client sent during
                        // this channel-open round trip is sitting right here. Flush
                        // it now, before removing self hands `channel` over to the
                        // glue handlers, or it's silently lost (audit #30). This is
                        // distinct from `earlyData` above, which only covers bytes
                        // that arrived *before* `openDirectTCPIP` was even called.
                        if !self.buffer.isEmpty {
                            var late = childChannel.allocator.buffer(capacity: self.buffer.count)
                            late.writeBytes(self.buffer)
                            self.counter.addOut(self.buffer.count)
                            childChannel.writeAndFlush(late, promise: nil)
                            self.buffer = []
                        }
                        self.send(SOCKS5.connectReply(.success), on: channel)
                        self.state = .done
                        _ = channel.pipeline.removeHandler(self)
                    case .failure(let error):
                        self.log(
                            .error,
                            SSHErrorText.describeForwardRejection(
                                error, targetHost: targetHost, targetPort: targetPort))
                        self.send(SOCKS5.connectReply(.generalFailure), on: channel)
                        channel.close(promise: nil)
                    }
                }
            } catch SOCKS5.ParseError.incomplete {
            } catch SOCKS5.ParseError.unsupportedCommand {
                send(SOCKS5.connectReply(.commandNotSupported), on: channel)
                channel.close(promise: nil)
            } catch SOCKS5.ParseError.unsupportedAddress {
                send(SOCKS5.connectReply(.addressTypeNotSupported), on: channel)
                channel.close(promise: nil)
            } catch {
                send(SOCKS5.connectReply(.generalFailure), on: channel)
                channel.close(promise: nil)
            }

        case .connecting, .done:
            break
        }
    }

    private func send(_ bytes: [UInt8], on channel: Channel) {
        var out = channel.allocator.buffer(capacity: bytes.count)
        out.writeBytes(bytes)
        channel.writeAndFlush(out, promise: nil)
    }
}
