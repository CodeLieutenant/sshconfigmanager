import Foundation
import SSHConfigCore

/// A copy of a config file as it was before one save.
public struct ConfigSnapshot: Identifiable, Equatable {
    public let id: String
    public let takenAt: Date
    public let originalPath: String
    public let snapshotPath: String
    public let byteCount: Int
    public var name: String?

    public var fileName: String { URL(fileURLWithPath: originalPath).lastPathComponent }
}

/// Keeps a copy of every config file the app is about to overwrite.
///
/// The macOS build keeps its version history in SQLite. That store is in the
/// macOS package, not in the shared core, so Linux keeps plain files under the
/// XDG data directory instead. The file is the record — no database to corrupt,
/// and a user can read a snapshot with `cat`.
public enum HistoryStore {
    public static let limit = 50

    public static var directory: String {
        let base =
            ProcessInfo.processInfo.environment["XDG_DATA_HOME"]
            ?? "\(SSHDirectory.home)/.local/share"
        return "\(base)/sshmanager/history"
    }

    /// Copies `path` into the history directory. Called before a write, so a
    /// failure here must not stop the save — the user's edit matters more than
    /// the backup.
    @discardableResult
    public static func snapshot(path: String, name: String = "") -> ConfigSnapshot? {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        try? FileManager.default.createDirectory(
            atPath: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let stamp = Int(Date().timeIntervalSince1970 * 1000)
        let name = URL(fileURLWithPath: path).lastPathComponent
        let snapshotPath = "\(directory)/\(stamp)-\(name)"
        guard (try? text.write(toFile: snapshotPath, atomically: true, encoding: .utf8)) != nil
        else { return nil }
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: snapshotPath
        )
        writeOriginPath(path, for: snapshotPath)
        if !name.isEmpty {
            try? name.write(toFile: "\(snapshotPath).name", atomically: true, encoding: .utf8)
        }
        prune()
        return ConfigSnapshot(
            id: snapshotPath,
            takenAt: Date(timeIntervalSince1970: Double(stamp) / 1000),
            originalPath: path,
            snapshotPath: snapshotPath,
            byteCount: text.utf8.count,
            name: name.isEmpty ? nil : name
        )
    }

    public static func all() -> [ConfigSnapshot] {
        let names =
            (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []
        return
            names
            .filter { !$0.hasSuffix(".origin") && !$0.hasSuffix(".name") }
            .compactMap { name -> ConfigSnapshot? in
                let path = "\(directory)/\(name)"
                guard let stamp = Int(name.prefix(while: { $0.isNumber })), stamp > 0 else {
                    return nil
                }
                let attributes = try? FileManager.default.attributesOfItem(atPath: path)
                return ConfigSnapshot(
                    id: path,
                    takenAt: Date(timeIntervalSince1970: Double(stamp) / 1000),
                    originalPath: originPath(for: path) ?? ConfigStore.configPath,
                    snapshotPath: path,
                    byteCount: (attributes?[.size] as? NSNumber)?.intValue ?? 0,
                    name: try? String(contentsOfFile: "\(path).name", encoding: .utf8)
                )
            }
            .sorted { $0.takenAt > $1.takenAt }
    }

    public static func text(of snapshot: ConfigSnapshot) -> String {
        (try? String(contentsOfFile: snapshot.snapshotPath, encoding: .utf8)) ?? ""
    }

    /// Puts a snapshot back. The current file is snapshotted first, so a restore
    /// is itself undoable.
    public static func restore(_ snapshot: ConfigSnapshot) throws {
        let text = try String(contentsOfFile: snapshot.snapshotPath, encoding: .utf8)
        self.snapshot(path: snapshot.originalPath)
        try text.write(toFile: snapshot.originalPath, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: snapshot.originalPath
        )
    }

    /// The diff against the file as it stands now.
    public static func diff(_ snapshot: ConfigSnapshot) -> [TextDiff.Line] {
        let current = (try? String(contentsOfFile: snapshot.originalPath, encoding: .utf8)) ?? ""
        return TextDiff.diff(old: text(of: snapshot), new: current)
    }

    public static func name(of snapshot: ConfigSnapshot) -> String? {
        try? String(contentsOfFile: "\(snapshot.snapshotPath).name", encoding: .utf8)
    }

    public static func setName(_ name: String, for snapshot: ConfigSnapshot) {
        let path = "\(snapshot.snapshotPath).name"
        if name.isEmpty {
            try? FileManager.default.removeItem(atPath: path)
        } else {
            try? name.write(toFile: path, atomically: true, encoding: .utf8)
        }
    }

    /// Deletes every kept version. The current configuration is untouched.
    public static func clear() {
        for snapshot in all() {
            try? FileManager.default.removeItem(atPath: snapshot.snapshotPath)
            try? FileManager.default.removeItem(atPath: "\(snapshot.snapshotPath).origin")
            try? FileManager.default.removeItem(atPath: "\(snapshot.snapshotPath).name")
        }
    }

    private static func prune() {
        let snapshots = all()
        guard snapshots.count > limit else { return }
        for snapshot in snapshots.dropFirst(limit) {
            try? FileManager.default.removeItem(atPath: snapshot.snapshotPath)
            try? FileManager.default.removeItem(atPath: "\(snapshot.snapshotPath).origin")
        }
    }

    // A snapshot of an included file has to remember which file it came from, and
    // the name alone cannot carry a path.
    private static func writeOriginPath(_ path: String, for snapshotPath: String) {
        try? path.write(toFile: "\(snapshotPath).origin", atomically: true, encoding: .utf8)
    }

    private static func originPath(for snapshotPath: String) -> String? {
        try? String(contentsOfFile: "\(snapshotPath).origin", encoding: .utf8)
    }
}
