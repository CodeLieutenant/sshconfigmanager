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
    func refreshAgent() async {
        #if DEBUG
            if ScreenshotMode.isActive {
                agentIdentities = ScreenshotMode.sampleAgentIdentities()
                agentStatus = .available
                return
            }
        #endif
        guard SSHAgentService.isAvailable else {
            agentIdentities = []
            agentStatus = .unavailable
            return
        }
        do {
            agentIdentities = try await SSHAgentService().listIdentities()
            agentStatus = .available
        } catch {
            agentIdentities = []
            agentStatus = .failed(error.localizedDescription)
        }
    }

    func removeAgentIdentity(keyBlob: [UInt8]) async {
        do {
            try await SSHAgentService().removeIdentity(keyBlob: keyBlob)
        } catch {
            errorMessage = error.localizedDescription
        }
        await refreshAgent()
    }

    func removeAllAgentIdentities() async {
        do {
            try await SSHAgentService().removeAll()
        } catch {
            errorMessage = error.localizedDescription
        }
        await refreshAgent()
    }

    enum AgentAddError: LocalizedError {
        case noPrivateKey
        case unreadable
        case cancelled
        var errorDescription: String? {
            switch self {
            case .noPrivateKey: return "This key has no private-key file to load."
            case .unreadable: return "Couldn't read the private-key file."
            case .cancelled: return nil
            }
        }
    }

    @discardableResult
    func addKeyToAgent(_ key: SSHPublicKey) async -> Bool {
        do {
            let (pem, _) = try readPrivateKey(key)
            let passphrase = try resolvePassphrase(forPEM: pem, keyName: key.name)
            try await loadIntoAgent(pem: pem, passphrase: passphrase, comment: agentComment(for: key))
            await refreshAgent()
            return true
        } catch AgentAddError.cancelled {
            return false
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func isRememberedAcrossReboots(_ key: SSHPublicKey) -> Bool {
        guard let name = key.privateKeyURL?.lastPathComponent else { return false }
        return rememberedKeyNames.contains(name)
    }

    @discardableResult
    func rememberKeyAcrossReboots(_ key: SSHPublicKey) async -> Bool {
        do {
            let (pem, name) = try readPrivateKey(key)
            let passphrase = try resolvePassphrase(forPEM: pem, keyName: key.name)
            try await loadIntoAgent(pem: pem, passphrase: passphrase, comment: agentComment(for: key))
            try passphraseStore.store(passphrase: passphrase ?? "", forKeyPath: name)
            rememberedKeyNames.insert(name)
            LoginItemManager.enable()
            await refreshAgent()
            return true
        } catch AgentAddError.cancelled {
            return false
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func forgetKeyAcrossReboots(_ key: SSHPublicKey) {
        guard let name = key.privateKeyURL?.lastPathComponent else { return }
        passphraseStore.remove(forKeyPath: name)
        rememberedKeyNames.remove(name)
        if rememberedKeyNames.isEmpty { LoginItemManager.disable() }
    }

    func reloadPersistedAgentKeys() async {
        let names = passphraseStore.allKeyPaths()
        guard !names.isEmpty else { return }
        rememberedKeyNames = Set(names)
        for name in names {
            guard let pem = grantedFileText(named: name) else { continue }
            let stored = passphraseStore.passphrase(forKeyPath: name)
            let passphrase = (stored?.isEmpty == true) ? nil : stored
            let comment =
                publicKeys.first { $0.privateKeyURL?.lastPathComponent == name }
                .map(agentComment(for:)) ?? name
            do {
                try await loadIntoAgent(pem: pem, passphrase: passphrase, comment: comment)
            } catch {
                continue
            }
        }
        await refreshAgent()
    }

    private func readPrivateKey(_ key: SSHPublicKey) throws -> (pem: String, name: String) {
        guard let url = key.privateKeyURL else { throw AgentAddError.noPrivateKey }
        let name = url.lastPathComponent
        guard let pem = grantedFileText(named: name) else { throw AgentAddError.unreadable }
        return (pem, name)
    }

    private func agentComment(for key: SSHPublicKey) -> String {
        key.comment.isEmpty ? key.name : key.comment
    }

    private func resolvePassphrase(forPEM pem: String, keyName: String) throws -> String? {
        guard OpenSSHPrivateKey.isEncrypted(pem: pem) == true else { return nil }
        guard let entered = Self.promptForPassphrase(keyName: keyName) else {
            throw AgentAddError.cancelled
        }
        return entered
    }

    private func loadIntoAgent(pem: String, passphrase: String?, comment: String) async throws {
        let body = try await Task.detached(priority: .userInitiated) {
            let parsed = try OpenSSHPrivateKey.parse(pem: pem, passphrase: passphrase)
            return try AgentKeySerializer.addIdentityBody(for: parsed, comment: comment)
        }.value
        try await SSHAgentService().addIdentity(body: body)
    }

    @MainActor
    private static func promptForPassphrase(keyName: String) -> String? {
        let alert = NSAlert()
        alert.messageText = "Passphrase for \(keyName)"
        alert.informativeText = "This key is encrypted. Enter its passphrase to add it to the SSH agent."
        alert.addButton(withTitle: "Add to Agent")
        alert.addButton(withTitle: "Cancel")
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return field.stringValue
    }
}
