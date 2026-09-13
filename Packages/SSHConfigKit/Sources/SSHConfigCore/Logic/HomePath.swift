//
//  HomePath.swift
//  sshconfigmanager
//
//  Collapsing an absolute path under the user's home to `~/…` — the shorthand
//  ssh_config itself uses, and the only form that survives the file being synced
//  to another machine or shared with a Linux box. File pickers, drag-and-drop and
//  key enumeration all hand back `/Users/<you>/…`, which is portable to nothing.
//
//  `home` is always passed in rather than read here: under the App Sandbox both
//  `NSHomeDirectory()` and `FileManager.homeDirectoryForCurrentUser` return the
//  *container*, so anything anchored on them silently fails to abbreviate a real
//  `~/.ssh/…` path. The app layer supplies `SSHFileAccess.realHomeDirectory`; on
//  Linux it'll supply `$HOME`.
//

import Foundation

public enum HomePath {
    /// `path` with a leading `home` replaced by `~`, or unchanged when it doesn't
    /// live under `home`. Matching is on whole path components, so a sibling
    /// directory that merely shares the prefix (`/Users/dana-old` next to
    /// `/Users/dana`) is left alone.
    public static func abbreviating(_ path: String, home: String) -> String {
        let home = home.hasSuffix("/") ? String(home.dropLast()) : home
        guard !home.isEmpty, !path.hasPrefix("~") else { return path }
        if path == home { return "~" }
        guard path.hasPrefix(home + "/") else { return path }
        return "~" + path.dropFirst(home.count)
    }

    /// The inverse: `~`/`~/…` expanded against `home`. `~user` forms are left alone
    /// — resolving another account's home is the OS's job, not a string rewrite.
    public static func expanding(_ path: String, home: String) -> String {
        guard !home.isEmpty else { return path }
        if path == "~" { return home }
        guard path.hasPrefix("~/") else { return path }
        return home + path.dropFirst(1)
    }
}
