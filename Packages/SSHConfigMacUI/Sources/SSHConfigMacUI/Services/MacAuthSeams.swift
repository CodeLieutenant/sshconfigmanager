//
//  MacAuthSeams.swift
//  SSHConfigMacUI
//
//  The macOS side of the engine's two authentication seams: an AppKit alert for
//  every secret the server asks for, and the app's own agent actor for signing.
//
//  The alert code moved here verbatim when SSHAuthDelegates went into
//  SSHConfigEngine — it is the part that cannot follow the engine to Linux.
//

import AppKit
import Foundation
import SSHConfigCore
import SSHConfigEngine

/// Asks the user for a password or 2FA response with a modal alert.
///
/// A value type, not an actor: every method hops to the main actor for the alert
/// itself, so there is no state here to protect.
struct MacCredentialPrompter: SSHCredentialPrompting {
    func promptForPassword(username: String) async -> String? {
        await MainActor.run {
            NSApp.activate()
            let alert = NSAlert()
            alert.messageText = "Password Required"
            alert.informativeText = "Enter the password for \(username)."
            alert.addButton(withTitle: "Continue")
            alert.addButton(withTitle: "Cancel")
            let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
            alert.accessoryView = field
            alert.window.initialFirstResponder = field
            guard alert.runModal() == .alertFirstButtonReturn else { return nil }
            return field.stringValue
        }
    }

    func promptForChallenges(
        name: String, instruction: String, prompts: [SSHAuthPrompt]
    ) async -> [String]? {
        guard !prompts.isEmpty else { return [] }
        return await MainActor.run {
            NSApp.activate()
            let alert = NSAlert()
            alert.messageText = name.isEmpty ? "Authentication Required" : name
            alert.informativeText = instruction
            alert.addButton(withTitle: "Continue")
            alert.addButton(withTitle: "Cancel")

            // Stack one field per prompt vertically.
            let fieldHeight: CGFloat = 24
            let spacing: CGFloat = 6
            let labelHeight: CGFloat = 18
            let rowHeight = labelHeight + spacing + fieldHeight
            let totalHeight = CGFloat(prompts.count) * rowHeight - spacing
            let containerWidth: CGFloat = 280
            let container = NSView(frame: NSRect(x: 0, y: 0, width: containerWidth, height: totalHeight))

            var fields: [NSTextField] = []
            for (index, prompt) in prompts.enumerated().reversed() {
                let rowY = CGFloat(index) * rowHeight
                let label = NSTextField(labelWithString: prompt.text)
                label.frame = NSRect(
                    x: 0, y: rowY + fieldHeight + spacing, width: containerWidth, height: labelHeight)
                label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
                container.addSubview(label)

                let field: NSTextField =
                    prompt.echo
                    ? NSTextField(frame: NSRect(x: 0, y: rowY, width: containerWidth, height: fieldHeight))
                    : NSSecureTextField(frame: NSRect(x: 0, y: rowY, width: containerWidth, height: fieldHeight))
                container.addSubview(field)
                fields.insert(field, at: 0)
            }

            alert.accessoryView = container
            alert.window.initialFirstResponder = fields.first

            guard alert.runModal() == .alertFirstButtonReturn else { return nil }
            return fields.map { $0.stringValue }
        }
    }
}

/// Signs through the app's `SSHAgentService`, which owns the agent socket and the
/// sandbox entitlement that makes it reachable.
struct MacAgentSigner: SSHAgentSigning {
    func sign(
        keyBlob: [UInt8], data: [UInt8], flags: UInt32, socketPath: String?
    ) async throws -> [UInt8] {
        try await SSHAgentService().sign(
            keyBlob: keyBlob, data: data, flags: flags, socketPath: socketPath)
    }
}
