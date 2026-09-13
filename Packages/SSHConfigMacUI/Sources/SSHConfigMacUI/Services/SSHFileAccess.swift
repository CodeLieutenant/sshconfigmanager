//
//  SSHFileAccess.swift
//  sshconfigmanager
//
//  Sandbox-safe access to the user's ~/.ssh directory via a security-scoped bookmark.
//

import AppKit
import Darwin
import Foundation
import SSHConfigCore

/// Errors surfaced by file access.
///
/// `symlinkOutsideGrantedDirectory` covers two related cases with the same fix
/// (grant access to `target`): `source` is genuinely a symlink whose target lies
/// outside every granted root, *or* `source` is an ordinary `Include` target
/// (glob directory or literal file) that was simply never granted at all — in
/// that case `source == target`, since there's no symlink to report separately.
enum SSHFileAccessError: LocalizedError {
    case accessDenied
    case noDirectory
    case outsideGrantedDirectory(URL)
    case fileTooLarge(URL)
    case symlinkOutsideGrantedDirectory(source: URL, target: URL)

    var errorDescription: String? {
        switch self {
        case .accessDenied:
            return "Access to the .ssh folder was not granted."
        case .noDirectory:
            return "No .ssh folder has been selected yet."
        case .outsideGrantedDirectory(let url):
            return "“\(url.lastPathComponent)” is outside the folder you granted access to."
        case .fileTooLarge(let url):
            return "“\(url.lastPathComponent)” is too large to read as a text file."
        case .symlinkOutsideGrantedDirectory(let source, let target) where source == target:
            return "“\(source.lastPathComponent)” points to “\(target.path)”, which is outside "
                + "the folder(s) this app was granted access to — the sandbox can't reach it. "
                + "Grant access to that location, or move it inside ~/.ssh."
        case .symlinkOutsideGrantedDirectory(let source, let target):
            return "“\(source.lastPathComponent)” is a symlink to “\(target.path)”, which is outside "
                + "the folder(s) this app was granted access to — the sandbox can't follow it. "
                + "Grant access to that location, or move the real file inside ~/.ssh."
        }
    }
}

/// Manages sandbox access to the `~/.ssh` directory.
///
/// Because the app is sandboxed (Mac App Store), it cannot read `~/.ssh` directly.
/// The user grants access once via an open panel; we persist an app-scoped
/// security-scoped bookmark and re-establish access on each launch.
@MainActor
final class SSHFileAccess {
    private static let bookmarkKey = "sshDirectoryBookmark"
    private static let extraBookmarksKey = "sshExtraDirectoryBookmarks"
    private static let backupFolderName = ".sshmanager-backups"

    /// The granted directory, with security-scoped access currently active.
    private(set) var directoryURL: URL?

    /// Extra directories granted outside `~/.ssh`, each with its own active
    /// security-scoped bookmark — e.g. a dotfiles repo that `~/.ssh/config` (or an
    /// `Include`) symlinks into. Populated via `requestAccess(toAdditionalDirectory:)`.
    private(set) var extraDirectoryURLs: [URL] = []

    var hasAccess: Bool { directoryURL != nil }

    /// Every directory currently covered by an active security-scoped grant: the
    /// primary `~/.ssh` folder plus any extra folders granted for symlinked configs.
    private var grantedRoots: [URL] {
        (directoryURL.map { [$0] } ?? []) + extraDirectoryURLs
    }

    /// The user's *real* home directory (`/Users/<you>`).
    ///
    /// Inside the App Sandbox, `FileManager.homeDirectoryForCurrentUser` and
    /// `NSHomeDirectory()` return the **container** path
    /// (`~/Library/Containers/<bundle-id>/Data`), not `/Users/<you>`. The password
    /// database is not redirected, so `getpwuid(getuid())` still yields the real
    /// home — which is what we need to (a) pre-point open panels at the real
    /// `~/.ssh` and (b) collapse user-picked absolute paths back to `~/…` when
    /// writing IdentityFile directives. Falls back to the (container) API path on
    /// the theoretical chance the lookup fails.
    nonisolated static var realHomeDirectory: URL {
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir {
            let path = String(cString: dir)
            if !path.isEmpty { return URL(fileURLWithPath: path, isDirectory: true) }
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    /// The conventional `~/.ssh` location, used to pre-point the open panel.
    static var defaultSSHDirectory: URL {
        realHomeDirectory.appendingPathComponent(".ssh", isDirectory: true)
    }

    /// Collapses an absolute path under the real home to `~/…`. The one place the
    /// app layer binds `HomePath` to *this* machine's home; everything that writes
    /// a path into ssh_config goes through here so the file stays portable.
    nonisolated static func portablePath(_ path: String) -> String {
        HomePath.abbreviating(path, home: realHomeDirectory.path)
    }

    /// The main config file inside the granted directory, if access exists.
    var configURL: URL? {
        directoryURL?.appendingPathComponent("config", isDirectory: false)
    }

    /// The known_hosts file inside the granted directory, if access exists.
    var knownHostsURL: URL? {
        directoryURL?.appendingPathComponent("known_hosts", isDirectory: false)
    }

    /// The default location for file-backed group configs: `~/.ssh/ssh-config-manager.d/`.
    /// A group can instead point at a directory the user picked explicitly (granted
    /// via `requestAccess(toAdditionalDirectory:)`), so this is only the fallback.
    var defaultGroupsDirectory: URL? {
        directoryURL?.appendingPathComponent("ssh-config-manager.d", isDirectory: true)
    }

    // MARK: - Access lifecycle

    /// Attempts to restore access from a previously stored bookmark. Returns true on success.
    @discardableResult
    func restoreAccess() -> Bool {
        guard let data = UserDefaults.standard.data(forKey: Self.bookmarkKey) else { return false }
        var isStale = false
        do {
            let url = try URL(
                resolvingBookmarkData: data,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            guard url.startAccessingSecurityScopedResource() else { return false }
            directoryURL = url
            if isStale {
                // Refresh the bookmark so it keeps resolving in future launches.
                try? storeBookmark(for: url)
            }
            restoreExtraAccess()
            return true
        } catch {
            return false
        }
    }

    /// Restores every extra directory bookmark saved by `requestAccess(toAdditionalDirectory:)`.
    private func restoreExtraAccess() {
        guard let stored = UserDefaults.standard.array(forKey: Self.extraBookmarksKey) as? [Data] else { return }
        var refreshed: [Data] = []
        for data in stored {
            var isStale = false
            guard
                let url = try? URL(
                    resolvingBookmarkData: data, options: [.withSecurityScope],
                    relativeTo: nil, bookmarkDataIsStale: &isStale),
                url.startAccessingSecurityScopedResource()
            else { continue }
            extraDirectoryURLs.append(url)
            if isStale,
                let fresh = try? url.bookmarkData(
                    options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
            {
                refreshed.append(fresh)
            } else {
                refreshed.append(data)
            }
        }
        UserDefaults.standard.set(refreshed, forKey: Self.extraBookmarksKey)
    }

    /// Presents an open panel for the user to grant access to their `.ssh` folder.
    @discardableResult
    func requestAccess() throws -> URL {
        let panel = NSOpenPanel()
        panel.message = "Grant access to your SSH configuration folder (usually ~/.ssh)."
        panel.prompt = "Grant Access"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.directoryURL = Self.defaultSSHDirectory

        guard panel.runModal() == .OK, let url = panel.url else {
            throw SSHFileAccessError.accessDenied
        }

        try storeBookmark(for: url)
        guard url.startAccessingSecurityScopedResource() else {
            throw SSHFileAccessError.accessDenied
        }
        directoryURL = url
        Log.fileAccess.notice("granted access to \(url.path, privacy: .public)")
        return url
    }

    /// Grants access to a directory outside `~/.ssh` — used when `~/.ssh/config` (or
    /// an `Include`) is a symlink into somewhere the sandbox can't otherwise reach,
    /// e.g. a dotfiles repo. Persists its own security-scoped bookmark so the grant
    /// survives relaunch, alongside the primary `~/.ssh` one.
    @discardableResult
    func requestAccess(toAdditionalDirectory hint: URL, message: String? = nil) throws -> URL {
        let panel = NSOpenPanel()
        panel.message =
            message ?? "“\(hint.lastPathComponent)” holds a symlinked SSH config file. "
            + "Grant access so SSH Config Manager can read it."
        panel.prompt = "Grant Access"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.directoryURL = hint

        guard panel.runModal() == .OK, let url = panel.url else {
            throw SSHFileAccessError.accessDenied
        }

        let data = try url.bookmarkData(
            options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
        var stored = (UserDefaults.standard.array(forKey: Self.extraBookmarksKey) as? [Data]) ?? []
        stored.append(data)
        UserDefaults.standard.set(stored, forKey: Self.extraBookmarksKey)

        guard url.startAccessingSecurityScopedResource() else {
            throw SSHFileAccessError.accessDenied
        }
        if !extraDirectoryURLs.contains(where: { $0.standardizedFileURL.path == url.standardizedFileURL.path }) {
            extraDirectoryURLs.append(url)
        }
        Log.fileAccess.notice("granted access to additional directory \(url.path, privacy: .public)")
        return url
    }

    /// Forgets the stored grant(s) (used for "change folder" / reset).
    func revokeAccess() {
        if let url = directoryURL {
            url.stopAccessingSecurityScopedResource()
        }
        for url in extraDirectoryURLs {
            url.stopAccessingSecurityScopedResource()
        }
        directoryURL = nil
        extraDirectoryURLs = []
        UserDefaults.standard.removeObject(forKey: Self.bookmarkKey)
        UserDefaults.standard.removeObject(forKey: Self.extraBookmarksKey)
        Log.fileAccess.notice("revoked every stored ~/.ssh grant")
    }

    private func storeBookmark(for url: URL) throws {
        let data = try url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        UserDefaults.standard.set(data, forKey: Self.bookmarkKey)
    }

    // MARK: - Reading

    /// The largest text file we'll read. Any real ssh_config / known_hosts / key is
    /// far smaller; the cap just bounds memory if a huge file lands in ~/.ssh (now
    /// that key discovery reads non-`.pub` files too).
    private static let maxReadBytes = 16 * 1024 * 1024

    /// Reads a UTF-8 text file. The URL must be inside the granted directory.
    func readText(at url: URL) throws -> String {
        try ensureInsideGrantedDirectory(url)
        guard FileManager.default.fileExists(atPath: url.path) else { return "" }
        if let target = symlinkEscapeTarget(of: url) {
            throw SSHFileAccessError.symlinkOutsideGrantedDirectory(source: url, target: target)
        }
        if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
            size > Self.maxReadBytes
        {
            throw SSHFileAccessError.fileTooLarge(url)
        }
        let data = try Data(contentsOf: url)
        return String(decoding: data, as: UTF8.self)
    }

    /// Presents an open panel pre-pointed at the granted directory and returns the
    /// chosen file, but only if it lies inside the grant (the security-scoped bookmark
    /// covers the folder, so files within it are readable/writable; anything outside
    /// is rejected). Returns nil if the user cancels or picks outside the grant.
    func chooseFileInGrantedDirectory(message: String, prompt: String) -> URL? {
        guard let directoryURL else { return nil }
        let panel = NSOpenPanel()
        panel.message = message
        panel.prompt = prompt
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = directoryURL
        guard panel.runModal() == .OK, let url = panel.url,
            (try? ensureInsideGrantedDirectory(url)) != nil
        else { return nil }
        return url
    }

    /// Lists regular files directly inside the granted directory.
    func directoryFiles() throws -> [URL] {
        guard let directoryURL else { throw SSHFileAccessError.noDirectory }
        let urls = try FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        return urls.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    // MARK: - Writing

    /// Writes text atomically, optionally backing up the existing file first into a
    /// hidden backups folder. `permissions` defaults to `0600` (the right mode for
    /// config files and private keys); pass `0644` for public `.pub` keys.
    ///
    /// If `url` is a symlink (e.g. a dotfiles-managed `~/.ssh/config` pointing at
    /// `~/dotfiles/ssh/config`), this writes through it to the resolved target
    /// rather than at `url` itself. `replaceItemAt(url, withItemAt:)` with a
    /// *symlink* as the destination doesn't follow it — it swaps out whatever is
    /// at `url` wholesale, which would silently turn an intentional symlink into
    /// a plain file, or simply fail. That failure was exactly the reported "auto
    /// save doesn't work for a symlinked file" bug: the temp file got written
    /// successfully, the replace onto the symlink then threw, and — since nothing
    /// cleaned it up on failure either — every attempt left another orphaned
    /// `.<name>.tmp-<uuid>` file sitting in the directory.
    func writeText(_ text: String, to url: URL, makeBackup: Bool, permissions: Int = 0o600) throws {
        try ensureInsideGrantedDirectory(url)
        let resolved = url.resolvingSymlinksInPath()
        guard resolved.standardizedFileURL.path != url.standardizedFileURL.path else {
            try writeRegularFile(text, to: url, makeBackup: makeBackup, permissions: permissions)
            return
        }
        // It's a symlink. Only follow it if the real target is somewhere this app
        // can actually write — otherwise this is the same escape `readText` guards
        // against, just on the write path.
        guard (try? ensureInsideGrantedDirectory(resolved)) != nil else {
            Log.fileAccess.error(
                "refusing to write through symlink \(url.path, privacy: .public) → \(resolved.path, privacy: .public) (outside every grant)"
            )
            throw SSHFileAccessError.symlinkOutsideGrantedDirectory(source: url, target: resolved)
        }
        Log.fileAccess.info(
            "writing through symlink \(url.path, privacy: .public) → \(resolved.path, privacy: .public)")
        try writeRegularFile(text, to: resolved, makeBackup: makeBackup, permissions: permissions)
    }

    /// The actual atomic write: temp file in the same directory, then
    /// replace/move into place. `url` must not itself be a symlink — `writeText`
    /// resolves through one before calling this.
    private func writeRegularFile(_ text: String, to url: URL, makeBackup: Bool, permissions: Int) throws {
        let fileManager = FileManager.default
        let directory = url.deletingLastPathComponent()

        if makeBackup, fileManager.fileExists(atPath: url.path) {
            try backUp(url, fileManager: fileManager)
        }

        let tempURL = directory.appendingPathComponent(
            "." + url.lastPathComponent + ".tmp-" + UUID().uuidString
        )
        let data = Data(text.utf8)
        try data.write(to: tempURL, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: permissions], ofItemAtPath: tempURL.path)
        // `.atomic` above only guarantees `tempURL` itself isn't left half-written
        // if *that* write is interrupted — it doesn't flush anything to the drive.
        // Without this, a power loss right after `writeText` returns could still
        // lose the just-"saved" config (audit #6): the bytes were still sitting in
        // a write-back cache, not on stable storage, when the machine died.
        // `F_FULLFSYNC` (not a bare `fsync()`) is what actually flushes the
        // drive's own write cache on macOS.
        Self.fullFsync(tempURL)

        do {
            if fileManager.fileExists(atPath: url.path) {
                _ = try fileManager.replaceItemAt(url, withItemAt: tempURL)
            } else {
                try fileManager.moveItem(at: tempURL, to: url)
            }
        } catch {
            // Don't leave `.tmp-*` debris behind on a failed replace/move — this is
            // exactly what accumulated (silently, indefinitely) before this fix.
            try? fileManager.removeItem(at: tempURL)
            throw error
        }
        try? fileManager.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path)
        // Flush the *directory* too, so the rename that publishes the new content
        // under `url`'s name is itself durable, not just the content.
        Self.fullFsync(directory)
    }

    /// Best-effort `F_FULLFSYNC` on whatever's at `url` (file or directory) — see
    /// the call sites in `writeRegularFile` (audit #6). Silently does nothing on
    /// a filesystem that doesn't support it (e.g. some network volumes return
    /// `ENOTSUP`); the write itself already reached the OS's normal buffered
    /// path either way; this only strengthens the durability guarantee, it isn't
    /// required for the write to have "worked."
    private static func fullFsync(_ url: URL) {
        let fd = open(url.path, O_RDONLY)
        guard fd >= 0 else { return }
        defer { close(fd) }
        _ = fcntl(fd, F_FULLFSYNC)
    }

    private func backUp(_ url: URL, fileManager: FileManager) throws {
        guard let directoryURL else { return }
        let backupDir = directoryURL.appendingPathComponent(Self.backupFolderName, isDirectory: true)
        if !fileManager.fileExists(atPath: backupDir.path) {
            try fileManager.createDirectory(at: backupDir, withIntermediateDirectories: true)
        }
        let stamp = Self.timestampFormatter.string(from: Date())
        let backupURL = backupDir.appendingPathComponent("\(url.lastPathComponent).\(stamp).bak")
        try? fileManager.removeItem(at: backupURL)
        try fileManager.copyItem(at: url, to: backupURL)
        Log.fileAccess.info(
            "backed up \(url.lastPathComponent, privacy: .public) → \(backupURL.lastPathComponent, privacy: .public)")
    }

    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }()

    // MARK: - Permissions

    /// The POSIX permission bits of a file/dir inside the granted directory (e.g.
    /// `0o600`). Throws if the URL is outside the grant; the caller treats a thrown
    /// error (e.g. missing file) as "unknown".
    func permissions(of url: URL) throws -> Int {
        try ensureInsideGrantedDirectory(url)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0
    }

    /// chmods a file/dir inside the granted directory. Used by the key audit's
    /// one-click permission fixes; the grant check keeps it from touching anything
    /// outside `~/.ssh`.
    func setPermissions(_ mode: Int, on url: URL) throws {
        Log.fileAccess.notice(
            "chmod \(String(mode, radix: 8), privacy: .public) \(url.lastPathComponent, privacy: .public)")
        try ensureInsideGrantedDirectory(url)
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
    }

    // MARK: - Deletion

    /// Deletes a file inside the granted directory, optionally backing it up first
    /// into the hidden backups folder (so an orphaned-key delete is recoverable).
    /// A missing file is a no-op.
    func deleteFile(at url: URL, makeBackup: Bool) throws {
        try ensureInsideGrantedDirectory(url)
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: url.path) else { return }
        if makeBackup { try backUp(url, fileManager: fileManager) }
        try fileManager.removeItem(at: url)
        Log.fileAccess.notice("deleted \(url.path, privacy: .public) (backup: \(makeBackup, privacy: .public))")
    }

    /// Creates `url` (and any missing intermediate directories) if it doesn't
    /// already exist. Used before writing a new file-backed group's `.conf` file
    /// into `~/.ssh/ssh-config-manager.d/` (or a user-chosen custom directory).
    /// A leftover empty directory after undoing the group that created it is
    /// harmless clutter, so this is intentionally not paired with any cleanup.
    func ensureDirectoryExists(at url: URL) throws {
        try ensureInsideGrantedDirectory(url)
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        if exists, isDirectory.boolValue { return }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        Log.fileAccess.notice("created directory \(url.path, privacy: .public)")
    }

    // MARK: - Backups

    /// A saved backup of a config file.
    struct BackupInfo: Identifiable, Equatable {
        let id = UUID()
        let url: URL
        let originalName: String
        let date: Date
        static func == (lhs: BackupInfo, rhs: BackupInfo) -> Bool { lhs.url == rhs.url }
    }

    /// Lists backups for a given file name (e.g. "config"), newest first.
    func backups(forFileNamed fileName: String) -> [BackupInfo] {
        guard let directoryURL else { return [] }
        let backupDir = directoryURL.appendingPathComponent(Self.backupFolderName, isDirectory: true)
        guard
            let entries = try? FileManager.default.contentsOfDirectory(
                at: backupDir, includingPropertiesForKeys: nil)
        else { return [] }
        let prefix = fileName + "."
        return entries.compactMap { url -> BackupInfo? in
            let name = url.lastPathComponent
            guard name.hasPrefix(prefix), name.hasSuffix(".bak") else { return nil }
            let stamp = String(name.dropFirst(prefix.count).dropLast(4)) // strip ".bak"
            guard let date = Self.timestampFormatter.date(from: stamp) else { return nil }
            return BackupInfo(url: url, originalName: fileName, date: date)
        }
        .sorted { $0.date > $1.date }
    }

    /// Reads a backup's text (backups live inside the granted directory).
    func readBackup(_ info: BackupInfo) throws -> String {
        try readText(at: info.url)
    }

    // MARK: - Include resolution

    /// Resolves an `Include` pattern (which may contain globs and multiple tokens)
    /// to concrete files inside the granted directory. Tokens outside the granted
    /// directory are skipped. `onSymlinkEscape` is called for a glob whose directory
    /// (e.g. `conf.d` in `Include ~/.ssh/conf.d/*`) is itself a symlink resolving
    /// outside every granted root — without it, that whole directory's hosts would
    /// silently vanish from the config with no indication why.
    func resolveIncludes(
        _ patternList: String,
        onSymlinkEscape: (_ source: URL, _ target: URL) -> Void = { _, _ in }
    ) -> [URL] {
        guard let directoryURL else { return [] }
        // NSHomeDirectory() / expandingTildeInPath returns the sandbox *container*
        // path in a sandboxed app, not the real home. Use the password-database home
        // so that `Include ~/.ssh/config.d/*` resolves to the actual ~/.ssh directory.
        let realHome = SSHFileAccess.realHomeDirectory.path
        var results: [URL] = []
        for token in tokenize(patternList) {
            let expanded: String
            if token.hasPrefix("~/") {
                expanded = realHome + String(token.dropFirst(1))
            } else if token == "~" {
                expanded = realHome
            } else {
                expanded = token
            }
            let baseURL: URL
            if expanded.hasPrefix("/") {
                baseURL = URL(fileURLWithPath: expanded)
            } else {
                baseURL = directoryURL.appendingPathComponent(expanded)
            }
            for url in matchGlob(baseURL, onSymlinkEscape: onSymlinkEscape)
            where (try? ensureInsideGrantedDirectory(url)) != nil {
                results.append(url.standardizedFileURL)
            }
        }
        return results
    }

    /// Splits an include value into tokens, honoring double quotes.
    ///
    /// `\r` and `\n` are treated as unquoted whitespace separators, mirroring real ssh
    /// (which treats them as trailing whitespace). The parser deliberately keeps a
    /// directive's trailing `\r` in its stored value for byte-exact round-tripping (audit
    /// #27), so a CRLF `~/.ssh/config` hands us `config.d/*\r`. Without stripping it, the
    /// glob `config.d/*\r` matches no file and every host in every included file silently
    /// vanishes from the UI. (Audit CFG-2.)
    private func tokenize(_ value: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var inQuotes = false
        for character in value {
            if character == "\"" {
                inQuotes.toggle()
            } else if character == " " || character == "\t" || character == "\r" || character == "\n", !inQuotes {
                if !current.isEmpty {
                    tokens.append(current)
                    current = ""
                }
            } else {
                current.append(character)
            }
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens
    }

    /// Expands a single path that may contain `*`/`?` in its final component.
    ///
    /// Any candidate path this resolves to that lies outside every granted root
    /// gets reported via `onSymlinkEscape` before being dropped — not just the ones
    /// that get there via a symlink. Plenty of real `Include`s point somewhere
    /// perfectly ordinary that just was never granted (e.g. `Include
    /// ~/dotfiles/ssh/*.conf`, no symlink involved) — treating only the symlink
    /// case as recoverable meant every *other* out-of-grant Include's hosts simply
    /// vanished from the config with no indication why and no way to fix it.
    private func matchGlob(_ url: URL, onSymlinkEscape: (_ source: URL, _ target: URL) -> Void) -> [URL] {
        let fileManager = FileManager.default
        let name = url.lastPathComponent
        if !name.contains("*") && !name.contains("?") {
            // Non-glob: a literal file. Check the grant *before* touching the
            // filesystem — under the sandbox, `fileExists`/`resourceValues` on an
            // ungranted path typically read as "doesn't exist" rather than
            // "permission denied", so checking existence first would silently
            // swallow this exactly like the directory case below used to.
            guard (try? ensureInsideGrantedDirectory(url)) != nil else {
                onSymlinkEscape(url, symlinkEscapeTarget(of: url) ?? url)
                return []
            }
            // A symlink whose target escapes every granted root must surface the
            // grant flow, not vanish: under the sandbox `fileExists` on it reads
            // as "doesn't exist", so the plain existence check below would
            // silently drop it just like the glob case used to.
            if let target = symlinkEscapeTarget(of: url) {
                onSymlinkEscape(url, target)
                return []
            }
            return isIncludableRegularFile(url) ? [url] : []
        }
        let directory = url.deletingLastPathComponent()
        // A glob whose directory lies outside every granted root (e.g. `Include
        // /etc/*` or `Include ~/dotfiles/ssh/*.conf`) — report it instead of the
        // silent drop this used to be; see the doc comment above.
        guard (try? ensureInsideGrantedDirectory(directory)) != nil else {
            onSymlinkEscape(directory, symlinkEscapeTarget(of: directory) ?? directory)
            return []
        }
        // The directory itself (e.g. `conf.d`) can be a symlink into a dotfiles repo
        // the sandbox has no bookmark for — its unresolved path lives inside the
        // granted directory (passing the check above), but enumerating it fails.
        // Report the real target instead of letting `contentsOfDirectory` fail
        // silently, so the caller can offer to grant access to it.
        if let target = symlinkEscapeTarget(of: directory) {
            onSymlinkEscape(directory, target)
            return []
        }
        // `contentsOfDirectory(at: URL, ...)` fails with ENOTDIR when `directory` is
        // itself a symlink (even to a granted target) — the path-string API doesn't
        // have that limitation, since it follows the symlink like any other POSIX
        // directory traversal. Without this, a granted symlinked directory would
        // still silently resolve to zero files after "Grant Access" supposedly fixed it.
        guard let names = try? fileManager.contentsOfDirectory(atPath: directory.path) else { return [] }
        let entries = names.map { directory.appendingPathComponent($0) }
        return
            entries
            // FNM_PERIOD matches OpenSSH's glob(3) default: `*` does not match a
            // leading `.`, so hidden files like `.DS_Store` are correctly skipped.
            .filter { fnmatch(name, $0.lastPathComponent, FNM_PERIOD) == 0 }
            // Skip directories, symlinks to directories, and other non-regular
            // files — but a matched entry that is itself a symlink escaping every
            // granted root (e.g. `config.d/work.conf → ~/dotfiles/…`) gets
            // reported so the caller can offer to grant access, exactly like a
            // symlinked directory above. Its resolved target can't be stat'ed
            // under the sandbox, so without this it read as "not a regular file"
            // and the whole entry silently vanished from the UI.
            .filter { entry in
                if let target = symlinkEscapeTarget(of: entry) {
                    onSymlinkEscape(entry, target)
                    return false
                }
                return isIncludableRegularFile(entry)
            }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Whether an `Include` candidate is a regular file, following a symlink to
    /// its (in-grant) target. `isRegularFileKey` alone is `false` for a symlink
    /// even when it points at a perfectly readable regular file — filtering on
    /// it dropped every dotfiles-managed symlink from glob and literal Includes
    /// with no indication why. Directories, symlinks to directories, and broken
    /// symlinks stay excluded. Callers must handle out-of-grant symlink targets
    /// first (see `symlinkEscapeTarget`) — those can't be stat'ed here.
    private func isIncludableRegularFile(_ url: URL) -> Bool {
        let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        if values?.isRegularFile == true { return true }
        guard values?.isSymbolicLink == true else { return false }
        return
            (try? url.resolvingSymlinksInPath()
            .resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
    }

    // MARK: - Validation

    @discardableResult
    private func ensureInsideGrantedDirectory(_ url: URL) throws -> URL {
        guard directoryURL != nil else { throw SSHFileAccessError.noDirectory }
        let target = url.standardizedFileURL.path
        let isInside = grantedRoots.contains { root in
            let base = root.standardizedFileURL.path
            return target == base || target.hasPrefix(base + "/")
        }
        guard isInside else { throw SSHFileAccessError.outsideGrantedDirectory(url) }
        return url
    }

    /// If `url` is (or passes through) a symlink whose fully resolved target lies
    /// outside every granted root, returns that target. Sandboxed content reads on
    /// such a target are denied even though metadata calls (`fileExists`,
    /// `resourceValues`) on the symlink itself succeed — without this check, a
    /// read/write attempt fails deep inside Foundation with a confusing "file
    /// doesn't exist" error instead of one that names the actual target and lets
    /// the caller offer to grant access to it.
    private func symlinkEscapeTarget(of url: URL) -> URL? {
        let resolved = url.resolvingSymlinksInPath()
        guard resolved.standardizedFileURL.path != url.standardizedFileURL.path else { return nil }
        guard (try? ensureInsideGrantedDirectory(resolved)) == nil else { return nil }
        return resolved
    }

    #if DEBUG
        /// Test seam: point at a plain directory, bypassing the security-scoped bookmark.
        func useDirectoryForTesting(_ url: URL) { directoryURL = url }
        /// Test seam: grant an extra root, bypassing the `requestAccess(toAdditionalDirectory:)` panel.
        func useAdditionalDirectoryForTesting(_ url: URL) { extraDirectoryURLs.append(url) }
    #endif
}

extension SSHPublicKey {
    /// The key's `IdentityFile` value, `~`-relative against the real (non-container)
    /// home. Every UI and config-writing call site uses this rather than passing a
    /// home around; see `SSHFileAccess.realHomeDirectory` for why the sandbox makes
    /// the obvious `FileManager` answer wrong.
    nonisolated var identityFilePath: String {
        #if DEBUG
            if let presented = ScreenshotMode.presentedIdentityFilePath(for: self) { return presented }
        #endif
        return identityFilePath(relativeTo: SSHFileAccess.realHomeDirectory.path)
    }
}
