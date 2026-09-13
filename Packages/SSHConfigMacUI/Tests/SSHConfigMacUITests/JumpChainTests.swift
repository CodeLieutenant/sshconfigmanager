//
//  JumpChainTests.swift
//  sshconfigmanagerTests
//
//  Round-trip tests for JumpChain.parse/render and the jump-chain resolver.
//

import Foundation
import SSHConfigCore
import Testing

@testable import SSHConfigMacUI

struct JumpChainTests {

    // MARK: - parse / render round-trips

    @Test func parsesEmpty() {
        let chain = JumpChain.parse("")
        #expect(chain.hops.isEmpty)
        #expect(!chain.isNone)
        #expect(chain.render() == "")
    }

    @Test func parsesNone() {
        let chain = JumpChain.parse("none")
        #expect(chain.isNone)
        #expect(chain.hops.isEmpty)
        #expect(chain.render() == "none")
    }

    @Test func parsesNoneCaseInsensitive() {
        let chain = JumpChain.parse("NONE")
        #expect(chain.isNone)
    }

    @Test func parsesSingleHost() {
        let chain = JumpChain.parse("bastion.example.com")
        #expect(chain.hops.count == 1)
        #expect(chain.hops[0].host == "bastion.example.com")
        #expect(chain.hops[0].user == nil)
        #expect(chain.hops[0].port == nil)
        #expect(chain.render() == "bastion.example.com")
    }

    @Test func parsesUserAtHost() {
        let chain = JumpChain.parse("jane@edge.example.com")
        #expect(chain.hops[0].user == "jane")
        #expect(chain.hops[0].host == "edge.example.com")
        #expect(chain.render() == "jane@edge.example.com")
    }

    @Test func parsesUserHostPort() {
        let chain = JumpChain.parse("alice@jump.example.com:2222")
        let hop = chain.hops[0]
        #expect(hop.user == "alice")
        #expect(hop.host == "jump.example.com")
        #expect(hop.port == 2222)
        #expect(chain.render() == "alice@jump.example.com:2222")
    }

    @Test func parsesMultiHopInOrder() {
        let chain = JumpChain.parse("jane@edge.example.com:2222,bastion.internal:22")
        #expect(chain.hops.count == 2)
        #expect(chain.hops[0].host == "edge.example.com")
        #expect(chain.hops[0].user == "jane")
        #expect(chain.hops[0].port == 2222)
        #expect(chain.hops[1].host == "bastion.internal")
        #expect(chain.hops[1].port == 22)
        #expect(chain.render() == "jane@edge.example.com:2222,bastion.internal:22")
    }

    @Test func parsesIPv6BracketedHost() {
        let chain = JumpChain.parse("[2001:db8::1]:2022")
        #expect(chain.hops.count == 1)
        #expect(chain.hops[0].host == "2001:db8::1")
        #expect(chain.hops[0].port == 2022)
        // render must re-bracket IPv6
        #expect(chain.render() == "[2001:db8::1]:2022")
    }

    @Test func parseAndRenderIsIdempotent() {
        let values = [
            "none",
            "bastion",
            "alice@bastion:2222",
            "hop1,hop2,hop3",
            "[::1]:22",
        ]
        for v in values {
            #expect(JumpChain.parse(v).render() == v, "round-trip failed for \(v)")
        }
    }

    // MARK: - Document-level: set then clear leaves other lines untouched

    @Test func settingAndClearingProxyJumpLeavesOtherLinesUntouched() throws {
        let url = URL(fileURLWithPath: "/tmp/config")
        var doc = SSHConfigParser.parse(
            """
            Host web
                HostName web.example.com
                User deploy
                Port 22
            """, sourceURL: url)
        guard var block = doc.blocks.first else {
            Issue.record("no block parsed")
            return
        }

        // Set ProxyJump
        block.setValue("bastion", for: "ProxyJump")
        doc.blocks[0] = block
        let withJump = SSHConfigSerializer.serialize(doc)
        #expect(withJump.contains("ProxyJump bastion"))
        #expect(withJump.contains("HostName web.example.com"))
        #expect(withJump.contains("User deploy"))
        #expect(withJump.contains("Port 22"))

        // Clear ProxyJump
        block.setValue(nil, for: "ProxyJump")
        doc.blocks[0] = block
        let cleared = SSHConfigSerializer.serialize(doc)
        #expect(!cleared.contains("ProxyJump"))
        #expect(cleared.contains("HostName web.example.com"))
        #expect(cleared.contains("User deploy"))
        #expect(cleared.contains("Port 22"))
    }

    // MARK: - resolveJumpChain

    private func docs(_ text: String) -> [SSHConfigDocument] {
        [SSHConfigParser.parse(text, sourceURL: URL(fileURLWithPath: "/tmp/config"))]
    }

    @Test func resolveReturnsNoHopsWhenNoProxyJump() {
        let hops = EffectiveConfigResolver.resolveJumpChain(
            target: "web",
            in: docs(
                """
                Host web
                    HostName web.example.com
                """))
        #expect(hops.isEmpty)
    }

    @Test func resolveSingleHop() {
        let hops = EffectiveConfigResolver.resolveJumpChain(
            target: "web",
            in: docs(
                """
                Host web
                    HostName web.example.com
                    ProxyJump bastion
                Host bastion
                    HostName b.example.com
                    User jumpuser
                    Port 2222
                """))
        #expect(hops.count == 1)
        #expect(hops[0].hostName == "b.example.com")
        #expect(hops[0].user == "jumpuser")
        #expect(hops[0].port == 2222)
        #expect(hops[0].isAlias)
    }

    @Test func resolveDoesNotCrashOnCycle() {
        // Must not recurse infinitely; the cycle-guard keeps it short.
        let hops = EffectiveConfigResolver.resolveJumpChain(
            target: "a",
            in: docs(
                """
                Host a
                    ProxyJump b
                Host b
                    ProxyJump a
                """))
        // We just verify it finishes. The cycle node uses the label without crash.
        #expect(hops.count >= 1)
    }
}
