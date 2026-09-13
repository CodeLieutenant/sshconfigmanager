//
//  TerminalPreset.swift
//  sshconfigmanager
//
//  Describes how to hand a built `ssh` command to a terminal emulator. The
//  sandbox can't spawn `open -a Terminal`, so the only fidelity path is
//  AppleScript `do script` into Terminal/iTerm (user-consented). Emulators that
//  expose no scriptable "run this command" verb reachable from a sandbox
//  (Ghostty, kitty, WezTerm today) fall back to putting the command on the
//  clipboard — see `TerminalLauncher`.
//

import Foundation

/// A terminal the user can connect through. Built-ins are static; the `id` is the
/// stable token persisted in `AppSettings.preferredTerminalID`.
public struct TerminalPreset: Identifiable, Hashable {
    /// How `TerminalLauncher` hands the command to this terminal.
    public enum Handoff: Hashable {
        /// Drive the app with AppleScript `do script` (needs apple-events consent).
        case appleScript(AppleScriptDialect)
        /// No sandbox-reachable scripting verb — copy the command and tell the user.
        case clipboardOnly
    }

    /// The two AppleScript shapes we know how to write — Terminal and iTerm differ.
    public enum AppleScriptDialect: Hashable { case terminal, iterm }

    public let id: String
    public let name: String
    public let bundleID: String
    public let handoff: Handoff

    /// The shipped list, in display order. Terminal is first because it's always
    /// present on macOS, so it's the safe default.
    public static let builtIns: [TerminalPreset] = [
        .init(
            id: "terminal", name: "Terminal", bundleID: "com.apple.Terminal",
            handoff: .appleScript(.terminal)),
        .init(
            id: "iterm", name: "iTerm2", bundleID: "com.googlecode.iterm2",
            handoff: .appleScript(.iterm)),
        .init(
            id: "ghostty", name: "Ghostty", bundleID: "com.mitchellh.ghostty",
            handoff: .clipboardOnly),
        .init(
            id: "kitty", name: "kitty", bundleID: "net.kovidgoyal.kitty",
            handoff: .clipboardOnly),
        .init(
            id: "wezterm", name: "WezTerm", bundleID: "com.github.wez.wezterm",
            handoff: .clipboardOnly),
    ]

    /// The preset for an id, falling back to Terminal (the always-present default).
    public static func preset(id: String) -> TerminalPreset {
        builtIns.first { $0.id == id } ?? builtIns[0]
    }
}
