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
    var keyFindings: [LintFinding] {
        KeyAuditor.audit(
            keys: keyAuditInputs, documents: documents,
            sshDirectory: sshDirectorySnapshot, enabled: enabledAuditCategories)
    }

    private var enabledAuditCategories: Set<KeyAuditor.Category> {
        var enabled: Set<KeyAuditor.Category> = []
        if settings.auditWeakKeys { enabled.insert(.weakAlgorithm) }
        if settings.auditKeyPermissions { enabled.insert(.permissions) }
        if settings.auditMissingPassphrase { enabled.insert(.passphrase) }
        if settings.auditOrphanedKeys { enabled.insert(.orphan) }
        return enabled
    }

    func loadKeys() {
        guard hasAccess, let files = try? fileAccess.directoryFiles() else {
            publicKeys = []
            return
        }
        publicKeys = SSHKeyService.discoverKeys(files: files) { try? fileAccess.readText(at: $0) }
        Log.keys.info(
            "discovered \(self.publicKeys.count, privacy: .public) key(s) in \(files.count, privacy: .public) file(s)")
    }

    func loadKeyFindings() {
        guard hasAccess else {
            keyAuditInputs = []
            sshDirectorySnapshot = nil
            return
        }
        keyAuditInputs = SSHKeyService.auditInputs(
            keys: publicKeys,
            readText: { try? fileAccess.readText(at: $0) },
            mode: { try? fileAccess.permissions(of: $0) })
        sshDirectorySnapshot = fileAccess.directoryURL.flatMap { url in
            (try? fileAccess.permissions(of: url)).map { (path: url.path, mode: $0) }
        }
    }

    func hostsUsing(_ key: SSHPublicKey) -> [String] {
        allHostBlocks.filter { block in
            block.directives(for: "IdentityFile").contains { identityBaseName($0.value) == key.name }
        }.compactMap { $0.patterns.first }
    }

    private func identityBaseName(_ directiveValue: String) -> String {
        let value = directiveValue.trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        let expanded = (value as NSString).expandingTildeInPath
        var base = (expanded as NSString).lastPathComponent
        if base.hasSuffix(".pub") { base = String(base.dropLast(4)) }
        return base
    }

    func deleteOrphanedKey(privateKeyPath: String?, publicKeyPath: String?) {
        do {
            if let path = privateKeyPath {
                try fileAccess.deleteFile(at: URL(fileURLWithPath: path), makeBackup: true)
            }
            if let path = publicKeyPath {
                try fileAccess.deleteFile(at: URL(fileURLWithPath: path), makeBackup: true)
            }
            reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    enum KeyCreationError: LocalizedError {
        case noDirectory
        case invalidFileName
        case fileExists(String)
        case notDiscovered

        var errorDescription: String? {
            switch self {
            case .noDirectory:
                return "No SSH folder is granted. Grant access to ~/.ssh first."
            case .invalidFileName:
                return "Enter a valid key name — a single file name with no “/”."
            case .fileExists(let name):
                return "“\(name)” already exists. Choose a different name so an existing key isn't overwritten."
            case .notDiscovered:
                return "The key was written but couldn't be read back. Check the SSH folder."
            }
        }
    }

    @discardableResult
    func createKey(
        algorithm: KeyAlgorithm, fileName: String,
        comment: String, passphrase: String?
    ) throws -> SSHPublicKey {
        guard let directoryURL = fileAccess.directoryURL else { throw KeyCreationError.noDirectory }

        let name = fileName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isValidKeyFileName(name) else { throw KeyCreationError.invalidFileName }

        let pubName = name + ".pub"
        let existing = existingFileNames
        if existing.contains(name) { throw KeyCreationError.fileExists(name) }
        if existing.contains(pubName) { throw KeyCreationError.fileExists(pubName) }

        Log.keys.notice(
            "generating a \(String(describing: algorithm), privacy: .public) key as \(name, privacy: .public), passphrase: \(passphrase?.isEmpty == false, privacy: .public)"
        )
        let generated = try SSHKeyGenerator.generate(
            algorithm: algorithm, comment: comment, passphrase: passphrase)

        try fileAccess.writeText(
            generated.privateKeyPEM,
            to: directoryURL.appendingPathComponent(name),
            makeBackup: false, permissions: 0o600)
        try fileAccess.writeText(
            generated.publicKeyText,
            to: directoryURL.appendingPathComponent(pubName),
            makeBackup: false, permissions: 0o644)
        Log.keys.notice("wrote new key pair \(name, privacy: .public) / \(pubName, privacy: .public)")

        reload()

        guard let key = publicKeys.first(where: { $0.publicKeyURL?.lastPathComponent == pubName }) else {
            throw KeyCreationError.notDiscovered
        }
        return key
    }

    func attachIdentity(fileName: String, toHost id: HostBlock.ID) {
        updateBlock(id: id, actionName: EditAction.setIdentityFile.name) { block in
            block.addDirective(keyword: "IdentityFile", value: "~/.ssh/\(fileName)")
        }
    }

    static func isValidKeyFileName(_ name: String) -> Bool {
        guard !name.isEmpty, name.count <= 255,
            !name.hasPrefix("."), name != ".", name != ".."
        else { return false }
        return !name.contains("/") && !name.contains("\0") && !name.hasSuffix(".pub")
    }

    func browseForKeyFile() -> String? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose a private key file to use as an IdentityFile."
        panel.prompt = "Use Key"
        panel.directoryURL = fileAccess.directoryURL ?? SSHFileAccess.defaultSSHDirectory
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return SSHFileAccess.portablePath(url.path)
    }
}
