import SSHConfigCore
import Testing

struct ProxyCommandParserTests {
    @Test func recognizesSSHDashWWithBastionLast() {
        #expect(
            ProxyCommandParser.recognize("ssh -W %h:%p bastion.example.com")
                == .sshWJumpHost(bastion: "bastion.example.com"))
    }

    @Test func recognizesSSHDashWWithExtraFlagsBeforeBastion() {
        #expect(
            ProxyCommandParser.recognize("ssh -q -o StrictHostKeyChecking=no -W %h:%p bastion")
                == .sshWJumpHost(bastion: "bastion"))
    }

    @Test func recognizesNetcatSOCKS5WithExplicitProtocol() {
        #expect(
            ProxyCommandParser.recognize("nc -X 5 -x proxy.example.com:1080 %h %p")
                == .socks5(host: "proxy.example.com", port: 1080))
    }

    @Test func recognizesBareDashXAsSOCKS5() {
        #expect(
            ProxyCommandParser.recognize("nc -x 10.0.0.1:1080 %h %p")
                == .socks5(host: "10.0.0.1", port: 1080))
    }

    @Test func recognizesNetcatHTTPConnect() {
        #expect(
            ProxyCommandParser.recognize("ncat -X connect -x proxy.example.com:3128 %h %p")
                == .httpConnect(host: "proxy.example.com", port: 3128))
    }

    @Test func recognizesConnectProxySOCKS5() {
        #expect(
            ProxyCommandParser.recognize("connect -S 10.0.0.1:1080 %h %p")
                == .socks5(host: "10.0.0.1", port: 1080))
    }

    @Test func recognizesConnectProxyHTTPConnect() {
        #expect(
            ProxyCommandParser.recognize("connect-proxy -H proxy.example.com:8080 %h %p")
                == .httpConnect(host: "proxy.example.com", port: 8080))
    }

    @Test func recognizesCorkscrew() {
        #expect(
            ProxyCommandParser.recognize("corkscrew proxy.example.com 3128 %h %p")
                == .httpConnect(host: "proxy.example.com", port: 3128))
    }

    @Test func unrecognizedCommandsReturnNil() {
        #expect(ProxyCommandParser.recognize("cloudflared access ssh --hostname %h") == nil)
        #expect(ProxyCommandParser.recognize("nc %h %p") == nil)
        #expect(ProxyCommandParser.recognize("") == nil)
    }
}
