//
//  ParserCRLFAndBOMTests.swift
//  sshconfigmanagerTests
//
//  Regression coverage for audit #27 (CRLF `\r` leaking into parsed values,
//  aliases, and connect targets) and #36 (a UTF-8 BOM hiding the first Host
//  block). The full byte-exact round-trip guardrail (`ParserPropertyTests`)
//  lives in the app's XCTest target since SSHConfigKit has no test target of
//  its own — these are the fast, targeted checks that belong next to the rest
//  of the SSHConfigMacUI package suite.
//

import Foundation
import SSHConfigCore
import Testing

@testable import SSHConfigMacUI

private let cfgURL = URL(fileURLWithPath: "/tmp/config")

private func parse(_ text: String) -> SSHConfigDocument {
    SSHConfigParser.parse(text, sourceURL: cfgURL)
}

struct ParserCRLFAndBOMTests {
    // MARK: - #27: CRLF

    @Test func crlfHostPatternHasNoTrailingCR() {
        let document = parse("Host web\r\n    HostName foo\r\n")
        let block = document.blocks.first!
        #expect(block.patterns == ["web"])
        #expect(block.firstValue(for: "HostName") == "foo")
    }

    @Test func crlfMultiWordPatternsHaveNoTrailingCROnTheLast() {
        let document = parse("Host web bastion\r\n")
        #expect(document.blocks.first!.patterns == ["web", "bastion"])
    }

    @Test func crlfValuesForRepeatedKeywordHaveNoTrailingCR() {
        let document = parse("Host web\r\n    IdentityFile a\r\n    IdentityFile b\r\n")
        #expect(document.blocks.first!.values(for: "IdentityFile") == ["a", "b"])
    }

    @Test func crlfConnectionTargetHasNoTrailingCR() {
        let document = parse("Host web\r\n    HostName foo\r\n    Port 2222\r\n")
        let target = document.blocks.first!.connectionTarget
        #expect(target?.host == "foo")
        #expect(target?.port == 2222)
    }

    /// Guards the parser's own byte-exact round-trip invariant at the model
    /// layer (the full property-based suite lives in the app's XCTest target,
    /// see `ParserPropertyTests.losslessOnPathologicalInputs`) — the CRLF fix
    /// must strip `\r` only for *consumers*, never touch the stored value.
    @Test func crlfRoundTripsByteExactWhenUnedited() {
        let text = "Host web\r\n    HostName foo\r\n"
        let reserialized = SSHConfigSerializer.serialize(parse(text))
        #expect(reserialized == text)
    }

    // MARK: - #36: UTF-8 BOM

    @Test func bomPrefixedFirstHostIsRecognized() {
        let document = parse("\u{FEFF}Host web\n    HostName foo\n")
        #expect(document.blocks.count == 1)
        #expect(document.blocks.first?.patterns == ["web"])
        #expect(document.preamble.isEmpty, "a BOM'd Host line must not fall into the preamble")
    }

    @Test func bomPrefixedCommentIsRecognized() {
        // A leading comment attaches to the following Host block's `leading`
        // (label-comment convention), so this asserts against the block, not
        // `document.preamble` — the case that matters here is that the BOM'd
        // line parses as `.comment` at all, rather than falling through to an
        // unrecognized directive.
        let document = parse("\u{FEFF}# a comment\nHost web\n")
        #expect(document.blocks.count == 1)
        #expect(document.blocks.first?.leading.count == 1)
        if case .comment = document.blocks.first?.leading.first {
            // expected
        } else {
            Issue.record("expected the BOM'd first line to parse as a comment")
        }
    }

    /// Same round-trip guardrail as CRLF: the BOM byte must still come back
    /// out exactly on an unedited reserialize.
    @Test func bomRoundTripsByteExactWhenUnedited() {
        let text = "\u{FEFF}Host web\n"
        let reserialized = SSHConfigSerializer.serialize(parse(text))
        #expect(reserialized == text)
    }
}
