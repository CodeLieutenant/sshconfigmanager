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
    var knownHostsFileURL: URL? {
        fileAccess.directoryURL?.appendingPathComponent(knownHostsFileName, isDirectory: false)
    }

    func loadKnownHosts(clearingExternalChange: Bool = true) {
        if clearingExternalChange { externalKnownHostsChange = nil }
        guard let url = knownHostsFileURL else {
            knownHosts = []
            return
        }
        let text = (try? fileAccess.readText(at: url)) ?? ""
        knownHosts = KnownHostsService.parse(text)
        Log.knownHosts.info(
            "loaded \(self.knownHosts.count, privacy: .public) entry(s) from \(url.lastPathComponent, privacy: .public)"
        )
    }

    func dismissExternalKnownHostsChange() {
        externalKnownHostsChange = nil
    }

    func knownHostsFileChoices() -> [String] {
        let onDisk = (try? fileAccess.directoryFiles())?.map(\.lastPathComponent) ?? []
        var names = Set(onDisk)
        names.insert("known_hosts")
        names.insert(knownHostsFileName)
        return names.sorted()
    }

    func selectKnownHostsFile(named name: String) {
        guard name != knownHostsFileName else { return }
        Log.knownHosts.notice("switched known_hosts file to \(name, privacy: .public)")
        knownHostsFileName = name
        loadKnownHosts()
        updateFileWatchers()
    }

    func chooseKnownHostsFile() {
        guard
            let url = fileAccess.chooseFileInGrantedDirectory(
                message: "Choose a known_hosts file inside your SSH folder.",
                prompt: "Choose")
        else { return }
        selectKnownHostsFile(named: url.lastPathComponent)
    }

    @discardableResult
    func addKnownHostLine(_ raw: String) -> Bool {
        guard let url = knownHostsFileURL else {
            errorMessage = SSHFileAccessError.noDirectory.localizedDescription
            return false
        }
        guard KnownHostsService.isValidLine(raw) else {
            errorMessage =
                "That isn't a valid known_hosts entry. A line looks like: "
                + "“hostname ssh-ed25519 AAAA…”."
            return false
        }
        let text = (try? fileAccess.readText(at: url)) ?? ""
        let updated = KnownHostsService.appending(line: raw, to: text)
        do {
            try fileAccess.writeText(updated, to: url, makeBackup: true)
            Log.knownHosts.notice("added a known_hosts entry by hand")
            loadKnownHosts()
            return true
        } catch {
            Log.knownHosts.error("adding a known_hosts entry failed: \(SSHErrorText.describe(error), privacy: .public)")
            errorMessage = error.localizedDescription
            return false
        }
    }

    func deleteKnownHost(_ entry: KnownHostEntry) {
        guard let url = knownHostsFileURL,
            let text = try? fileAccess.readText(at: url)
        else { return }
        let updated = KnownHostsService.removing(lineIndex: entry.lineIndex, from: text)
        do {
            try fileAccess.writeText(updated, to: url, makeBackup: true)
            Log.knownHosts.notice("removed the known_hosts entry for \(entry.hostsDisplay, privacy: .private)")
            loadKnownHosts()
        } catch {
            Log.knownHosts.error(
                "removing a known_hosts entry failed: \(SSHErrorText.describe(error), privacy: .public)")
            errorMessage = error.localizedDescription
        }
    }

    func deleteKnownHosts(_ entries: [KnownHostEntry]) {
        guard !entries.isEmpty else { return }
        guard let url = knownHostsFileURL,
            var text = try? fileAccess.readText(at: url)
        else { return }
        for lineIndex in entries.map(\.lineIndex).sorted(by: >) {
            text = KnownHostsService.removing(lineIndex: lineIndex, from: text)
        }
        do {
            try fileAccess.writeText(text, to: url, makeBackup: true)
            Log.knownHosts.notice("removed \(entries.count, privacy: .public) known_hosts entry(s)")
            loadKnownHosts()
        } catch {
            Log.knownHosts.error(
                "removing known_hosts entries failed: \(SSHErrorText.describe(error), privacy: .public)")
            errorMessage = error.localizedDescription
        }
    }

    func setMarker(_ marker: KnownHostMarker, on entry: KnownHostEntry) {
        guard let url = knownHostsFileURL,
            var text = try? fileAccess.readText(at: url)
        else { return }
        Log.knownHosts.notice(
            "setting marker \(marker.rawValue, privacy: .public) on \(entry.hostsDisplay, privacy: .private)")
        let newLine = KnownHostsService.setMarker(marker, on: entry.raw)
        text = KnownHostsService.replacing(lineIndex: entry.lineIndex, with: newLine, in: text)
        do {
            try fileAccess.writeText(text, to: url, makeBackup: true)
            loadKnownHosts()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    enum KnownHostCleanupAction {
        case remove
        case commentOut
        case replaceWithScanned(openSSHLine: String)
    }

    func applyCleanup(_ action: KnownHostCleanupAction, to entry: KnownHostEntry) {
        guard let url = knownHostsFileURL,
            var text = try? fileAccess.readText(at: url)
        else { return }
        switch action {
        case .remove:
            text = KnownHostsService.removing(lineIndex: entry.lineIndex, from: text)
        case .commentOut:
            text = KnownHostsService.toggleComment(lineIndex: entry.lineIndex, in: text)
        case .replaceWithScanned(let openSSHLine):
            let hostToken = entry.hostsDisplay.replacingOccurrences(of: ", ", with: ",")
            let newLine = "\(hostToken) \(openSSHLine)"
            text = KnownHostsService.replacing(lineIndex: entry.lineIndex, with: newLine, in: text)
        }
        do {
            try fileAccess.writeText(text, to: url, makeBackup: true)
            loadKnownHosts()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func knownHostsStaticFindings() -> [KnownHostEntry.ID: KnownHostsAudit.Finding] {
        KnownHostsAudit.staticFindings(knownHosts, knownNames: Set(knownPlaintextNames()))
    }

    func knownPlaintextNames() -> [String] {
        var names = Set<String>()
        for block in allHostBlocks where !block.isWildcard {
            for alias in block.concreteAliases { names.insert(alias) }
            if let h = block.firstValue(for: "HostName")?.trimmingCharacters(in: .whitespaces),
                !h.isEmpty
            {
                names.insert(h)
            }
        }
        return Array(names)
    }

    func configBlock(forKnownHost host: String) -> HostBlock.ID? {
        let lower = host.lowercased()
        let aliasMap = configAliasesByHost()
        if let aliases = aliasMap[lower], let alias = aliases.first {
            return allHostBlocks.first(where: { $0.primaryAlias == alias })?.id
        }
        return allHostBlocks.first(where: { block in
            block.concreteAliases.contains(where: { $0.lowercased() == lower })
        })?.id
    }

    func revealInEditor(_ id: HostBlock.ID) {
        selectedBlockID = id
    }

    @discardableResult
    func createConfigBlock(forKnownHost host: String, alias: String) -> HostBlock.ID? {
        let trimmedAlias = alias.trimmingCharacters(in: .whitespaces)
        let trimmedHost = host.trimmingCharacters(in: .whitespaces)
        guard !trimmedAlias.isEmpty, !trimmedHost.isEmpty else { return nil }
        guard let targetURL = mainDocumentURL,
            let index = documents.firstIndex(where: { $0.sourceURL == targetURL })
        else { return nil }
        let header = Directive(keyword: "Host", value: trimmedAlias, isDirty: true)
        let hostNameLine = Directive(
            leadingIndent: "    ", keyword: "HostName",
            value: trimmedHost, isDirty: true)
        let newBlock = HostBlock(
            kind: .host, header: header,
            body: [.directive(hostNameLine)], sourceURL: targetURL)
        mutate("Create config entry") {
            documents[index].appendBlocks([newBlock])
        }
        selectedBlockID = newBlock.id
        return newBlock.id
    }

    func revealKnownHostsFileInFinder() {
        guard let url = knownHostsFileURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func configAliasesByHost() -> [String: [String]] {
        var map: [String: [String]] = [:]
        for block in allHostBlocks where !block.isWildcard {
            guard let alias = block.primaryAlias else { continue }
            var hostKeys: Set<String> = []
            if let hostName = block.firstValue(for: "HostName")?.trimmingCharacters(in: .whitespaces),
                !hostName.isEmpty
            {
                hostKeys.insert(hostName.lowercased())
            }
            for a in block.concreteAliases { hostKeys.insert(a.lowercased()) }
            for key in hostKeys where map[key]?.contains(alias) != true {
                map[key, default: []].append(alias)
            }
        }
        return map
    }

    @discardableResult
    func resolveHostKey(
        hostToken: String, newOpenSSHLine: String,
        replacingType: String?
    ) -> Bool {
        guard let url = knownHostsFileURL else {
            errorMessage = SSHFileAccessError.noDirectory.localizedDescription
            return false
        }
        let fullLine = "\(hostToken) \(newOpenSSHLine)"
        guard KnownHostsService.isValidLine(fullLine) else {
            errorMessage = "The scanned host key couldn’t be written as a known_hosts entry."
            return false
        }
        var text = (try? fileAccess.readText(at: url)) ?? ""
        if let replacingType {
            let victims = KnownHostsService.parse(text).filter { entry in
                entry.keyType == replacingType && hostFieldMatches(entry, token: hostToken)
            }
            for lineIndex in victims.map(\.lineIndex).sorted(by: >) {
                text = KnownHostsService.removing(lineIndex: lineIndex, from: text)
            }
        }
        text = KnownHostsService.appending(line: fullLine, to: text)
        do {
            try fileAccess.writeText(text, to: url, makeBackup: true)
            loadKnownHosts()
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    enum FetchHostKeyResult: Sendable {
        case added(keyType: String, fingerprint: String)
        case alreadyTrusted(keyType: String)
        case failed(String)
        case noTarget
    }

    func fetchHostKey(for block: HostBlock) async -> FetchHostKeyResult {
        guard let (host, port) = block.connectionTarget else { return .noTarget }
        switch await HostKeyScanner.scan(host: host, port: port) {
        case .failure(let error):
            return .failed(error.message)
        case .success(let probe):
            guard let url = knownHostsFileURL else {
                return .failed(SSHFileAccessError.noDirectory.localizedDescription)
            }
            let token = port == 22 ? host : "[\(host)]:\(port)"
            let text = (try? fileAccess.readText(at: url)) ?? ""

            if KnownHostsService.parse(text).contains(where: {
                !$0.isHashed && $0.fingerprint == probe.fingerprint && hostFieldMatches($0, token: token)
            }) {
                return .alreadyTrusted(keyType: probe.keyType)
            }

            let line = "\(token) \(probe.openSSH)"
            guard KnownHostsService.isValidLine(line) else {
                return .failed("The fetched key couldn’t be written as a known_hosts entry.")
            }
            do {
                try fileAccess.writeText(
                    KnownHostsService.appending(line: line, to: text),
                    to: url, makeBackup: true)
                loadKnownHosts()
                return .added(keyType: probe.keyType, fingerprint: probe.fingerprint)
            } catch {
                return .failed(error.localizedDescription)
            }
        }
    }

    func persistTrustedHostKey(host: String, port: Int, hashKnownHosts: Bool, openSSHKeyLine: String) {
        guard KnownHostsService.isSafeHostToken(host) else { return }
        guard let url = knownHostsFileURL else { return }
        let text = (try? fileAccess.readText(at: url)) ?? ""
        var salt = Data(count: 20)
        _ = salt.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 20, $0.baseAddress!) }
        let line = KnownHostsService.formatTrustLine(
            host: host, port: port, openSSHKeyLine: openSSHKeyLine,
            hashed: hashKnownHosts, salt: salt, hmacSHA1: KnownHostsValidatingDelegate.hmacSHA1)
        guard KnownHostsService.isValidLine(line) else { return }
        guard !text.split(separator: "\n").contains(Substring(line)) else { return }
        try? fileAccess.writeText(KnownHostsService.appending(line: line, to: text), to: url, makeBackup: true)
        loadKnownHosts()
    }

    private func hostFieldMatches(_ entry: KnownHostEntry, token: String) -> Bool {
        guard !entry.isHashed else { return false }
        let entryNames = Set(entry.hostsDisplay.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
        let tokenNames = Set(token.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
        return !entryNames.isDisjoint(with: tokenNames)
    }
}
