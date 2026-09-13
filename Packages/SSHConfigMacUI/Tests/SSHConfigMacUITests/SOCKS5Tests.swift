//
//  SOCKS5Tests.swift
//  sshconfigmanagerTests
//
//  Pure parsing for the dynamic (-D) tunnel's SOCKS5 server side.
//

import Foundation
import SSHConfigCore
import Testing

@testable import SSHConfigMacUI

struct SOCKS5Tests {
    @Test func greetingWithNoAuthIsAccepted() throws {
        // VER=5, NMETHODS=1, METHOD=0x00 (no auth)
        #expect(try SOCKS5.parseGreeting([0x05, 0x01, 0x00]) == true)
        // Offers only GSSAPI (0x01) → not acceptable.
        #expect(try SOCKS5.parseGreeting([0x05, 0x01, 0x01]) == false)
    }

    @Test func greetingNeedsAllMethodBytes() {
        #expect(throws: SOCKS5.ParseError.incomplete) { try SOCKS5.parseGreeting([0x05, 0x02, 0x00]) }
    }

    @Test func badVersionRejected() {
        #expect(throws: SOCKS5.ParseError.badVersion) { try SOCKS5.parseGreeting([0x04, 0x01, 0x00]) }
    }

    @Test func parsesIPv4ConnectRequest() throws {
        // VER CMD RSV ATYP=1  IP=127.0.0.1  PORT=5432 (0x1538)
        let req: [UInt8] = [0x05, 0x01, 0x00, 0x01, 127, 0, 0, 1, 0x15, 0x38]
        #expect(try SOCKS5.parseConnectRequest(req) == .init(host: "127.0.0.1", port: 5432))
    }

    @Test func parsesDomainConnectRequest() throws {
        let host = Array("db.internal".utf8)
        var req: [UInt8] = [0x05, 0x01, 0x00, 0x03, UInt8(host.count)]
        req += host
        req += [0x00, 0x50] // port 80
        #expect(try SOCKS5.parseConnectRequest(req) == .init(host: "db.internal", port: 80))
    }

    @Test func parsesIPv6ConnectRequest() throws {
        var req: [UInt8] = [0x05, 0x01, 0x00, 0x04]
        req += [0x00, 0x01] + [UInt8](repeating: 0, count: 12) + [0x00, 0x01] // ::1-ish
        req += [0x1f, 0x90] // port 8080
        let target = try SOCKS5.parseConnectRequest(req)
        #expect(target.port == 8080)
        #expect(target.host.contains(":"))
    }

    @Test func incompleteRequestThrows() {
        #expect(throws: SOCKS5.ParseError.incomplete) {
            try SOCKS5.parseConnectRequest([0x05, 0x01, 0x00, 0x01, 127, 0]) // missing rest of IPv4 + port
        }
    }

    @Test func nonConnectCommandRejected() {
        // CMD=0x02 (BIND) is unsupported.
        #expect(throws: SOCKS5.ParseError.unsupportedCommand) {
            try SOCKS5.parseConnectRequest([0x05, 0x02, 0x00, 0x01, 127, 0, 0, 1, 0, 80])
        }
    }

    @Test func replyEncodingIsWellFormed() {
        #expect(SOCKS5.methodSelection() == [0x05, 0x00])
        let reply = SOCKS5.connectReply(.success)
        #expect(reply.prefix(4) == [0x05, 0x00, 0x00, 0x01])
        #expect(reply.count == 10)
    }
}
