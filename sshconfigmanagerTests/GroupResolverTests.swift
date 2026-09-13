//
//  GroupResolverTests.swift
//  sshconfigmanagerTests
//

import Foundation
import SSHConfigCore
import SSHConfigServices
import Testing

@testable import SSHConfigMacUI

@Suite("GroupResolver")
struct GroupResolverTests {

    // MARK: - Helpers

    private func makeBlock(alias: String) -> HostBlock {
        HostBlock(
            kind: .host,
            header: Directive(keyword: "Host", value: alias),
            sourceURL: URL(filePath: "/tmp/config")
        )
    }

    /// A virtual (non-file-backed) group record — membership still comes from
    /// the `group/<name>` tag, but the record itself must exist in `groups` for
    /// `GroupResolver` to recognize that tag (see `PersistedGroup`'s doc comment).
    private func makeGroup(name: String, sortIndex: Int) -> PersistedGroup {
        PersistedGroup(name: name, filePath: nil, sortIndex: sortIndex)
    }

    // MARK: - .flat mode

    @Test("flat mode returns empty — caller uses filteredGroups")
    func flatModeReturnsEmpty() {
        let blocks = [makeBlock(alias: "web-1"), makeBlock(alias: "db")]
        let result = GroupResolver.resolve(blocks: blocks, mode: .flat, tagMap: [:], groups: [])
        #expect(result.isEmpty)
    }

    // MARK: - .byTag mode — basic grouping

    @Test("byTag groups blocks by group/ tag")
    func byTagGroupsBlocks() {
        let web = makeBlock(alias: "web-1")
        let db = makeBlock(alias: "db")
        let tagMap: [String: [String]] = [
            "web-1": ["group/prod"],
            "db": ["group/prod"],
        ]
        let groups = [makeGroup(name: "prod", sortIndex: 0)]
        let result = GroupResolver.resolve(blocks: [web, db], mode: .byTag, tagMap: tagMap, groups: groups)
        #expect(result.count == 1)
        #expect(result[0].name == "prod")
        #expect(result[0].isUngrouped == false)
        #expect(result[0].blocks.map(\.title) == ["web-1", "db"])
    }

    @Test("byTag separates blocks into distinct named groups")
    func byTagMultipleGroups() {
        let prod = makeBlock(alias: "web-prod")
        let dev = makeBlock(alias: "web-dev")
        let tagMap: [String: [String]] = [
            "web-prod": ["group/prod"],
            "web-dev": ["group/dev"],
        ]
        let groups = [makeGroup(name: "prod", sortIndex: 0), makeGroup(name: "dev", sortIndex: 1)]
        let result = GroupResolver.resolve(blocks: [prod, dev], mode: .byTag, tagMap: tagMap, groups: groups)
        #expect(result.count == 2)
        #expect(result[0].name == "prod")
        #expect(result[1].name == "dev")
    }

    @Test("byTag orders groups by sortIndex, independent of block order")
    func byTagPreservesGroupOrder() {
        let a = makeBlock(alias: "a")
        let b = makeBlock(alias: "b")
        let c = makeBlock(alias: "c")
        let tagMap: [String: [String]] = [
            "a": ["group/beta"],
            "b": ["group/alpha"],
            "c": ["group/beta"],
        ]
        // "beta" is tagged first (block "a") but "alpha" is declared with the lower
        // sortIndex — order follows the group records, not tag first-occurrence.
        let groups = [makeGroup(name: "alpha", sortIndex: 0), makeGroup(name: "beta", sortIndex: 1)]
        let result = GroupResolver.resolve(blocks: [a, b, c], mode: .byTag, tagMap: tagMap, groups: groups)
        #expect(result.count == 2)
        #expect(result[0].name == "alpha")
        #expect(result[1].name == "beta")
    }

    @Test("byTag collects ungrouped blocks at the end")
    func byTagUngroupedAtEnd() {
        let grouped = makeBlock(alias: "web")
        let lone = makeBlock(alias: "scratch")
        let tagMap: [String: [String]] = ["web": ["group/prod"]]
        let groups = [makeGroup(name: "prod", sortIndex: 0)]
        let result = GroupResolver.resolve(blocks: [grouped, lone], mode: .byTag, tagMap: tagMap, groups: groups)
        #expect(result.count == 2)
        #expect(result[0].name == "prod")
        #expect(result[1].isUngrouped == true)
        #expect(result[1].name == "Ungrouped")
        #expect(result[1].blocks.map(\.title) == ["scratch"])
    }

    @Test("byTag with no group tags returns single Ungrouped group")
    func byTagAllUngrouped() {
        let a = makeBlock(alias: "a")
        let b = makeBlock(alias: "b")
        let result = GroupResolver.resolve(blocks: [a, b], mode: .byTag, tagMap: [:], groups: [])
        #expect(result.count == 1)
        #expect(result[0].isUngrouped == true)
        #expect(result[0].blocks.count == 2)
    }

    @Test("byTag ignores tags without the group/ prefix")
    func byTagIgnoresNonGroupTags() {
        let block = makeBlock(alias: "prod-web")
        let tagMap: [String: [String]] = ["prod-web": ["production", "web"]]
        let result = GroupResolver.resolve(blocks: [block], mode: .byTag, tagMap: tagMap, groups: [])
        #expect(result.count == 1)
        #expect(result[0].isUngrouped == true)
    }

    @Test("byTag uses first group/ tag when block carries multiple")
    func byTagFirstGroupTagWins() {
        let block = makeBlock(alias: "multi")
        let tagMap: [String: [String]] = ["multi": ["group/alpha", "group/beta"]]
        // Only "alpha" needs a group record: `currentGroup` only ever looks up the
        // first `group/`-prefixed tag, so "beta" is never consulted. (Every group
        // record appears in the result even with zero members, so adding a "beta"
        // record here would make this assert result.count == 2, not 1.)
        let groups = [makeGroup(name: "alpha", sortIndex: 0)]
        let result = GroupResolver.resolve(blocks: [block], mode: .byTag, tagMap: tagMap, groups: groups)
        #expect(result.count == 1)
        #expect(result[0].name == "alpha")
    }

    @Test("byTag is empty when block list is empty")
    func byTagEmptyInput() {
        let result = GroupResolver.resolve(blocks: [], mode: .byTag, tagMap: [:], groups: [])
        #expect(result.isEmpty)
    }
}
