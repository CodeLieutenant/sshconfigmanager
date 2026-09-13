//
//  SSHValueQuoting.swift
//  sshconfigmanager
//
//  Quote handling for ssh_config directive *values* (ssh_config(5), "QUOTING").
//

import Foundation

/// Strips/adds the double quotes ssh_config uses to wrap a single-argument value
/// whose path contains spaces — e.g. a 1Password agent socket:
///
///     IdentityAgent "~/Library/Group Containers/2BUA8C4S2C.com.1password/t/agent.sock"
///
/// `ssh` removes the surrounding quotes before using the path, so we must too
/// everywhere a value is *interpreted* (tilde/`%`-token expansion, agent-socket
/// resolution, the sandbox-grant prompt) or *displayed* in the editor. The stored
/// `Directive.value` stays byte-exact for lossless round-tripping — only these
/// semantic accessors unquote, mirroring how the trailing-`\r` of a CRLF file is
/// stripped at the consumer rather than in the stored value (see `HostBlock`).
///
/// Only ever applied to `.path`-kind keywords (`KeywordRegistry.isPath`): a
/// command-line directive like `ProxyCommand ssh -W %h:%p bastion` carries real,
/// significant spaces that must never be quoted or unquoted.
public enum SSHValueQuoting {
    /// Removes a single fully-surrounding pair of double quotes, if present.
    ///
    /// Only a value wholly wrapped in quotes with no interior quote is stripped
    /// (`"~/a b/c"` → `~/a b/c`). A value with interior or partial quotes is left
    /// untouched — splitting it would change its meaning, and a single path
    /// directive is never legitimately two quoted tokens.
    public static func unquoted(_ value: String) -> String {
        guard value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") else { return value }
        let inner = value.dropFirst().dropLast()
        guard !inner.contains("\"") else { return value }
        return String(inner)
    }

    /// Double-quotes `value` when it must be quoted to survive re-parsing — i.e. it
    /// contains whitespace and isn't already wrapped. Whitespace-free values (the
    /// overwhelming majority) and already-quoted ones are returned unchanged, so the
    /// file stays exactly as terse as the user wrote it.
    public static func quotedIfNeeded(_ value: String) -> String {
        guard value.contains(where: { $0 == " " || $0 == "\t" }) else { return value }
        if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") { return value }
        return "\"\(value)\""
    }
}
