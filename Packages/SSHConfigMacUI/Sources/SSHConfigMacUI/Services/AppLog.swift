//
//  AppLog.swift
//  sshconfigmanager
//
//  Level guidance (unified logging persistence): use `.notice` (the default) for
//  meaningful state transitions you'd want in a bug report — it's persisted to
//  disk and therefore readable back via OSLogStore. Use `.error`/`.fault` for
//  failures. Use `.info` for the fine-grained trail (per-edit, per-request): it
//  lives in the memory buffer, so it shows up in the in-app Log window and in a
//  same-session bug report, but costs nothing on disk.
//
//  Avoid `.debug` for anything you expect a user to *see*: the system only
//  captures debug entries when debug logging is explicitly enabled for the
//  subsystem (`log config --subsystem … --mode level:debug`), so a `.debug` line
//  is invisible in the Log window on a normal machine. Reserve it for tracing
//  you'd only ever read while attached to a debugger. Never log secrets, key
//  material, or full file contents; default string interpolation in `Logger` is
//  already redacted as `<private>` unless you opt into `.public`.
//

import Foundation
import os

/// Namespaced `Logger`s for the whole app. Add a category here rather than
/// constructing ad-hoc `Logger(subsystem:category:)` instances at call sites.
nonisolated enum Log {
    /// The shared subsystem — the app's bundle id. Matches the value the older
    /// scattered loggers used, so existing Console filters keep working.
    static let subsystem = AppIdentity.bundleIdentifier

    static let categories = [
        "app", "config", "fileaccess", "keys", "knownhosts", "agent",
        "tunnel", "database", "diagnostics", "settings",
        "login-item", "terminal-launch",
    ]

    /// App lifecycle, window/scene wiring, top-level coordination.
    static let app = Logger(subsystem: subsystem, category: "app")
    /// ssh_config parsing, loading, and saving.
    static let config = Logger(subsystem: subsystem, category: "config")
    /// Security-scoped `~/.ssh` access (bookmarks, sandbox file I/O).
    static let fileAccess = Logger(subsystem: subsystem, category: "fileaccess")
    /// Key listing/generation/import.
    static let keys = Logger(subsystem: subsystem, category: "keys")
    /// known_hosts read/verify/edit.
    static let knownHosts = Logger(subsystem: subsystem, category: "knownhosts")
    /// ssh-agent service + socket.
    static let agent = Logger(subsystem: subsystem, category: "agent")
    /// In-process tunnel engine + supervisor.
    static let tunnel = Logger(subsystem: subsystem, category: "tunnel")
    /// SQLite persistence layer.
    static let database = Logger(subsystem: subsystem, category: "database")
    static let diagnostics = Logger(subsystem: subsystem, category: "diagnostics")
    /// Settings load/persist.
    static let settings = Logger(subsystem: subsystem, category: "settings")
    /// Launch-at-login registration.
    static let loginItem = Logger(subsystem: subsystem, category: "login-item")
    /// Terminal launching.
    static let terminalLaunch = Logger(subsystem: subsystem, category: "terminal-launch")
}
