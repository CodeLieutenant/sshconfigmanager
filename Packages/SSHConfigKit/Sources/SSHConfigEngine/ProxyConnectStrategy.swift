import Foundation
import NIOCore
import NIOPosix
import SSHConfigCore

public nonisolated struct ProxyCommandUnavailableError: Error, LocalizedError {
    public let commandLine: String

    public init(commandLine: String) {
        self.commandLine = commandLine
    }

    public var errorDescription: String? {
        "This host's ProxyCommand (\"\(commandLine)\") isn't one of the patterns this app runs in-process "
            + "(\"ssh -W\", a SOCKS5 proxy, or an HTTP CONNECT proxy), and the Mac App Store build can't run "
            + "an external command for it. Use the unsandboxed direct-download build to run it as-is."
    }
}

public protocol ProxyConnectStrategy: Sendable {
    var displayName: String { get }
    func connect(
        group: EventLoopGroup, targetHost: String, targetPort: Int, username: String,
        log: @escaping @Sendable (TunnelLogLevel, String) -> Void,
        channelInitializer: @escaping @Sendable (Channel) -> EventLoopFuture<Void>
    ) -> EventLoopFuture<Channel>
}

public enum ProxyConnectStrategyFactory {
    public static func make(for hop: ConnectionHop, subprocessCapable: Bool) -> any ProxyConnectStrategy {
        switch hop.proxyCommandTransport {
        case nil:
            return DirectTCPConnectStrategy(
                tcpKeepAlive: hop.tcpKeepAlive, connectTimeout: hop.connectTimeout, bindAddress: hop.bindAddress)
        case .socks5(let host, let port):
            return SOCKS5ConnectStrategy(proxyHost: host, proxyPort: port)
        case .httpConnect(let host, let port):
            return HTTPConnectConnectStrategy(proxyHost: host, proxyPort: port)
        case .rawSubprocess(let commandLine):
            return subprocessCapable
                ? SubprocessConnectStrategy(commandLine: commandLine)
                : UnsupportedProxyConnectStrategy(commandLine: commandLine)
        }
    }
}

public struct DirectTCPConnectStrategy: ProxyConnectStrategy {
    public let tcpKeepAlive: Bool
    public let connectTimeout: Int?
    public let bindAddress: String?
    public var displayName: String { "a direct connection" }

    public init(tcpKeepAlive: Bool, connectTimeout: Int?, bindAddress: String?) {
        self.tcpKeepAlive = tcpKeepAlive
        self.connectTimeout = connectTimeout
        self.bindAddress = bindAddress
    }

    public func connect(
        group: EventLoopGroup, targetHost: String, targetPort: Int, username: String,
        log: @escaping @Sendable (TunnelLogLevel, String) -> Void,
        channelInitializer: @escaping @Sendable (Channel) -> EventLoopFuture<Void>
    ) -> EventLoopFuture<Channel> {
        var bootstrap = ClientBootstrap(group: group)
            .channelInitializer(channelInitializer)
            .channelOption(.socketOption(.so_reuseaddr), value: 1)
        if tcpKeepAlive {
            bootstrap = bootstrap.channelOption(.socketOption(.so_keepalive), value: 1)
        }
        if let seconds = connectTimeout, seconds > 0 {
            bootstrap = bootstrap.connectTimeout(.seconds(Int64(seconds)))
        }
        if let bindAddress, !bindAddress.isEmpty {
            if let source = try? SocketAddress(ipAddress: bindAddress, port: 0) {
                bootstrap = bootstrap.bind(to: source)
            } else {
                log(.error, "BindAddress “\(bindAddress)” isn't a literal IP — ignoring it")
            }
        }
        return bootstrap.connect(host: targetHost, port: targetPort)
    }
}

public struct SOCKS5ConnectStrategy: ProxyConnectStrategy {
    public let proxyHost: String
    public let proxyPort: Int
    public var displayName: String { "SOCKS5 proxy \(proxyHost):\(proxyPort)" }

    public init(proxyHost: String, proxyPort: Int) {
        self.proxyHost = proxyHost
        self.proxyPort = proxyPort
    }

    public func connect(
        group: EventLoopGroup, targetHost: String, targetPort: Int, username: String,
        log: @escaping @Sendable (TunnelLogLevel, String) -> Void,
        channelInitializer: @escaping @Sendable (Channel) -> EventLoopFuture<Void>
    ) -> EventLoopFuture<Channel> {
        ProxyDialTransport.connectViaSOCKS5(
            group: group, proxyHost: proxyHost, proxyPort: proxyPort, targetHost: targetHost,
            targetPort: targetPort, channelInitializer: channelInitializer)
    }
}

public struct HTTPConnectConnectStrategy: ProxyConnectStrategy {
    public let proxyHost: String
    public let proxyPort: Int
    public var displayName: String { "HTTP CONNECT proxy \(proxyHost):\(proxyPort)" }

    public init(proxyHost: String, proxyPort: Int) {
        self.proxyHost = proxyHost
        self.proxyPort = proxyPort
    }

    public func connect(
        group: EventLoopGroup, targetHost: String, targetPort: Int, username: String,
        log: @escaping @Sendable (TunnelLogLevel, String) -> Void,
        channelInitializer: @escaping @Sendable (Channel) -> EventLoopFuture<Void>
    ) -> EventLoopFuture<Channel> {
        ProxyDialTransport.connectViaHTTPConnect(
            group: group, proxyHost: proxyHost, proxyPort: proxyPort, targetHost: targetHost,
            targetPort: targetPort, channelInitializer: channelInitializer)
    }
}

public struct SubprocessConnectStrategy: ProxyConnectStrategy {
    public let commandLine: String
    public var displayName: String { "ProxyCommand" }

    public init(commandLine: String) {
        self.commandLine = commandLine
    }

    public func connect(
        group: EventLoopGroup, targetHost: String, targetPort: Int, username: String,
        log: @escaping @Sendable (TunnelLogLevel, String) -> Void,
        channelInitializer: @escaping @Sendable (Channel) -> EventLoopFuture<Void>
    ) -> EventLoopFuture<Channel> {
        ProxyCommandTransport.connect(
            group: group, commandLine: commandLine, host: targetHost, port: targetPort, username: username,
            channelInitializer: channelInitializer)
    }
}

public struct UnsupportedProxyConnectStrategy: ProxyConnectStrategy {
    public let commandLine: String
    public var displayName: String { "an unsupported ProxyCommand" }

    public init(commandLine: String) {
        self.commandLine = commandLine
    }

    public func connect(
        group: EventLoopGroup, targetHost: String, targetPort: Int, username: String,
        log: @escaping @Sendable (TunnelLogLevel, String) -> Void,
        channelInitializer: @escaping @Sendable (Channel) -> EventLoopFuture<Void>
    ) -> EventLoopFuture<Channel> {
        group.next().makeFailedFuture(ProxyCommandUnavailableError(commandLine: commandLine))
    }
}
