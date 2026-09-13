//
//  KnownHostsService.swift
//  sshconfigmanager
//
//  Parses ~/.ssh/known_hosts for read-only display and line deletion.
//

import Foundation
import SSHConfigCore

// `KnownHostEntry` now lives in SSHConfigCore (Model/KnownHostEntry.swift).

/// What changed in `known_hosts` between two parses of it — typically the app's
/// in-memory copy versus a fresh read off disk after the live file watcher fires.
public struct KnownHostsChangeSummary: Equatable {
    public var added: [KnownHostEntry]
    public var removed: [KnownHostEntry]
    public var isEmpty: Bool { added.isEmpty && removed.isEmpty }
}

public enum KnownHostsService {
    /// Diffs two known_hosts parses by raw line text — not `KnownHostEntry.id`, which is
    /// a fresh `UUID()` per `parse()` call and so never matches across two parses of the
    /// exact same line. Counts occurrences per raw line (rather than plain set
    /// membership) so a duplicate line's addition/removal isn't masked by a surviving
    /// copy of the same text elsewhere in the file.
    public static func diff(old: [KnownHostEntry], new: [KnownHostEntry]) -> KnownHostsChangeSummary {
        var oldByRaw: [String: [KnownHostEntry]] = [:]
        for entry in old { oldByRaw[entry.raw, default: []].append(entry) }
        var newByRaw: [String: [KnownHostEntry]] = [:]
        for entry in new { newByRaw[entry.raw, default: []].append(entry) }

        var added: [KnownHostEntry] = []
        var removed: [KnownHostEntry] = []
        for raw in Set(oldByRaw.keys).union(newByRaw.keys) {
            let oldEntries = oldByRaw[raw] ?? []
            let newEntries = newByRaw[raw] ?? []
            if newEntries.count > oldEntries.count {
                added.append(contentsOf: newEntries.suffix(newEntries.count - oldEntries.count))
            } else if oldEntries.count > newEntries.count {
                removed.append(contentsOf: oldEntries.suffix(oldEntries.count - newEntries.count))
            }
        }
        return KnownHostsChangeSummary(added: added, removed: removed)
    }

    /// Parses known_hosts text into entries (skipping comments and blank lines).
    public static func parse(_ text: String) -> [KnownHostEntry] {
        let (lines, _) = SSHConfigParser.splitLines(text)
        var entries: [KnownHostEntry] = []

        for (index, line) in lines.enumerated() {
            // `.whitespacesAndNewlines`, not `.whitespaces`: a CRLF known_hosts file
            // leaves a `\r` glued to the final field, which would corrupt the key blob
            // (and so the fingerprint) of a 3-field line — every connection to that host
            // would then be refused as a fingerprint mismatch.
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }

            // Split on ANY whitespace, not just `" "`. known_hosts fields are
            // whitespace-delimited — OpenSSH's `load_host_keys` steps over spaces and
            // tabs alike — so a tab-separated line is a valid entry. Splitting on space
            // alone collapsed such a line into a single field, `fields.count >= 3` failed,
            // and the entry was dropped *silently*: the host then read as absent from
            // known_hosts, so `KnownHostsVerifier.decide` returned `.unknown` and a
            // CHANGED key was trusted on first use instead of refused as a possible MITM.
            // The same parse backs `isValidLine`, so the audit also called those lines
            // malformed and offered to delete them.
            var fields = trimmed.split(whereSeparator: \.isWhitespace).map(String.init)
            guard !fields.isEmpty else { continue }

            var marker: String?
            if fields[0].hasPrefix("@") {
                marker = fields.removeFirst()
            }
            guard fields.count >= 3 else { continue }

            let hostField = fields[0]
            let keyType = fields[1]
            let blob = fields[2]
            let isHashed = hostField.hasPrefix("|1|")

            // For `|1|<base64 salt>|<base64 hash>`, decode the two fields so the
            // verifier can recompute HMAC-SHA1(salt, host) and match the entry.
            var hashSalt: Data?
            var hashedHost: Data?
            if isHashed {
                let parts = hostField.split(separator: "|", omittingEmptySubsequences: false)
                // parts == ["", "1", "<salt>", "<hash>"]
                if parts.count == 4 {
                    hashSalt = Data(base64Encoded: String(parts[2]))
                    hashedHost = Data(base64Encoded: String(parts[3]))
                }
            }

            entries.append(
                KnownHostEntry(
                    id: UUID(),
                    lineIndex: index,
                    raw: line,
                    marker: marker,
                    hostsDisplay: isHashed ? "(hashed)" : hostField.replacingOccurrences(of: ",", with: ", "),
                    isHashed: isHashed,
                    hashSalt: hashSalt,
                    hashedHost: hashedHost,
                    keyType: keyType,
                    fingerprint: SSHKeyService.fingerprint(base64Blob: blob)
                ))
        }
        return entries
    }

    /// Whether `line` is a syntactically usable known_hosts entry (host + key type +
    /// blob, optionally a leading `@`-marker). Used to gate manual insertion.
    public static func isValidLine(_ line: String) -> Bool {
        !parse(line).isEmpty
    }

    /// Builds the known_hosts line to persist a newly-trusted (TOFU) host key —
    /// same `token key` shape `resolveHostKey`/`fetchHostKey` already write.
    /// Hashes the hostname when `hashed` is true, mirroring `HashKnownHosts yes`
    /// (ssh_config(5)): several distros default to hashed known_hosts, and writing
    /// a plaintext hostname there would silently downgrade that setting.
    public static func formatTrustLine(
        host: String, port: Int, openSSHKeyLine: String,
        hashed: Bool, salt: Data,
        hmacSHA1: KnownHostsVerifier.HMACSHA1
    ) -> String {
        guard isSafeHostToken(host) else { return "" }
        let token = port == 22 ? host : "[\(host)]:\(port)"
        guard hashed, let message = token.data(using: .utf8) else {
            return "\(token) \(openSSHKeyLine)"
        }
        let hash = hmacSHA1(salt, message)
        // No trailing `|` — `|1|<salt>|<hash>` is the full token; a fourth pipe
        // would split into 5 parts and `parse()`'s hashed-entry decoder (which
        // expects exactly `["", "1", salt, hash]`) would silently drop it back to
        // an unhashed-looking (but garbage) host field.
        let hashedToken = "|1|\(salt.base64EncodedString())|\(hash.base64EncodedString())"
        return "\(hashedToken) \(openSSHKeyLine)"
    }

    public static func isSafeHostToken(_ host: String) -> Bool {
        guard !host.isEmpty else { return false }
        for scalar in host.unicodeScalars {
            if scalar.value <= 0x20 || scalar.value == 0x7f { return false }
            if scalar.value >= 0x80 && scalar.value <= 0x9f { return false }
            if scalar == "@" || scalar == "#" { return false }
            if scalar.properties.isWhitespace { return false }
        }
        return true
    }

    /// Returns the file text with `line` appended as a new entry, normalizing
    /// surrounding newlines so the result stays one-entry-per-line.
    public static func appending(line: String, to text: String) -> String {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return text }
        var result = text
        if !result.isEmpty, !result.hasSuffix("\n") { result += "\n" }
        result += trimmed + "\n"
        return result
    }

    /// Returns the file text with the given line removed.
    public static func removing(lineIndex: Int, from text: String) -> String {
        let (lines, trailingNewline) = SSHConfigParser.splitLines(text)
        guard lines.indices.contains(lineIndex) else { return text }
        var newLines = lines
        newLines.remove(at: lineIndex)
        var result = newLines.joined(separator: "\n")
        if trailingNewline, !result.isEmpty { result += "\n" }
        return result
    }

    /// Returns the file text with `lineIndex` replaced by `newLine`, preserving all
    /// other lines and their order exactly.
    public static func replacing(lineIndex: Int, with newLine: String, in text: String) -> String {
        let (lines, trailingNewline) = SSHConfigParser.splitLines(text)
        guard lines.indices.contains(lineIndex) else { return text }
        var newLines = lines
        newLines[lineIndex] = newLine
        var result = newLines.joined(separator: "\n")
        if trailingNewline { result += "\n" }
        return result
    }

    /// Toggles the `# ` comment prefix on the line at `lineIndex`. A commented line
    /// (one starting with `#`) has its prefix stripped; a plain line gets `# ` prepended.
    public static func toggleComment(lineIndex: Int, in text: String) -> String {
        let (lines, trailingNewline) = SSHConfigParser.splitLines(text)
        guard lines.indices.contains(lineIndex) else { return text }
        var newLines = lines
        let line = lines[lineIndex]
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("#") {
            let stripped = trimmed.dropFirst()
            newLines[lineIndex] = stripped.hasPrefix(" ") ? String(stripped.dropFirst()) : String(stripped)
        } else {
            newLines[lineIndex] = "# " + line
        }
        var result = newLines.joined(separator: "\n")
        if trailingNewline { result += "\n" }
        return result
    }

    /// Returns `raw` with its leading `@`-marker replaced by `marker` (or removed for
    /// `.none`), preserving the rest of the line verbatim.
    public static func setMarker(_ marker: KnownHostMarker, on raw: String) -> String {
        var rest = raw.trimmingCharacters(in: .whitespaces)
        if rest.hasPrefix("@") {
            if let spaceRange = rest.range(of: " ") {
                rest = String(rest[spaceRange.upperBound...]).trimmingCharacters(in: .whitespaces)
            } else {
                return marker.rawValue.isEmpty ? "" : marker.rawValue
            }
        }
        return marker == .none ? rest : "\(marker.rawValue) \(rest)"
    }
}
