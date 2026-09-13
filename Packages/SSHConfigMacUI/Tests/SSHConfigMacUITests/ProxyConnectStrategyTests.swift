import NIOPosix
import SSHConfigCore
import SSHConfigEngine
import Testing

struct ProxyConnectStrategyTests {
    private func hop(_ transport: ProxyCommandTransportKind?) -> ConnectionHop {
        ConnectionHop(host: "target.example.com", port: 22, username: "deploy", auth: .keyboardInteractive)
            .settingProxyCommandTransport(transport)
    }

    @Test func noTransportPicksDirectTCP() {
        let strategy = ProxyConnectStrategyFactory.make(for: hop(nil), subprocessCapable: false)
        #expect(strategy is DirectTCPConnectStrategy)
    }

    @Test func socks5PicksSOCKS5Strategy() {
        let strategy = ProxyConnectStrategyFactory.make(
            for: hop(.socks5(host: "10.0.0.1", port: 1080)), subprocessCapable: false)
        #expect(strategy is SOCKS5ConnectStrategy)
        #expect(strategy.displayName == "SOCKS5 proxy 10.0.0.1:1080")
    }

    @Test func httpConnectPicksHTTPConnectStrategy() {
        let strategy = ProxyConnectStrategyFactory.make(
            for: hop(.httpConnect(host: "proxy.example.com", port: 3128)), subprocessCapable: false)
        #expect(strategy is HTTPConnectConnectStrategy)
        #expect(strategy.displayName == "HTTP CONNECT proxy proxy.example.com:3128")
    }

    @Test func rawSubprocessPicksSubprocessStrategyWhenCapable() {
        let strategy = ProxyConnectStrategyFactory.make(
            for: hop(.rawSubprocess("cloudflared access ssh")), subprocessCapable: true)
        #expect(strategy is SubprocessConnectStrategy)
    }

    @Test func rawSubprocessPicksUnsupportedStrategyWhenNotCapable() {
        let strategy = ProxyConnectStrategyFactory.make(
            for: hop(.rawSubprocess("cloudflared access ssh")), subprocessCapable: false)
        #expect(strategy is UnsupportedProxyConnectStrategy)
    }

    @Test func unsupportedStrategyFailsImmediatelyWithAClearMessage() throws {
        let strategy = UnsupportedProxyConnectStrategy(commandLine: "cloudflared access ssh --hostname %h")
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { try? group.syncShutdownGracefully() }
        let future = strategy.connect(
            group: group, targetHost: "target.example.com", targetPort: 22, username: "deploy",
            log: { _, _ in }, channelInitializer: { $0.eventLoop.makeSucceededVoidFuture() })
        do {
            _ = try future.wait()
            Issue.record("expected the future to fail")
        } catch let error as ProxyCommandUnavailableError {
            #expect(error.commandLine == "cloudflared access ssh --hostname %h")
            #expect(error.errorDescription?.contains("Mac App Store") == true)
            #expect(error.errorDescription?.contains("direct-download") == true)
        }
    }
}

extension ConnectionHop {
    fileprivate func settingProxyCommandTransport(_ transport: ProxyCommandTransportKind?) -> ConnectionHop {
        var copy = self
        copy.proxyCommandTransport = transport
        return copy
    }
}
