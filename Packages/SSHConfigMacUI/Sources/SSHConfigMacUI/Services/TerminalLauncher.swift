//
//  TerminalLauncher.swift
//  sshconfigmanager
//
//  The one piece of Connect & Launch that touches the OS: it opens a terminal
//  window running a built `ssh` command. The app is sandboxed, so `Process` →
//  `open -a Terminal` is out; the only high-fidelity path is AppleScript
//  `do script` into Terminal/iTerm, which needs the apple-events entitlement and
//  a one-time user-consent prompt. When that path isn't available — the terminal
//  exposes no reachable scripting verb, or the user denied automation — we fall
//  back to copying the command and telling the user to paste it.
//
//  Pure helpers (script construction, AppleScript quoting, the `{ssh}` template)
//  live as statics so they're unit-tested without launching anything; only
//  `launch` has side effects.
//

import AppKit
import Foundation
import SSHConfigCore
import os

/// What happened when we tried to connect. Both are non-fatal: the command is
/// always either running or on the clipboard, never lost.
enum TerminalLaunchOutcome: Equatable {
    /// A window opened in the named terminal and ran the command.
    case launched(terminalName: String)
    /// We couldn't drive the terminal; the command is on the clipboard. `message`
    /// is a user-facing explanation of why and what to do.
    case copiedToClipboard(message: String)
}

/// Behind a protocol so `ConfigStore.connect` is testable without AppleScript.
@MainActor
protocol TerminalLaunching {
    func launch(_ command: SSHCommandBuilder.Command, using preset: TerminalPreset) -> TerminalLaunchOutcome
}

@MainActor
struct TerminalLauncher: TerminalLaunching {
    private static let log = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "sshconfigmanager", category: "terminal-launch")

    func launch(_ command: SSHCommandBuilder.Command, using preset: TerminalPreset) -> TerminalLaunchOutcome {
        switch preset.handoff {
        case .appleScript(let dialect):
            let source = Self.appleScript(for: dialect, command: command.shellString)
            if let failure = runAppleScript(source) {
                // Log the raw AppleScript error number so a field report ("connect did
                // nothing") is diagnosable from Console without reproducing — -1743 is a
                // denied/poisoned automation grant, the most common cause.
                Self.log.error(
                    "AppleScript handoff to \(preset.name, privacy: .public) failed: error \(failure, privacy: .public)"
                )
                copyToClipboard(command.shellString)
                return .copiedToClipboard(message: Self.failureMessage(for: failure, terminalName: preset.name))
            }
            return .launched(terminalName: preset.name)
        case .clipboardOnly:
            #if UNSANDBOXED
                if let argv = Self.processLaunchArguments(for: preset, command: command.shellString) {
                    do {
                        try Self.launchProcess(argv)
                        return .launched(terminalName: preset.name)
                    } catch {
                        Self.log.error(
                            "Process handoff to \(preset.name, privacy: .public) failed: \(error.localizedDescription, privacy: .public)"
                        )
                    }
                }
            #endif
            copyToClipboard(command.shellString)
            return .copiedToClipboard(message: Self.clipboardOnlyMessage(terminalName: preset.name))
        }
    }

    static func clipboardOnlyMessage(terminalName: String) -> String {
        #if UNSANDBOXED
            return "Couldn't launch \(terminalName) — the command is on your clipboard; paste it into \(terminalName)."
        #else
            return "\(terminalName) can't be launched from a sandboxed app, but the command "
                + "is on your clipboard — paste it into \(terminalName)."
        #endif
    }

    static func processLaunchArguments(for preset: TerminalPreset, command: String) -> [String]? {
        switch preset.id {
        case "ghostty":
            return ["-na", preset.name, "--args", "-e", "/bin/sh", "-c", command]
        case "kitty":
            return ["-na", preset.name, "--args", "/bin/sh", "-c", command]
        case "wezterm":
            return ["-na", preset.name, "--args", "start", "--", "/bin/sh", "-c", command]
        default:
            return nil
        }
    }

    private static func launchProcess(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = arguments
        try process.run()
    }

    /// Runs an AppleScript source string. Returns `nil` on success, or the
    /// `NSAppleScript` error number on failure so the caller can explain *why* we
    /// fell back (a denied/poisoned automation grant is -1743; a missing app is
    /// -600/-609; everything else is treated as a generic script failure).
    private func runAppleScript(_ source: String) -> Int? {
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else { return Self.osaGenericError }
        script.executeAndReturnError(&error)
        guard let error else { return nil }
        return (error[NSAppleScript.errorNumber] as? Int) ?? Self.osaGenericError
    }

    /// AppleEvent/OSA error numbers not surfaced by Foundation's Swift overlay.
    private static let osaGenericError = -2700 // errOSAGeneric
    private static let eventNotHandled = -1708 // errAEEventNotHandled

    /// Maps an `NSAppleScript` error number to a user-facing fallback message. The
    /// command is always already on the clipboard by the time this is shown.
    static func failureMessage(for errorNumber: Int, terminalName: String) -> String {
        switch errorNumber {
        case errAEEventNotPermitted:
            // -1743: macOS denied the Apple event. Either the user clicked "Don't
            // Allow", or the recorded grant no longer matches this build's code
            // signature (common when alternating signed/unsigned builds). The
            // Automation toggle existing-but-off and a stale grant look identical
            // here, so point at the reset path too.
            return "\(terminalName) blocked automation. Enable it under System Settings ▸ "
                + "Privacy & Security ▸ Automation (or run `tccutil reset AppleEvents "
                + "\(AppIdentity.bundleIdentifier)` if the toggle is missing). The command "
                + "is on your clipboard; paste it into a terminal."
        case Self.eventNotHandled, procNotFound:
            // -600/-1708: the terminal app isn't reachable to script.
            return "Couldn't reach \(terminalName) to run the command — it's on your "
                + "clipboard; paste it into a terminal."
        default:
            return "Couldn't control \(terminalName) (error \(errorNumber)). The command is "
                + "on your clipboard; paste it into a terminal."
        }
    }

    private func copyToClipboard(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }

    // MARK: - Pure helpers (unit-tested)

    /// Substitutes the built command into a user `{ssh}` template. An empty or
    /// placeholder-free template means "run the command as-is".
    static func applyTemplate(_ template: String, to command: String) -> String {
        let trimmed = template.trimmingCharacters(in: .whitespaces)
        guard trimmed.contains("{ssh}") else { return command }
        return trimmed.replacingOccurrences(of: "{ssh}", with: command)
    }

    /// Quotes a string for use as an AppleScript string literal: backslash and
    /// double-quote escaped. The command was already shell-quoted upstream; this
    /// is the second, AppleScript-level escaping so the line survives both hops.
    static func appleScriptQuote(_ string: String) -> String {
        let escaped =
            string
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"" + escaped + "\""
    }

    /// Builds the AppleScript that opens a window and runs `command`.
    static func appleScript(for dialect: TerminalPreset.AppleScriptDialect, command: String) -> String {
        let literal = appleScriptQuote(command)
        switch dialect {
        case .terminal:
            return """
                tell application "Terminal"
                    activate
                    do script \(literal)
                end tell
                """
        case .iterm:
            return """
                tell application "iTerm"
                    activate
                    set newWindow to (create window with default profile)
                    tell current session of newWindow to write text \(literal)
                end tell
                """
        }
    }
}
