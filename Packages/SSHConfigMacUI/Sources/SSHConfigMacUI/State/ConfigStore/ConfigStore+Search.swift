import AppKit
import Foundation
import Observation
import SSHConfigCore
import SSHConfigCrypto
import SSHConfigEngine
import SSHConfigServices
import Security
import SwiftUI
@preconcurrency import UserNotifications

extension ConfigStore {
    func searchableHosts(matching query: String) -> [HostBlock] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        let hosts = allHostBlocks.filter { !$0.isWildcard }
        guard !q.isEmpty else { return hosts }
        return hosts.filter {
            FuzzyMatch.contains(q, in: $0.title.lowercased())
                || FuzzyMatch.contains(q, in: ($0.firstValue(for: "HostName") ?? "").lowercased())
        }
    }

    struct DocumentGroup: Identifiable {
        let id: URL
        let name: String
        let isMain: Bool
        var blocks: [HostBlock]
    }

    struct ParsedSearch {
        var tags: [String]
        var text: String
        var isEmpty: Bool { tags.isEmpty && text.isEmpty }
    }

    var parsedSearch: ParsedSearch {
        var tags: [String] = []
        var words: [String] = []
        for token in searchText.split(separator: " ") {
            if token.hasPrefix("#") {
                let tag = token.dropFirst().lowercased()
                if !tag.isEmpty { tags.append(tag) }
            } else {
                words.append(token.lowercased())
            }
        }
        return ParsedSearch(tags: tags, text: words.joined(separator: " "))
    }

    var filteredGroups: [DocumentGroup] {
        let search = parsedSearch
        var activeTags = search.tags
        if let tagFilter { activeTags.append(tagFilter.lowercased()) }
        let filtering = !search.isEmpty || tagFilter != nil
        var groups: [DocumentGroup] = []
        for (index, document) in documents.enumerated() {
            let blocks = document.blocks.filter { block in
                if block.isWildcard { return false }
                if !activeTags.isEmpty {
                    let hostTags = tags(for: block).map { $0.lowercased() }
                    let matchesAll = activeTags.allSatisfy { token in
                        hostTags.contains { $0.contains(token) }
                    }
                    if !matchesAll { return false }
                }
                return search.text.isEmpty || matches(block, query: search.text)
            }
            if blocks.isEmpty && filtering { continue }
            groups.append(
                DocumentGroup(
                    id: document.sourceURL,
                    name: document.displayName,
                    isMain: index == 0,
                    blocks: blocks
                ))
        }
        return groups
    }

    private func matches(_ block: HostBlock, query: String) -> Bool {
        let haystacks = [
            block.title.lowercased(),
            (block.firstValue(for: "HostName") ?? "").lowercased(),
        ]
        let words = query.split(separator: " ").map(String.init)
        guard !words.isEmpty else { return true }
        return words.allSatisfy { word in
            haystacks.contains { FuzzyMatch.contains(word, in: $0) }
        }
    }

    var sidebarTree: [HostGroup] {
        guard groupingMode != .flat else { return [] }
        let allFiltered = filteredGroups.flatMap(\.blocks)
        return GroupResolver.resolve(
            blocks: allFiltered, mode: groupingMode,
            tagMap: tagsByAlias, groups: groups)
    }

    var hasGroupTags: Bool {
        tagsByAlias.values.contains { tags in tags.contains { $0.hasPrefix(GroupResolver.groupTagPrefix) } }
    }

    var searchSuggestions: [String] {
        let tokens = searchText.split(separator: " ", omittingEmptySubsequences: false)
        guard let last = tokens.last, last.hasPrefix("#") else { return [] }
        let partial = String(last.dropFirst()).lowercased()
        let chosen = Set(parsedSearch.tags)
        return allTags.filter { tag in
            let lower = tag.lowercased()
            return FuzzyMatch.contains(partial, in: lower) && !chosen.contains(lower)
        }
    }

    func applyTagSuggestion(_ tag: String) {
        var tokens = searchText.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        if !tokens.isEmpty { tokens.removeLast() }
        tokens.append("#\(tag)")
        searchText = tokens.joined(separator: " ") + " "
    }
}
