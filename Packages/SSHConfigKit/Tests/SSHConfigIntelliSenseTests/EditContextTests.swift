import Testing

@testable import SSHConfigIntelliSense

/// Cursor classification: keyword vs value vs quiet, with correct replace ranges.
@Suite struct EditContextTests {

    /// Helper: analyze with the cursor at the `|` marker in `source`.
    private func analyze(_ source: String) -> CompletionTarget {
        let offset = source.utf16.distance(
            from: source.utf16.startIndex,
            to: source.firstIndex(of: "|")!.samePosition(in: source.utf16)!)
        let text = source.replacingOccurrences(of: "|", with: "")
        return EditContext.analyze(text: text, utf16Offset: offset).target
    }

    @Test func partialKeywordAtLineStart() {
        guard case .keyword(let prefix, let replace) = analyze("Hos|") else {
            Issue.record("expected keyword")
            return
        }
        #expect(prefix == "Hos")
        #expect(replace.location == 0)
        #expect(replace.length == 3)
    }

    @Test func indentedKeyword() {
        guard case .keyword(let prefix, let replace) = analyze("    Port|") else {
            Issue.record("expected keyword")
            return
        }
        #expect(prefix == "Port")
        #expect(replace.location == 4)
        #expect(replace.length == 4)
    }

    @Test func emptyLineIsEmptyKeyword() {
        guard case .keyword(let prefix, _) = analyze("|") else {
            Issue.record("expected keyword")
            return
        }
        #expect(prefix.isEmpty)
    }

    @Test func valueAfterSpace() {
        guard case .value(let keyword, let prefix, _, let idx) = analyze("Port 2|") else {
            Issue.record("expected value")
            return
        }
        #expect(keyword == "Port")
        #expect(prefix == "2")
        #expect(idx == 0)
    }

    @Test func valueAfterEquals() {
        guard case .value(let keyword, let prefix, let replace, _) = analyze("Port=22|") else {
            Issue.record("expected value")
            return
        }
        #expect(keyword == "Port")
        #expect(prefix == "22")
        // Replace only "22", not "Port=22".
        #expect(replace.length == 2)
        #expect(replace.location == 5)
    }

    @Test func valueWithEmptyPrefixRightAfterSpace() {
        guard case .value(let keyword, let prefix, let replace, _) = analyze("StrictHostKeyChecking |") else {
            Issue.record("expected value")
            return
        }
        #expect(keyword == "StrictHostKeyChecking")
        #expect(prefix.isEmpty)
        #expect(replace.length == 0)
    }

    @Test func commaListCompletesLastElement() {
        guard case .value(let keyword, let prefix, let replace, _) = analyze("Ciphers aes128-ctr,cha|") else {
            Issue.record("expected value")
            return
        }
        #expect(keyword == "Ciphers")
        #expect(prefix == "cha")
        #expect(replace.length == 3)
    }

    @Test func secondValueTokenIndex() {
        guard case .value(_, let prefix, _, let idx) = analyze("LocalForward 8080 localh|") else {
            Issue.record("expected value")
            return
        }
        #expect(prefix == "localh")
        #expect(idx == 1)
    }

    @Test func commentLineIsQuiet() {
        #expect(analyze("# Host foo|") == .none)
        #expect(analyze("   # comment |") == .none)
    }
}
