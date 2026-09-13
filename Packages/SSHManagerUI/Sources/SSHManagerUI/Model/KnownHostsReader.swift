import Foundation
import SSHConfigCore
import SSHConfigServices

/// A known_hosts entry with whatever the audit says about it.
public struct KnownHostRow: Identifiable, Equatable {
    public let entry: KnownHostEntry
    public let finding: KnownHostsAudit.Finding?

    public var id: UUID { entry.id }
    public var host: String { entry.hostsDisplay }
    public var keyType: String { entry.keyType }
    public var fingerprint: String { entry.fingerprint ?? "" }
    public var marker: KnownHostMarker { entry.resolvedMarker }

    public var findingLabel: String? {
        switch finding {
        case .malformed: "Malformed line"
        case .duplicate: "Duplicate"
        case .orphan: "No host uses this"
        case nil: nil
        }
    }
}

public enum KnownHostsReader {
    public static var path: String { "\(SSHDirectory.defaultPath)/known_hosts" }

    public static func load(configuredNames: Set<String> = []) -> [KnownHostRow] {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
        let entries = KnownHostsService.parse(text)
        let findings = KnownHostsAudit.staticFindings(entries, knownNames: configuredNames)
        return entries.map { KnownHostRow(entry: $0, finding: findings[$0.id]) }
    }

    /// Groups entries the way the Known Hosts screen lists them: one row per host,
    /// however many keys that host has.
    public static func groups(_ rows: [KnownHostRow], configAliasesByHost: [String: [String]] = [:])
        -> [KnownHostGroup]
    {
        KnownHostGroup.build(
            from: rows.map(\.entry),
            configAliasesByHost: configAliasesByHost
        )
    }

    /// Removes one line and rewrites the file. Line indices come from the parse,
    /// so the caller must reload afterwards rather than reuse the old rows.
    public static func remove(lineIndex: Int) throws {
        let text = try String(contentsOfFile: path, encoding: .utf8)
        let updated = KnownHostsService.removing(lineIndex: lineIndex, from: text)
        try write(updated)
    }

    public static func setMarker(_ marker: KnownHostMarker, lineIndex: Int) throws {
        let text = try String(contentsOfFile: path, encoding: .utf8)
        let lines = text.components(separatedBy: "\n")
        guard lines.indices.contains(lineIndex) else { return }
        let updated = KnownHostsService.replacing(
            lineIndex: lineIndex,
            with: KnownHostsService.setMarker(marker, on: lines[lineIndex]),
            in: text
        )
        try write(updated)
    }

    /// Appends a line, creating the file if it is missing.
    public static func append(line: String) throws {
        let existing = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        try write(KnownHostsService.appending(line: line, to: existing))
    }

    private static func write(_ text: String) throws {
        try text.write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
    }
}
