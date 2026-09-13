//
//  SpotlightIndexer.swift
//  SSHConfigMacUI
//
//  Keeps the CoreSpotlight index in sync with the app's SSH host list. Each
//  non-wildcard host appears as a Spotlight result; clicking one opens SSH Config
//  Manager and selects that host in the sidebar via onContinueUserActivity in
//  RootScene.
//
//  The primary alias (e.g. "web", "db-prod") is the stable unique identifier —
//  not the HostBlock UUID, which is reassigned on every config reload.
//

import CoreSpotlight
import SSHConfigCore

/// The subset of `CSSearchableIndex` this type drives — a seam so `reindex`/
/// `deleteAll` are testable with a fake instead of the real system Spotlight
/// index. `CSSearchableIndex` already matches this signature structurally.
protocol SearchIndexing {
    func deleteSearchableItems(
        withDomainIdentifiers domainIdentifiers: [String],
        completionHandler: (@Sendable (Error?) -> Void)?)
    func indexSearchableItems(_ items: [CSSearchableItem], completionHandler: (@Sendable (Error?) -> Void)?)
}

extension CSSearchableIndex: SearchIndexing {}

/// `ConfigStore`'s seam onto `SpotlightIndexer` (audit #24) — a fake can assert
/// `reindex`/`deleteAll` calls (and when they happened) without touching the
/// real CoreSpotlight index.
protocol SpotlightIndexing {
    func reindex(_ hosts: [HostBlock])
    func deleteAll()
}

final class SpotlightIndexer: SpotlightIndexing {
    static let shared = SpotlightIndexer()

    private let index: SearchIndexing
    static let domainIdentifier = AppIdentity.scoped("hosts")

    init(index: SearchIndexing = CSSearchableIndex.default()) {
        self.index = index
    }

    /// Replaces the entire host index with the current snapshot. Items with the
    /// same uniqueIdentifier are updated in place; stale items (renamed/deleted
    /// hosts) are cleaned up by the preceding deleteAll within the domain.
    func reindex(_ hosts: [HostBlock]) {
        // Delete the entire domain first so renamed / deleted hosts don't linger.
        index.deleteSearchableItems(withDomainIdentifiers: [Self.domainIdentifier]) { [weak self] _ in
            Task { @MainActor in
                self?.indexAfterDelete(hosts)
            }
        }
    }

    private func indexAfterDelete(_ hosts: [HostBlock]) {
        let items = hosts.compactMap(Self.makeItem(for:))
        guard !items.isEmpty else { return }
        index.indexSearchableItems(items) { error in
            if let error {
                Log.app.warning("Spotlight indexing failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Removes all app-owned Spotlight entries (called when access is revoked so
    /// stale results don't persist after a folder change).
    func deleteAll() {
        index.deleteSearchableItems(withDomainIdentifiers: [Self.domainIdentifier]) { _ in }
    }

    /// Pure `HostBlock → CSSearchableItem` mapping — no CoreSpotlight I/O, safe to
    /// unit-test directly.
    static func makeItem(for host: HostBlock) -> CSSearchableItem? {
        guard !host.isWildcard, let alias = host.primaryAlias, !alias.isEmpty else { return nil }

        let attrs = CSSearchableItemAttributeSet(contentType: .text)
        attrs.title = host.title

        var descParts: [String] = []
        if let hostname = host.firstValue(for: "HostName"), !hostname.isEmpty {
            descParts.append(hostname)
        }
        if let user = host.firstValue(for: "User"), !user.isEmpty {
            descParts.append("User: \(user)")
        }
        if let port = host.firstValue(for: "Port"), !port.isEmpty {
            descParts.append("Port: \(port)")
        }
        attrs.contentDescription = descParts.isEmpty ? nil : descParts.joined(separator: " · ")

        var keywords = host.concreteAliases
        if let hostname = host.firstValue(for: "HostName") { keywords.append(hostname) }
        if let user = host.firstValue(for: "User") { keywords.append(user) }
        attrs.keywords = keywords

        return CSSearchableItem(
            uniqueIdentifier: SpotlightIndexer.uniqueIdentifier(for: alias),
            domainIdentifier: Self.domainIdentifier,
            attributeSet: attrs
        )
    }

    static func uniqueIdentifier(for alias: String) -> String {
        "sshconfigmanager://host/\(alias)"
    }

    /// Extracts the primary alias from a Spotlight unique identifier of the form
    /// `sshconfigmanager://host/<alias>`. Returns nil for unrecognised strings.
    static func alias(from spotlightIdentifier: String) -> String? {
        let prefix = "sshconfigmanager://host/"
        guard spotlightIdentifier.hasPrefix(prefix) else { return nil }
        let alias = String(spotlightIdentifier.dropFirst(prefix.count))
        return alias.isEmpty ? nil : alias
    }
}
