//
//  SSHCommandBuilder.swift
//  sshconfigmanager
//
//  Pure, I/O-free construction of the `ssh` invocations the Connect &
//  Launch feature hands to the user's own tools. No `NSWorkspace`, no `Process`,
//  no clipboard — it only builds strings and arrays, so every rule here is unit
//  testable. The side effects (clipboard, terminal launch) live elsewhere.
//
//  Two command styles, both from the same code:
//
//  * **Alias mode** emits `ssh <alias>` and lets the real `ssh` re-read the
//    config, so `ProxyJump`, `Match`, `%`-tokens, `IdentityAgent`, etc. all
//    behave exactly as configured. This is the correct default for *connecting*,
//    because our `EffectiveConfigResolver` is necessarily a partial reimpl.
//  * **Explicit mode** flattens the resolved settings into flags
//    (`ssh -i … -p … -J … user@host`) so the line is portable to a script, a CI
//    job, or a machine without this `Host` block. This is where the resolver
//    earns its keep.
//

import Foundation

public enum SSHCommandBuilder {
    /// A built command in two equivalent forms.
    public struct Command: Equatable {
        /// The argument vector, e.g. `["ssh", "-i", "~/.ssh/id", "-p", "2222", "deploy@host"]`.
        public var argv: [String]
        /// The same vector, shell-quoted and joined — ready to paste into a shell.
        public var shellString: String

        public init(argv: [String], shellString: String) {
            self.argv = argv
            self.shellString = shellString
        }
    }

    /// Keywords explicit mode maps to dedicated flags; every *other* resolved
    /// setting falls through to the generic `-o Keyword=value` form. Lowercased
    /// to match `ResolvedSetting.keyword` case-insensitively.
    private static let speciallyHandled: Set<String> = [
        "hostname", "user", "port", "identityfile", "proxyjump",
    ]

    // MARK: - Alias mode

    /// `ssh <alias>` plus any caller-forced extras (e.g. `-v`). The alias is the
    /// first concrete (non-wildcard) `Host` pattern; if the block is pattern-only
    /// it falls back to the block's own `HostName`. Returns `ssh` with no
    /// destination when neither exists — callers should guard with
    /// `block.connectionTarget != nil` / disable the action for such blocks.
    public static func aliasCommand(for block: HostBlock, extraOptions: [String] = []) -> Command {
        let destination = block.primaryAlias ?? block.firstValue(for: "HostName")
        var argv = ["ssh"] + extraOptions
        if let destination, !destination.isEmpty { argv.append(destination) }
        return command(from: argv)
    }

    // MARK: - Explicit mode

    /// Flattens the resolved settings for `alias` into an explicit `ssh` line.
    /// `User` becomes the `user@` prefix, `HostName` the destination host (falling
    /// back to `alias`), `Port` a `-p`, each `IdentityFile` a `-i`, `ProxyJump` a
    /// `-J`, and everything else a generic `-o Keyword=value` (preserving order and
    /// repeats — e.g. multiple `LocalForward`s).
    public static func explicitCommand(target alias: String, resolved: [ResolvedSetting]) -> Command {
        var argv = ["ssh"]

        if let port = resolved.firstValue(of: "port"), port != "22" {
            argv += ["-p", port]
        }
        for identity in resolved.values(of: "identityfile") {
            argv += ["-i", identity]
        }
        if let jump = resolved.firstValue(of: "proxyjump") {
            argv += ["-J", jump]
        }
        // Generic fallback for every other resolved keyword, preserving order so a
        // global `Host *` default and a host-specific override read as written.
        for setting in resolved where !speciallyHandled.contains(setting.keyword.lowercased()) {
            argv += ["-o", "\(setting.keyword)=\(setting.value)"]
        }

        let host = resolved.firstValue(of: "hostname") ?? alias
        if let user = resolved.firstValue(of: "user"), !user.isEmpty {
            argv.append("\(user)@\(host)")
        } else {
            argv.append(host)
        }

        return command(from: argv)
    }

    // MARK: - Deploy (ssh-copy-id)

    /// The `ssh-copy-id` workflow as a single self-contained line: `ssh <alias>
    /// '<remote one-liner>'`. We deploy in **alias mode** (like `aliasCommand`) so
    /// the user's real `ssh` honors `User`/`Port`/`ProxyJump`/`IdentityFile` and —
    /// crucially for a *first* key push — handles password auth and host-key TOFU
    /// itself, which is exactly when you deploy a key. Returns `nil` when the block
    /// has no concrete destination or the key line is blank.
    ///
    /// The remote one-liner is idempotent and permission-correct: `umask 077`
    /// plus an explicit `mkdir`/`touch` create `~/.ssh` (`0700`) and
    /// `authorized_keys` (`0600`) if absent, and `grep -qxF` de-dupes so repeated
    /// deploys never append the key twice — matching the local hygiene the key
    /// health audit enforces. Only the *public* key is ever transmitted.
    ///
    /// Quoting survives two shells: `shellQuote` single-quotes the key for the
    /// *remote* shell (so a space- or quote-bearing comment stays one token), then
    /// `command(from:)` single-quotes the whole remote string for the *local* shell.
    public static func deployCommand(for block: HostBlock, publicKeyLine: String) -> Command? {
        guard let destination = block.primaryAlias ?? block.firstValue(for: "HostName"),
            !destination.isEmpty
        else { return nil }
        let key = publicKeyLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return nil }

        let quotedKey = shellQuote(key)
        let remote =
            "umask 077; mkdir -p ~/.ssh && touch ~/.ssh/authorized_keys && "
            + "grep -qxF \(quotedKey) ~/.ssh/authorized_keys "
            + "|| echo \(quotedKey) >> ~/.ssh/authorized_keys"
        return command(from: ["ssh", destination, remote])
    }

    // MARK: - Shell quoting

    /// POSIX-safe single-argument quoting — see `ShellQuoting.argument`.
    public nonisolated static func shellQuote(_ argument: String) -> String {
        ShellQuoting.argument(argument)
    }

    /// Pairs an argv with its shell-quoted, space-joined rendering.
    private static func command(from argv: [String]) -> Command {
        Command(argv: argv, shellString: argv.map(shellQuote).joined(separator: " "))
    }
}
