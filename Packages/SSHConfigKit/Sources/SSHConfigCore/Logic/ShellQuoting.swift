//
//  ShellQuoting.swift
//  sshconfigmanager
//
//  The one audited home for turning strings into shell-safe tokens. This is a
//  security surface: a value like `ProxyCommand=; rm -rf ~` pasted into a shell
//  must come out inert. Two modes, because there are two needs:
//
//  - `argument(_:)` — an arbitrary argv token (building `ssh`/tunnel command
//    lines). Left bare when it contains only shell-inert characters (so common
//    cases read cleanly), otherwise single-quoted.
//  - `homePath(_:)` — a file path where a leading `~/` is kept *outside* the
//    quotes so the shell still expands it to the user's home directory.
//
//  Both splice embedded single quotes out as `'\''`. `nonisolated` so the pure
//  logic is callable from NIO callbacks and other off-main contexts.
//

import Foundation

public nonisolated enum ShellQuoting {
    /// Characters safe to leave unquoted in an argv token. `~` is intentionally
    /// included so a leading-tilde path still expands when the whole token is bare.
    private static let safeArgumentScalars = CharacterSet(
        charactersIn:
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-./:=@%+,~")

    /// POSIX-safe quoting for an arbitrary argument. Bare when shell-inert,
    /// otherwise wrapped in single quotes.
    public static func argument(_ value: String) -> String {
        if value.isEmpty { return "''" }
        if value.unicodeScalars.allSatisfy(safeArgumentScalars.contains) { return value }
        return singleQuoted(value)
    }

    /// POSIX-safe quoting for a file path, keeping a leading `~/` outside the
    /// quotes so the shell still expands the home directory. `~` alone stays bare.
    public static func homePath(_ path: String) -> String {
        if path == "~" { return "~" }
        if path.hasPrefix("~/") {
            let rest = String(path.dropFirst(2))
            return rest.isEmpty ? "~/" : "~/" + singleQuoted(rest)
        }
        return singleQuoted(path)
    }

    /// Wraps in single quotes, splicing embedded single quotes out as `'\''`.
    private static func singleQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
