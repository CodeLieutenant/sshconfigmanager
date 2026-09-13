import Testing

@testable import SSHConfigIntelliSense

@Suite struct IntelliSenseEngineTests {
    let engine = IntelliSenseEngine()

    /// Completions with the cursor at the `|` marker.
    private func complete(_ source: String) -> [CompletionItem] {
        let offset = source.utf16.distance(
            from: source.utf16.startIndex,
            to: source.firstIndex(of: "|")!.samePosition(in: source.utf16)!)
        let text = source.replacingOccurrences(of: "|", with: "")
        return engine.completions(in: text, utf16CursorOffset: offset)
    }

    // MARK: keywords

    @Test func keywordPrefixFuzzyMatches() {
        let items = complete("Hos|")
        #expect(items.contains { $0.label == "HostName" })
        #expect(items.contains { $0.label == "Host" })
        #expect(items.allSatisfy { $0.kind == .keyword })
    }

    @Test func keywordInsertAddsTrailingSpace() {
        let item = complete("HostNam|").first { $0.label == "HostName" }
        #expect(item?.insertText == "HostName ")
    }

    @Test func emptyKeywordPrefixOffersNothing() {
        // Don't pop the full directive list on a blank line.
        #expect(complete("|").isEmpty)
    }

    @Test func subsequenceMatchingLikePalette() {
        // "ciph" should reach "Ciphers"; "fwdx" should reach ForwardX11 via subsequence.
        #expect(complete("ciph|").contains { $0.label == "Ciphers" })
        #expect(complete("fwx|").contains { $0.label == "ForwardX11" })
    }

    // MARK: enum / yes-no values

    @Test func yesNoValues() {
        let items = complete("Compression |")
        #expect(items.map(\.label) == ["yes", "no"])
        #expect(items.allSatisfy { $0.kind == .enumCase })
    }

    @Test func enumerationValues() {
        let items = complete("StrictHostKeyChecking a|")
        #expect(items.contains { $0.label == "accept-new" })
        #expect(items.contains { $0.label == "ask" })
    }

    // MARK: algorithm catalogs

    @Test func ciphersCatalog() {
        let items = complete("Ciphers |")
        #expect(items.first?.label == "chacha20-poly1305@openssh.com")
        #expect(items.allSatisfy { $0.kind == .algorithm })
    }

    @Test func algorithmListCompletesLastElementAfterComma() {
        let items = complete("Ciphers aes128-ctr,aes256|")
        let gcm = items.first { $0.label == "aes256-gcm@openssh.com" }
        #expect(gcm != nil)
        // Replacing only "aes256", the typed last element.
        #expect(gcm?.replace.length == 6)
    }

    @Test func algorithmListOperatorPrefixPreserved() {
        let items = complete("KexAlgorithms +curve|")
        let item = items.first { $0.label == "curve25519-sha256" }
        #expect(item?.insertText == "+curve25519-sha256")
    }

    // MARK: document-derived host completion

    @Test func proxyJumpOffersDeclaredHosts() {
        let text = "Host bastion\n  HostName b.example.com\n\nHost web\n  ProxyJump b|"
        let offset = text.utf16.count
        let items = engine.completions(
            in: text.replacingOccurrences(of: "|", with: ""),
            utf16CursorOffset: offset - 1)
        #expect(items.contains { $0.label == "bastion" && $0.kind == .host })
    }

    @Test func proxyJumpCompletesHostAfterUserAtSign() {
        let text = "Host bastion\n\nHost web\n  ProxyJump admin@bas|"
        let bareOffset = text.replacingOccurrences(of: "|", with: "")
        let offset = text.utf16.distance(
            from: text.utf16.startIndex,
            to: text.firstIndex(of: "|")!.samePosition(in: text.utf16)!)
        let items = engine.completions(in: bareOffset, utf16CursorOffset: offset)
        let item = items.first { $0.label == "bastion" }
        #expect(item != nil)
        // Replace only "bas" (after the @), not "admin@bas".
        #expect(item?.replace.length == 3)
        #expect(item?.insertText == "bastion")
    }

    @Test func unknownKeywordValueOffersNothing() {
        #expect(complete("HostName foo|").isEmpty) // free-form string, no catalog
    }

    // MARK: hover

    @Test func hoverOnKnownKeyword() {
        let info = engine.hover(in: "  Port 22", utf16CursorOffset: 4)
        #expect(info?.title == "Port")
        #expect(info?.documentation.isEmpty == false)
    }

    @Test func hoverOnUnknownKeywordIsNil() {
        #expect(engine.hover(in: "Frobnicate yes", utf16CursorOffset: 2) == nil)
    }
}
