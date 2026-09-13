//
//  CRLFInsertionTests.swift
//  sshconfigmanagerTests
//
//  Reproducer: every *insertion* path wrote LF-only lines into a CRLF config.
//
//  `CRLFSemanticValueTests` covers reading a value and editing an existing line.
//  This covers the other half — adding new lines — which was still LF-only in six
//  copy-pasted `ConfigStore` call sites (add host, Global Defaults, new from
//  template, import, duplicate, move between files) plus the two `Include`-wiring
//  sites. Each appended a `.blank()` with `raw: ""` and built `Directive`s with no
//  `trailingText`, so adding one host to a CRLF file left it with mixed endings.
//
//  The fix put "append a block to this file" in one place —
//  `SSHConfigDocument.appendBlocks` — which honours `lineEnding`; these tests pin
//  the behaviour at the model layer where it now lives.
//

import Foundation
import SSHConfigCore
import Testing

private let cfgURL = URL(fileURLWithPath: "/tmp/config")

private func parse(_ text: String) -> SSHConfigDocument {
    SSHConfigParser.parse(text, sourceURL: cfgURL)
}

/// The set of line terminators `text` uses. A single-element set is the property that
/// actually matters here — a file must not end up mixing them.
///
/// Walks `unicodeScalars`, NOT `split(separator: "\n")`: Swift folds `"\r\n"` into one
/// grapheme cluster, so a Character-level split finds no separators at all in CRLF text
/// and reports an empty set. That is the same trap this round fixed in
/// `SSHConfigParser.splitLines` (see `CRLFSplitLinesTests`) — and it caught this helper
/// on the first run too.
private func lineEndings(of text: String) -> Set<String> {
    var endings: Set<String> = []
    var sawCR = false
    for scalar in text.unicodeScalars {
        if scalar == "\n" {
            endings.insert(sawCR ? "\r\n" : "\n")
        }
        sawCR = scalar == "\r"
    }
    return endings
}

struct SSHConfigDocumentLineEndingTests {
    @Test func crlfDocumentReportsCR() {
        #expect(parse("Host web\r\n    HostName x\r\n").lineEnding == "\r")
    }

    @Test func lfDocumentReportsEmpty() {
        #expect(parse("Host web\n    HostName x\n").lineEnding == "")
    }

    @Test func preambleOnlyCRLFDocumentReportsCR() {
        #expect(parse("# header\r\nUser me\r\n").lineEnding == "\r")
    }

    @Test func emptyDocumentReportsEmpty() {
        #expect(parse("").lineEnding == "")
    }
}

struct CRLFInsertionTests {
    private func newBlock(alias: String) -> HostBlock {
        HostBlock(
            kind: .host,
            header: Directive(keyword: "Host", value: alias, isDirty: true),
            body: [.directive(Directive(leadingIndent: "    ", keyword: "HostName", value: "h", isDirty: true))],
            sourceURL: cfgURL)
    }

    @Test func appendingABlockToACRLFFileStaysCRLF() {
        var document = parse("Host web\r\n    HostName example.com\r\n")
        document.appendBlocks([newBlock(alias: "added")])
        let text = SSHConfigSerializer.serialize(document)
        #expect(lineEndings(of: text) == ["\r\n"], "no mixed line endings: \(text.debugDescription)")
        #expect(text == "Host web\r\n    HostName example.com\r\n\r\nHost added\r\n    HostName h\r\n")
    }

    @Test func appendingABlockToAnLFFileStaysLF() {
        var document = parse("Host web\n    HostName example.com\n")
        document.appendBlocks([newBlock(alias: "added")])
        let text = SSHConfigSerializer.serialize(document)
        #expect(lineEndings(of: text) == ["\n"])
        #expect(text == "Host web\n    HostName example.com\n\nHost added\n    HostName h\n")
    }

    /// The separator blank line is itself a line, and it was the most obvious LF leak.
    @Test func separatorBlankLineMatchesTheFile() {
        var document = parse("Host web\r\n")
        document.appendBlocks([newBlock(alias: "added")])
        #expect(lineEndings(of: SSHConfigSerializer.serialize(document)) == ["\r\n"])
    }

    /// A preamble-only config (globals and comments, no `Host` block) must not get a
    /// separator prepended, and must not index `blocks[-1]`.
    @Test func appendingToAPreambleOnlyCRLFFileStaysCRLF() {
        var document = parse("# header\r\nUser me\r\n")
        document.appendBlocks([newBlock(alias: "added")])
        let text = SSHConfigSerializer.serialize(document)
        #expect(lineEndings(of: text) == ["\r\n"])
        #expect(text == "# header\r\nUser me\r\nHost added\r\n    HostName h\r\n")
    }

    /// Moving a block from an LF file into a CRLF one must re-terminate its lines,
    /// not carry the source file's endings across.
    @Test func movingABlockBetweenFilesAdoptsTheTargetEnding() {
        let source = parse("Host moved\n    HostName m\n")
        var target = parse("Host existing\r\n    HostName e\r\n")
        target.appendBlocks([source.blocks[0]])
        #expect(lineEndings(of: SSHConfigSerializer.serialize(target)) == ["\r\n"])
    }

    @Test func movingABlockIntoAnLFFileAdoptsLF() {
        let source = parse("Host moved\r\n    HostName m\r\n")
        var target = parse("Host existing\n    HostName e\n")
        target.appendBlocks([source.blocks[0]])
        #expect(lineEndings(of: SSHConfigSerializer.serialize(target)) == ["\n"])
    }

    @Test func appendingAnIncludeToACRLFFileStaysCRLF() {
        var document = parse("Host web\r\n    HostName example.com\r\n")
        document.appendPreamble(directive: Directive(keyword: "Include", value: "work.conf", isDirty: true))
        let text = SSHConfigSerializer.serialize(document)
        #expect(lineEndings(of: text) == ["\r\n"], "no mixed line endings: \(text.debugDescription)")
    }

    /// A block whose lines already match must come through byte-for-byte — no
    /// gratuitous re-render of clean lines.
    @Test func adoptingAMatchingEndingIsAnIdentity() {
        let block = parse("Host web\r\n    HostName example.com\r\n").blocks[0]
        let adopted = block.adoptingLineEnding("\r")
        #expect(adopted.header.rendered == block.header.rendered)
        #expect(adopted.body.map(\.rendered) == block.body.map(\.rendered))
        #expect(adopted.header.isDirty == block.header.isDirty)
    }
}
