//
//  AuditSOCKS5DomainLengthTests.swift
//  sshconfigmanagerTests
//
//  AUDIT 2026-07-11 (docs/release/macos-bug-audit-2026-07-11.md, finding NET-1) — FIXED.
//  `SOCKS5.parseConnectRequest` used to accept a zero-length domain (ATYP=domain,
//  LEN=0) and return an empty target host; the -D dynamic handler then opened a
//  `direct-tcpip` channel to host "" and reported SOCKS `success` to the client, so the
//  client believed the tunnel was up while the target was bogus. The parser now rejects a
//  zero-length domain with `.unsupportedAddress`, so the handler replies `generalFailure`.
//

import Foundation
import SSHConfigCore
import Testing

@testable import SSHConfigMacUI

struct AuditSOCKS5DomainLengthTests {
    /// Sanity: a normal domain request parses as expected.
    @Test func normalDomainParses() throws {
        // VER CMD RSV ATYP=domain LEN=3 'a' 'b' 'c' PORT=80
        let req: [UInt8] = [0x05, 0x01, 0x00, 0x03, 0x03, 0x61, 0x62, 0x63, 0x00, 0x50]
        let target = try SOCKS5.parseConnectRequest(req)
        #expect(target.host == "abc")
        #expect(target.port == 80)
    }

    /// The former exploit, now fixed: a zero-length domain is rejected rather than
    /// parsed into an empty host.
    @Test func zeroLengthDomainIsRejected() throws {
        // VER=5 CMD=connect RSV=0 ATYP=domain LEN=0 PORT=80
        let req: [UInt8] = [0x05, 0x01, 0x00, 0x03, 0x00, 0x00, 0x50]

        #expect(throws: SOCKS5.ParseError.unsupportedAddress) {
            _ = try SOCKS5.parseConnectRequest(req)
        }
    }
}
