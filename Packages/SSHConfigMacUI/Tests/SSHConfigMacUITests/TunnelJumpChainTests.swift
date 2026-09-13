//
//  TunnelJumpChainTests.swift
//  sshconfigmanagerTests
//
//  The pure ProxyJump chain resolver: spec parsing, chain order, per-hop config
//  inheritance, inline overrides, ProxyCommand rejection, and the loop guard.
//

import Foundation
import SSHConfigCore
import Testing

@testable import SSHConfigMacUI

struct TunnelJumpChainTests {
    private func docs(_ text: String) -> [SSHConfigDocument] {
        [SSHConfigParser.parse(text, sourceURL: URL(fileURLWithPath: "/tmp/config"))]
    }

    // MARK: - parseProxyJump

    @Test func parsesSingleHost() {
        #expect(TunnelJumpChain.parseProxyJump("bastion") == [JumpSpec(user: nil, host: "bastion", port: nil)])
    }

    @Test func parsesUserHostPort() {
        #expect(
            TunnelJumpChain.parseProxyJump("alice@jump.example.com:2222")
                == [JumpSpec(user: "alice", host: "jump.example.com", port: 2222)])
    }

    @Test func parsesMultipleHopsInOrder() {
        let specs = TunnelJumpChain.parseProxyJump("a, bob@b:22 ,c")
        #expect(
            specs == [
                JumpSpec(user: nil, host: "a", port: nil),
                JumpSpec(user: "bob", host: "b", port: 22),
                JumpSpec(user: nil, host: "c", port: nil),
            ])
    }

    @Test func noneAndEmptyYieldNoHops() {
        #expect(TunnelJumpChain.parseProxyJump("none").isEmpty)
        #expect(TunnelJumpChain.parseProxyJump("").isEmpty)
        #expect(TunnelJumpChain.parseProxyJump("   ").isEmpty)
    }

    @Test func parsesBracketedIPv6WithPort() {
        #expect(
            TunnelJumpChain.parseProxyJump("[2001:db8::1]:2022")
                == [JumpSpec(user: nil, host: "2001:db8::1", port: 2022)])
    }

    // MARK: - resolve

    @Test func resolvesTargetOnlyWhenNoProxyJump() throws {
        let chain = try TunnelJumpChain.resolve(
            alias: "web",
            in: docs(
                """
                Host web
                    HostName w.example.com
                    Port 22
                """))
        #expect(chain.count == 1)
        #expect(chain[0].host == "w.example.com")
    }

    @Test func resolvesJumpBeforeTargetWithInheritedConfig() throws {
        let chain = try TunnelJumpChain.resolve(
            alias: "target",
            in: docs(
                """
                Host target
                    HostName t.example.com
                    ProxyJump bastion
                Host bastion
                    HostName b.example.com
                    User jumpuser
                    Port 2222
                """))
        #expect(chain.count == 2)
        #expect(chain[0].host == "b.example.com") // jump first
        #expect(chain[0].port == 2222)
        #expect(chain[0].user == "jumpuser")
        #expect(chain[1].host == "t.example.com") // target last
    }

    @Test func inlineUserAndPortOverrideResolvedAlias() throws {
        let chain = try TunnelJumpChain.resolve(
            alias: "target",
            in: docs(
                """
                Host target
                    HostName t.example.com
                    ProxyJump admin@bastion:9000
                Host bastion
                    HostName b.example.com
                    User ignored
                    Port 22
                """))
        #expect(chain[0].host == "b.example.com") // host still resolved from alias
        #expect(chain[0].user == "admin") // inline override wins
        #expect(chain[0].port == 9000)
    }

    @Test func resolvesNestedJumpChainDepthFirst() throws {
        // target → via b, and b → via a; ssh order is a, b, target.
        let chain = try TunnelJumpChain.resolve(
            alias: "target",
            in: docs(
                """
                Host target
                    HostName t.example.com
                    ProxyJump b
                Host b
                    HostName b.example.com
                    ProxyJump a
                Host a
                    HostName a.example.com
                """))
        #expect(chain.map(\.host) == ["a.example.com", "b.example.com", "t.example.com"])
    }

    @Test func unrecognizedProxyCommandOnTheEntryHopIsTaggedNotRejected() throws {
        let hops = try TunnelJumpChain.resolve(
            alias: "x",
            in: docs(
                """
                Host x
                    ProxyCommand nc %h %p
                """))
        #expect(hops.count == 1)
        #expect(hops[0].proxyCommandTransport == .rawSubprocess("nc %h %p"))
    }

    @Test func unrecognizedProxyCommandResolvesToRawSubprocess() throws {
        let hops = try TunnelJumpChain.resolve(
            alias: "x",
            in: docs(
                """
                Host x
                    ProxyCommand /opt/homebrew/bin/cloudflared access ssh --hostname %h
                """))
        #expect(hops.count == 1)
        #expect(
            hops[0].proxyCommandTransport
                == .rawSubprocess("/opt/homebrew/bin/cloudflared access ssh --hostname %h"))
    }

    @Test func sshDashWProxyCommandIsFoldedIntoAJumpHop() throws {
        let hops = try TunnelJumpChain.resolve(
            alias: "target",
            in: docs(
                """
                Host target
                    ProxyCommand ssh -W %h:%p bastion
                Host bastion
                    HostName 203.0.113.9
                """))
        #expect(hops.map(\.host) == ["203.0.113.9", "target"])
        #expect(hops.allSatisfy { $0.proxyCommandTransport == nil })
    }

    @Test func socks5ProxyCommandIsUsable() throws {
        let hops = try TunnelJumpChain.resolve(
            alias: "x",
            in: docs(
                """
                Host x
                    ProxyCommand nc -x 10.0.0.1:1080 %h %p
                """))
        #expect(hops.count == 1)
        #expect(hops[0].proxyCommandTransport == .socks5(host: "10.0.0.1", port: 1080))
    }

    @Test func httpConnectProxyCommandIsUsable() throws {
        let hops = try TunnelJumpChain.resolve(
            alias: "x",
            in: docs(
                """
                Host x
                    ProxyCommand corkscrew proxy.example.com 3128 %h %p
                """))
        #expect(hops.count == 1)
        #expect(hops[0].proxyCommandTransport == .httpConnect(host: "proxy.example.com", port: 3128))
    }

    @Test func explicitProxyJumpWinsOverProxyCommandOnTheSameHost() throws {
        let hops = try TunnelJumpChain.resolve(
            alias: "target",
            in: docs(
                """
                Host target
                    ProxyJump jump
                    ProxyCommand nc -x 10.0.0.1:1080 %h %p
                Host jump
                    HostName 203.0.113.1
                """))
        #expect(hops.map(\.host) == ["203.0.113.1", "target"])
        #expect(hops.allSatisfy { $0.proxyCommandTransport == nil })
    }

    @Test func proxyCommandNoneCancelsAnInheritedProxyCommand() throws {
        let hops = try TunnelJumpChain.resolve(
            alias: "direct",
            in: docs(
                """
                Host direct
                    ProxyCommand none
                Host *
                    ProxyCommand nc -x 10.0.0.1:1080 %h %p
                """))
        #expect(hops.count == 1)
        #expect(hops[0].proxyCommandTransport == nil)
    }

    @Test func proxyCommandOnAJumpHostIsRejected() {
        #expect(throws: TunnelChainError.self) {
            try TunnelJumpChain.resolve(
                alias: "target",
                in: docs(
                    """
                    Host target
                        ProxyJump jump
                    Host jump
                        ProxyCommand nc %h %p
                    """))
        }
    }

    @Test func cyclicChainThrows() {
        #expect(throws: TunnelChainError.self) {
            try TunnelJumpChain.resolve(
                alias: "a",
                in: docs(
                    """
                    Host a
                        ProxyJump b
                    Host b
                        ProxyJump a
                    """))
        }
    }

    // MARK: - New per-hop fields (IdentityAgent, IdentitiesOnly, ConnectTimeout,
    // ServerAliveInterval, BindAddress)

    @Test func resolvesIdentityAgentRawVerbatim() throws {
        let chain = try TunnelJumpChain.resolve(
            alias: "web",
            in: docs(
                """
                Host web
                    HostName w.example.com
                    IdentityAgent ~/Library/Group Containers/2BUA8C4S2C.com.1password/t/agent.sock
                """))
        // Unexpanded: `~` expansion is an app-layer concern, not this package's.
        #expect(chain[0].identityAgentRaw == "~/Library/Group Containers/2BUA8C4S2C.com.1password/t/agent.sock")
    }

    @Test func identityAgentNoneAndSSHAuthSockPassThroughVerbatim() throws {
        let noneChain = try TunnelJumpChain.resolve(
            alias: "web",
            in: docs(
                """
                Host web
                    HostName w.example.com
                    IdentityAgent none
                """))
        #expect(noneChain[0].identityAgentRaw == "none")

        let defaultChain = try TunnelJumpChain.resolve(
            alias: "web",
            in: docs(
                """
                Host web
                    HostName w.example.com
                    IdentityAgent SSH_AUTH_SOCK
                """))
        #expect(defaultChain[0].identityAgentRaw == "SSH_AUTH_SOCK")
    }

    @Test func unsetIdentityAgentIsNil() throws {
        let chain = try TunnelJumpChain.resolve(
            alias: "web",
            in: docs(
                """
                Host web
                    HostName w.example.com
                """))
        #expect(chain[0].identityAgentRaw == nil)
    }

    @Test func identitiesOnlyYesIsTrueOtherwiseFalse() throws {
        let yes = try TunnelJumpChain.resolve(
            alias: "web",
            in: docs(
                """
                Host web
                    HostName w.example.com
                    IdentitiesOnly yes
                """))
        #expect(yes[0].identitiesOnly)

        let unset = try TunnelJumpChain.resolve(
            alias: "web",
            in: docs(
                """
                Host web
                    HostName w.example.com
                """))
        #expect(!unset[0].identitiesOnly)

        let no = try TunnelJumpChain.resolve(
            alias: "web",
            in: docs(
                """
                Host web
                    HostName w.example.com
                    IdentitiesOnly no
                """))
        #expect(!no[0].identitiesOnly)
    }

    @Test func resolvesConnectTimeoutServerAliveIntervalAndBindAddress() throws {
        let chain = try TunnelJumpChain.resolve(
            alias: "web",
            in: docs(
                """
                Host web
                    HostName w.example.com
                    ConnectTimeout 15
                    ServerAliveInterval 30
                    BindAddress 10.0.0.5
                """))
        #expect(chain[0].connectTimeout == 15)
        #expect(chain[0].serverAliveInterval == 30)
        #expect(chain[0].bindAddress == "10.0.0.5")
    }

    @Test func unsetNumericFieldsAreNil() throws {
        let chain = try TunnelJumpChain.resolve(
            alias: "web",
            in: docs(
                """
                Host web
                    HostName w.example.com
                """))
        #expect(chain[0].connectTimeout == nil)
        #expect(chain[0].serverAliveInterval == nil)
        #expect(chain[0].bindAddress == nil)
    }

    @Test func perHopFieldsAreIndependentAcrossAJumpChain() throws {
        // Each hop resolves its own config: the bastion's IdentitiesOnly/ConnectTimeout
        // must not leak onto the target, and vice versa.
        let chain = try TunnelJumpChain.resolve(
            alias: "target",
            in: docs(
                """
                Host target
                    HostName t.example.com
                    ProxyJump bastion
                    ServerAliveInterval 60
                Host bastion
                    HostName b.example.com
                    IdentitiesOnly yes
                    ConnectTimeout 5
                """))
        #expect(chain[0].host == "b.example.com") // bastion
        #expect(chain[0].identitiesOnly)
        #expect(chain[0].connectTimeout == 5)
        #expect(chain[0].serverAliveInterval == nil)

        #expect(chain[1].host == "t.example.com") // target
        #expect(!chain[1].identitiesOnly)
        #expect(chain[1].connectTimeout == nil)
        #expect(chain[1].serverAliveInterval == 60)
    }

    @Test func resolvesHostKeyVerificationDirectives() throws {
        let chain = try TunnelJumpChain.resolve(
            alias: "web",
            in: docs(
                """
                Host web
                    HostName w.example.com
                    StrictHostKeyChecking yes
                    HostKeyAlias web-alias
                    NoHostAuthenticationForLocalhost yes
                    HashKnownHosts yes
                    UserKnownHostsFile ~/.ssh/other_known_hosts ~/.ssh/more_known_hosts
                    RevokedHostKeys ~/.ssh/revoked_keys
                """))
        #expect(chain[0].strictHostKeyChecking == .strict)
        #expect(chain[0].hostKeyAlias == "web-alias")
        #expect(chain[0].noHostAuthenticationForLocalhost)
        #expect(chain[0].hashKnownHosts)
        #expect(chain[0].userKnownHostsFile == ["~/.ssh/other_known_hosts", "~/.ssh/more_known_hosts"])
        #expect(chain[0].revokedHostKeys == "~/.ssh/revoked_keys")
    }

    @Test func hostKeyVerificationDirectivesDefaultToUnsetBehavior() throws {
        let chain = try TunnelJumpChain.resolve(
            alias: "web",
            in: docs(
                """
                Host web
                    HostName w.example.com
                """))
        #expect(chain[0].strictHostKeyChecking == .acceptNew)
        #expect(chain[0].hostKeyAlias == nil)
        #expect(!chain[0].noHostAuthenticationForLocalhost)
        #expect(!chain[0].hashKnownHosts)
        #expect(chain[0].userKnownHostsFile.isEmpty)
        #expect(chain[0].revokedHostKeys == nil)
    }

    @Test func resolvesServerAliveCountMaxAndTCPKeepAlive() throws {
        let chain = try TunnelJumpChain.resolve(
            alias: "web",
            in: docs(
                """
                Host web
                    HostName w.example.com
                    ServerAliveCountMax 5
                    TCPKeepAlive no
                """))
        #expect(chain[0].serverAliveCountMax == 5)
        #expect(!chain[0].tcpKeepAlive)
    }

    @Test func serverAliveCountMaxAndTCPKeepAliveDefaults() throws {
        let chain = try TunnelJumpChain.resolve(
            alias: "web",
            in: docs(
                """
                Host web
                    HostName w.example.com
                """))
        #expect(chain[0].serverAliveCountMax == 3)
        #expect(chain[0].tcpKeepAlive)
    }

    @Test func resolvesCiphersAsCommaSeparatedList() throws {
        let chain = try TunnelJumpChain.resolve(
            alias: "web",
            in: docs(
                """
                Host web
                    HostName w.example.com
                    Ciphers aes256-gcm@openssh.com, aes128-gcm@openssh.com
                """))
        #expect(chain[0].ciphers == ["aes256-gcm@openssh.com", "aes128-gcm@openssh.com"])
    }

    @Test func unsetCiphersIsEmpty() throws {
        let chain = try TunnelJumpChain.resolve(
            alias: "web",
            in: docs(
                """
                Host web
                    HostName w.example.com
                """))
        #expect(chain[0].ciphers.isEmpty)
    }

    @Test func resolvesAuthMethodPreferenceDirectives() throws {
        let chain = try TunnelJumpChain.resolve(
            alias: "web",
            in: docs(
                """
                Host web
                    HostName w.example.com
                    PubkeyAuthentication no
                    KbdInteractiveAuthentication no
                    PasswordAuthentication no
                    GSSAPIAuthentication yes
                    HostbasedAuthentication yes
                """))
        #expect(!chain[0].pubkeyAuthentication)
        #expect(!chain[0].kbdInteractiveAuthentication)
        #expect(!chain[0].passwordAuthentication)
        #expect(chain[0].gssapiAuthenticationRequested)
        #expect(chain[0].hostbasedAuthenticationRequested)
    }

    @Test func authMethodPreferenceDirectivesDefaultToEnabled() throws {
        let chain = try TunnelJumpChain.resolve(
            alias: "web",
            in: docs(
                """
                Host web
                    HostName w.example.com
                """))
        #expect(chain[0].pubkeyAuthentication)
        #expect(chain[0].kbdInteractiveAuthentication)
        #expect(chain[0].passwordAuthentication)
        #expect(!chain[0].gssapiAuthenticationRequested)
        #expect(!chain[0].hostbasedAuthenticationRequested)
    }

    @Test func resolvesExitOnForwardFailure() throws {
        let chain = try TunnelJumpChain.resolve(
            alias: "web",
            in: docs(
                """
                Host web
                    HostName w.example.com
                    ExitOnForwardFailure yes
                """))
        #expect(chain[0].exitOnForwardFailure)
    }

    @Test func resolvesCertificateFile() throws {
        let chain = try TunnelJumpChain.resolve(
            alias: "web",
            in: docs(
                """
                Host web
                    HostName w.example.com
                    CertificateFile ~/.ssh/id_ed25519-cert.pub
                """))
        #expect(chain[0].certificateFile == "~/.ssh/id_ed25519-cert.pub")
    }

    @Test func unsetCertificateFileIsNil() throws {
        let chain = try TunnelJumpChain.resolve(
            alias: "web",
            in: docs(
                """
                Host web
                    HostName w.example.com
                """))
        #expect(chain[0].certificateFile == nil)
    }

    @Test func resolvesAlgorithmNegotiationDirectives() throws {
        let chain = try TunnelJumpChain.resolve(
            alias: "web",
            in: docs(
                """
                Host web
                    HostName w.example.com
                    KexAlgorithms curve25519-sha256, ecdh-sha2-nistp256
                    HostKeyAlgorithms ssh-ed25519, ecdsa-sha2-nistp256
                    PubkeyAcceptedAlgorithms ssh-ed25519
                """))
        #expect(chain[0].kexAlgorithms == ["curve25519-sha256", "ecdh-sha2-nistp256"])
        #expect(chain[0].hostKeyAlgorithms == ["ssh-ed25519", "ecdsa-sha2-nistp256"])
        #expect(chain[0].pubkeyAcceptedAlgorithms == ["ssh-ed25519"])
    }

    @Test func unsetAlgorithmNegotiationDirectivesAreEmpty() throws {
        let chain = try TunnelJumpChain.resolve(
            alias: "web",
            in: docs(
                """
                Host web
                    HostName w.example.com
                """))
        #expect(chain[0].kexAlgorithms.isEmpty)
        #expect(chain[0].hostKeyAlgorithms.isEmpty)
        #expect(chain[0].pubkeyAcceptedAlgorithms.isEmpty)
    }
}
