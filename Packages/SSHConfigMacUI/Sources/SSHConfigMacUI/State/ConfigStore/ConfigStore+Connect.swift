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
    func connect(knownHost group: KnownHostGroup) {
        let targetHost = group.connectHost ?? group.title
        if let blockID = configBlock(forKnownHost: targetHost),
            let b = block(id: blockID)
        {
            connect(b)
        } else {
            connectRaw(host: targetHost, port: group.connectPort)
        }
    }

    func connectRaw(host: String, port: Int = 22) {
        var argv = ["ssh"]
        if port != 22 { argv.append(contentsOf: ["-p", String(port)]) }
        argv.append(host)
        let shellString = argv.map(SSHCommandBuilder.shellQuote).joined(separator: " ")
        let wrapped = TerminalLauncher.applyTemplate(settings.terminalCommandTemplate, to: shellString)
        let command = SSHCommandBuilder.Command(argv: argv, shellString: wrapped)
        let preset = TerminalPreset.preset(id: settings.preferredTerminalID)
        switch terminalLauncher.launch(command, using: preset) {
        case .launched: break
        case .copiedToClipboard(let message): launchStatus = message
        }
    }

    func copySSHCommand(for block: HostBlock) {
        guard let alias = block.primaryAlias else { return }
        let resolved = EffectiveConfigResolver.resolve(target: alias, in: configGraph)
        let command = SSHCommandBuilder.explicitCommand(target: alias, resolved: resolved)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command.shellString, forType: .string)
    }

    func connect(_ block: HostBlock) {
        guard block.connectionTarget != nil else { return }
        let alias = SSHCommandBuilder.aliasCommand(for: block)
        let wrapped = TerminalLauncher.applyTemplate(
            settings.terminalCommandTemplate, to: alias.shellString)
        let command = SSHCommandBuilder.Command(argv: alias.argv, shellString: wrapped)
        let preset = TerminalPreset.preset(id: settings.preferredTerminalID)
        switch terminalLauncher.launch(command, using: preset) {
        case .launched:
            break
        case .copiedToClipboard(let message):
            launchStatus = message
        }
    }

    func deployKey(_ publicKeyLine: String, to block: HostBlock) {
        guard let command = SSHCommandBuilder.deployCommand(for: block, publicKeyLine: publicKeyLine) else { return }
        let wrapped = TerminalLauncher.applyTemplate(
            settings.terminalCommandTemplate, to: command.shellString)
        let final = SSHCommandBuilder.Command(argv: command.argv, shellString: wrapped)
        let preset = TerminalPreset.preset(id: settings.preferredTerminalID)
        switch terminalLauncher.launch(final, using: preset) {
        case .launched:
            break
        case .copiedToClipboard(let message):
            launchStatus = message
        }
    }

    func copyDeployCommand(_ publicKeyLine: String, to block: HostBlock) {
        guard let command = SSHCommandBuilder.deployCommand(for: block, publicKeyLine: publicKeyLine) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command.shellString, forType: .string)
    }
}
