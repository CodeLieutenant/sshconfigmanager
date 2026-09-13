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
    func alias(of block: HostBlock) -> String { block.patterns.first ?? "" }

    func isFavorite(_ block: HostBlock) -> Bool { favoriteAliases.contains(alias(of: block)) }

    func toggleFavorite(_ block: HostBlock) {
        let key = alias(of: block)
        guard !key.isEmpty else { return }
        if favoriteAliases.contains(key) { favoriteAliases.remove(key) } else { favoriteAliases.insert(key) }
        persistHostMetadata()
    }

    func tags(for block: HostBlock) -> [String] { tagsByAlias[alias(of: block)] ?? [] }

    func setTags(_ tags: [String], for block: HostBlock) {
        let key = alias(of: block)
        guard !key.isEmpty else { return }
        let cleaned = tags.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if cleaned.isEmpty { tagsByAlias[key] = nil } else { tagsByAlias[key] = cleaned }
        persistHostMetadata()
    }

    var allTags: [String] { Set(tagsByAlias.values.flatMap { $0 }).sorted() }

    var favoriteBlocks: [HostBlock] {
        allHostBlocks.filter { favoriteAliases.contains(alias(of: $0)) }
    }

    func persistHostMetadata() {
        if !groupsInitialLoadCompleted { hostMetadataMutatedBeforeLoad = true }
        guard let database else { return }
        let snapshot = AppDatabase.HostMetadata(favoriteAliases: favoriteAliases, tagsByAlias: tagsByAlias)
        Task { try? await database.replaceHostMetadata(snapshot) }
    }
}
