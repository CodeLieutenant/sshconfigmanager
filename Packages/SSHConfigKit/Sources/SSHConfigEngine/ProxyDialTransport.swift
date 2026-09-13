import Foundation
import NIOCore
import NIOPosix

#if canImport(Glibc)
    import Glibc
#else
    import Darwin
#endif

public nonisolated enum ProxyDialError: Error, LocalizedError {
    case socks5Rejected(replyCode: UInt8)
    case socks5MalformedReply
    case httpConnectRejected(statusLine: String)

    public var errorDescription: String? {
        switch self {
        case .socks5Rejected(let code): return "The SOCKS5 proxy refused the connection (reply code \(code))."
        case .socks5MalformedReply: return "The SOCKS5 proxy sent a reply this engine couldn't parse."
        case .httpConnectRejected(let statusLine): return "The HTTP CONNECT proxy refused the connection: \(statusLine)"
        }
    }
}

private func ipv4Octets(_ string: String) -> [UInt8]? {
    var addr = in_addr()
    guard string.withCString({ inet_pton(AF_INET, $0, &addr) }) == 1 else { return nil }
    let value = addr.s_addr
    return [
        UInt8(truncatingIfNeeded: value), UInt8(truncatingIfNeeded: value >> 8),
        UInt8(truncatingIfNeeded: value >> 16), UInt8(truncatingIfNeeded: value >> 24),
    ]
}

private func ipv6Octets(_ string: String) -> [UInt8]? {
    var addr = in6_addr()
    guard string.withCString({ inet_pton(AF_INET6, $0, &addr) }) == 1 else { return nil }
    return withUnsafeBytes(of: &addr) { Array($0) }
}

enum ProxyDialTransport {
    static func connectViaSOCKS5(
        group: EventLoopGroup, proxyHost: String, proxyPort: Int, targetHost: String, targetPort: Int,
        channelInitializer: @escaping @Sendable (Channel) -> EventLoopFuture<Void>
    ) -> EventLoopFuture<Channel> {
        dial(
            group: group, proxyHost: proxyHost, proxyPort: proxyPort,
            makeHandler: { SOCKS5HandshakeHandler(targetHost: targetHost, targetPort: targetPort) },
            handlerName: SOCKS5HandshakeHandler.handlerName, channelInitializer: channelInitializer)
    }

    static func connectViaHTTPConnect(
        group: EventLoopGroup, proxyHost: String, proxyPort: Int, targetHost: String, targetPort: Int,
        channelInitializer: @escaping @Sendable (Channel) -> EventLoopFuture<Void>
    ) -> EventLoopFuture<Channel> {
        dial(
            group: group, proxyHost: proxyHost, proxyPort: proxyPort,
            makeHandler: { HTTPConnectHandshakeHandler(targetHost: targetHost, targetPort: targetPort) },
            handlerName: HTTPConnectHandshakeHandler.handlerName, channelInitializer: channelInitializer)
    }

    private static func dial<Handler: ProxyHandshakeHandler>(
        group: EventLoopGroup, proxyHost: String, proxyPort: Int,
        makeHandler: @escaping @Sendable () -> Handler, handlerName: String,
        channelInitializer: @escaping @Sendable (Channel) -> EventLoopFuture<Void>
    ) -> EventLoopFuture<Channel> {
        ClientBootstrap(group: group.next())
            .channelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandler(makeHandler(), name: handlerName)
                }
            }
            .connect(host: proxyHost, port: proxyPort)
            .flatMap { channel in
                channel.pipeline.handler(type: Handler.self).flatMap { $0.completion }
            }
            .flatMap { channel in
                channel.pipeline.removeHandler(name: handlerName)
                    .flatMap { channelInitializer(channel) }
                    .map { channel }
            }
    }
}

private protocol ProxyHandshakeHandler: ChannelInboundHandler, RemovableChannelHandler {
    var completion: EventLoopFuture<Channel> { get }
}

private final class SOCKS5HandshakeHandler: ProxyHandshakeHandler {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    static let handlerName = "SOCKS5HandshakeHandler"

    private enum Stage { case awaitingMethodSelection, awaitingConnectReply }

    private let targetHost: String
    private let targetPort: Int
    private var stage: Stage = .awaitingMethodSelection
    private var buffer = ByteBuffer()
    private var promise: EventLoopPromise<Channel>?
    var completion: EventLoopFuture<Channel> { promise!.futureResult }

    init(targetHost: String, targetPort: Int) {
        self.targetHost = targetHost
        self.targetPort = targetPort
    }

    func handlerAdded(context: ChannelHandlerContext) {
        promise = context.eventLoop.makePromise(of: Channel.self)
        var greeting = context.channel.allocator.buffer(capacity: 3)
        greeting.writeBytes([0x05, 0x01, 0x00])
        context.writeAndFlush(Self.wrapOutboundOut(greeting), promise: nil)
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var incoming = Self.unwrapInboundIn(data)
        buffer.writeBuffer(&incoming)

        switch stage {
        case .awaitingMethodSelection:
            guard buffer.readableBytes >= 2, let bytes = buffer.readBytes(length: 2) else { return }
            guard bytes[0] == 0x05, bytes[1] == 0x00 else {
                promise?.fail(ProxyDialError.socks5Rejected(replyCode: bytes.count > 1 ? bytes[1] : 0xFF))
                context.close(promise: nil)
                return
            }
            buffer.discardReadBytes()
            stage = .awaitingConnectReply
            sendConnectRequest(context: context)
        case .awaitingConnectReply:
            parseConnectReply(context: context)
        }
    }

    private func sendConnectRequest(context: ChannelHandlerContext) {
        var request = context.channel.allocator.buffer(capacity: 32)
        request.writeBytes([0x05, 0x01, 0x00])
        if let octets = ipv4Octets(targetHost) {
            request.writeBytes([0x01])
            request.writeBytes(octets)
        } else if let octets = ipv6Octets(targetHost) {
            request.writeBytes([0x04])
            request.writeBytes(octets)
        } else {
            let hostBytes = Array(targetHost.utf8.prefix(255))
            request.writeBytes([0x03, UInt8(hostBytes.count)])
            request.writeBytes(hostBytes)
        }
        request.writeInteger(UInt16(targetPort))
        context.writeAndFlush(Self.wrapOutboundOut(request), promise: nil)
    }

    private func parseConnectReply(context: ChannelHandlerContext) {
        guard buffer.readableBytes >= 5 else { return }
        let bytes = buffer.getBytes(at: buffer.readerIndex, length: buffer.readableBytes) ?? []
        guard bytes[0] == 0x05 else {
            promise?.fail(ProxyDialError.socks5MalformedReply)
            context.close(promise: nil)
            return
        }
        let replyCode = bytes[1]
        let addressType = bytes[3]
        let addressLength: Int
        switch addressType {
        case 0x01: addressLength = 4
        case 0x03: addressLength = bytes.count > 4 ? Int(bytes[4]) + 1 : -1
        case 0x04: addressLength = 16
        default:
            promise?.fail(ProxyDialError.socks5MalformedReply)
            context.close(promise: nil)
            return
        }
        guard addressLength >= 0 else { return }
        let totalLength = 4 + addressLength + 2
        guard bytes.count >= totalLength else { return }
        _ = buffer.readBytes(length: totalLength)
        guard replyCode == 0x00 else {
            promise?.fail(ProxyDialError.socks5Rejected(replyCode: replyCode))
            context.close(promise: nil)
            return
        }
        promise?.succeed(context.channel)
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        promise?.fail(error)
        context.close(promise: nil)
    }
}

private final class HTTPConnectHandshakeHandler: ProxyHandshakeHandler {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    static let handlerName = "HTTPConnectHandshakeHandler"

    private let targetHost: String
    private let targetPort: Int
    private var buffer = ByteBuffer()
    private var promise: EventLoopPromise<Channel>?
    var completion: EventLoopFuture<Channel> { promise!.futureResult }

    init(targetHost: String, targetPort: Int) {
        self.targetHost = targetHost
        self.targetPort = targetPort
    }

    func handlerAdded(context: ChannelHandlerContext) {
        promise = context.eventLoop.makePromise(of: Channel.self)
        let request =
            "CONNECT \(targetHost):\(targetPort) HTTP/1.1\r\n"
            + "Host: \(targetHost):\(targetPort)\r\n"
            + "Proxy-Connection: Keep-Alive\r\n\r\n"
        var out = context.channel.allocator.buffer(capacity: request.utf8.count)
        out.writeString(request)
        context.writeAndFlush(Self.wrapOutboundOut(out), promise: nil)
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var incoming = Self.unwrapInboundIn(data)
        buffer.writeBuffer(&incoming)

        let readable = buffer.getString(at: buffer.readerIndex, length: buffer.readableBytes) ?? ""
        guard readable.range(of: "\r\n\r\n") != nil else { return }
        let statusLine = readable.split(separator: "\r\n", maxSplits: 1, omittingEmptySubsequences: false)[0]
        guard statusLine.contains(" 200 ") || statusLine.hasSuffix(" 200") else {
            promise?.fail(ProxyDialError.httpConnectRejected(statusLine: String(statusLine)))
            context.close(promise: nil)
            return
        }
        promise?.succeed(context.channel)
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        promise?.fail(error)
        context.close(promise: nil)
    }
}
