//
//  SpotlightIndexerTests.swift
//  sshconfigmanagerTests
//
//  `makeItem(for:)` is a pure `HostBlock → CSSearchableItem` mapper; `reindex`/
//  `deleteAll` drive `SearchIndexing`, a seam over the real `CSSearchableIndex`
//  so both are testable without touching the system Spotlight index.
//

import CoreSpotlight
import Foundation
import SSHConfigCore
import Testing

@testable import SSHConfigMacUI

private let cfgURL = URL(fileURLWithPath: "/tmp/config")

private func firstHostBlock(_ text: String) -> HostBlock {
    SSHConfigParser.parse(text, sourceURL: cfgURL).blocks.first { $0.kind == .host }!
}

/// Records every delete/index call instead of touching the system index.
@MainActor
private final class FakeSearchIndex: SearchIndexing {
    private(set) var deletedDomains: [[String]] = []
    private(set) var indexedItems: [[CSSearchableItem]] = []

    func deleteSearchableItems(
        withDomainIdentifiers domainIdentifiers: [String],
        completionHandler: (@Sendable (Error?) -> Void)?
    ) {
        deletedDomains.append(domainIdentifiers)
        completionHandler?(nil)
    }

    func indexSearchableItems(_ items: [CSSearchableItem], completionHandler: (@Sendable (Error?) -> Void)?) {
        indexedItems.append(items)
        completionHandler?(nil)
    }
}

@MainActor
struct SpotlightIndexerMakeItemTests {
    @Test func mapsAConcreteHostToASearchableItem() {
        let block = firstHostBlock("Host web\n    HostName 10.0.0.5\n    User deploy\n    Port 2222\n")
        let item = SpotlightIndexer.makeItem(for: block)
        #expect(item != nil)
        #expect(item?.uniqueIdentifier == SpotlightIndexer.uniqueIdentifier(for: "web"))
        #expect(item?.domainIdentifier == SpotlightIndexer.domainIdentifier)
        #expect(item?.attributeSet.title == block.title)
        #expect(item?.attributeSet.contentDescription?.contains("10.0.0.5") == true)
        #expect(item?.attributeSet.contentDescription?.contains("User: deploy") == true)
        #expect(item?.attributeSet.keywords?.contains("10.0.0.5") == true)
    }

    @Test func wildcardHostsAreExcluded() {
        let block = firstHostBlock("Host *.internal\n    HostName jump.example.com\n")
        #expect(SpotlightIndexer.makeItem(for: block) == nil)
    }

    @Test func roundTripsTheUniqueIdentifierFormat() {
        let identifier = SpotlightIndexer.uniqueIdentifier(for: "bastion")
        #expect(SpotlightIndexer.alias(from: identifier) == "bastion")
        #expect(SpotlightIndexer.alias(from: "not-a-spotlight-id") == nil)
    }
}

@MainActor
struct SpotlightIndexerReindexTests {
    @Test func reindexDeletesTheDomainThenIndexesTheMappedItems() async throws {
        let fake = FakeSearchIndex()
        let indexer = SpotlightIndexer(index: fake)
        let block = firstHostBlock("Host web\n    HostName 10.0.0.5\n")

        indexer.reindex([block])

        try await Task.sleep(for: .milliseconds(50)) // completion handlers run synchronously here, but be safe
        #expect(fake.deletedDomains == [[SpotlightIndexer.domainIdentifier]])
        #expect(fake.indexedItems.count == 1)
        #expect(fake.indexedItems.first?.first?.uniqueIdentifier == SpotlightIndexer.uniqueIdentifier(for: "web"))
    }

    @Test func reindexWithNoConcreteHostsSkipsIndexingAfterDelete() async throws {
        let fake = FakeSearchIndex()
        let indexer = SpotlightIndexer(index: fake)
        let block = firstHostBlock("Host *\n    User deploy\n")

        indexer.reindex([block])

        try await Task.sleep(for: .milliseconds(50))
        #expect(fake.deletedDomains == [[SpotlightIndexer.domainIdentifier]])
        #expect(fake.indexedItems.isEmpty)
    }

    @Test func deleteAllOnlyDeletesTheDomain() {
        let fake = FakeSearchIndex()
        let indexer = SpotlightIndexer(index: fake)

        indexer.deleteAll()

        #expect(fake.deletedDomains == [[SpotlightIndexer.domainIdentifier]])
        #expect(fake.indexedItems.isEmpty)
    }
}
