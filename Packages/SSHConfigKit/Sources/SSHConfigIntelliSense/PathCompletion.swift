//
//  PathCompletion.swift
//  SSHConfigIntelliSense
//
//  File-path completion for the path-typed keywords (IdentityFile, CertificateFile,
//  UserKnownHostsFile, ControlPath, …). The engine itself stays pure and I/O-free so
//  it remains reusable from a CLI or a Linux UI; the actual directory listing enters
//  through an injected `FileSystemBrowsing` provider. Everything *else* — splitting a
//  half-typed value into "directory so far" + "name fragment", expanding `~`,
//  resolving a relative path against the granted root, and confining the lookup to
//  that root — is pure string work and lives here so it can be unit-tested without a
//  filesystem.
//
//  The sandbox reality (Mac App Store) shapes the contract: the app may only read the
//  user-granted `~/.ssh` (a live security-scoped bookmark). So relative values resolve
//  against that grant and any path that escapes it completes to nothing rather than
//  leaking a directory listing.
//

import Foundation
import SSHConfigCore

/// One filesystem entry surfaced to path completion.
public struct FileEntry: Equatable, Sendable {
    public let name: String
    public let isDirectory: Bool

    public init(name: String, isDirectory: Bool) {
        self.name = name
        self.isDirectory = isDirectory
    }
}

/// A sandbox-safe, synchronous directory lister injected into the engine. Keeping the
/// seam `Sendable` (and its methods non-isolated) lets the engine stay actor-agnostic;
/// the macOS adapter is a plain value holding two path strings, so it carries no
/// isolation of its own. Implementations confine reads to a granted root.
public protocol FileSystemBrowsing: Sendable {
    /// The user's real home directory path, for `~` expansion (e.g. "/Users/me").
    var homeDirectoryPath: String { get }
    /// The root that relative values resolve against and that all listing is confined
    /// to (the granted `~/.ssh`). `nil` when no folder has been granted yet.
    var baseDirectoryPath: String? { get }
    /// Lists a directory by absolute path. Returns `[]` for anything the implementation
    /// can't or won't read (missing, outside the grant, or an error).
    func listDirectory(_ absolutePath: String) -> [FileEntry]
}

/// Pure helpers + the single entry point `complete(value:fileSystem:)` the engine calls.
public enum PathCompletion {
    /// What the engine needs to splice a path completion: how much of the typed value
    /// stays on the line, the fragment to match against, and the offerable entries.
    public struct Result: Equatable, Sendable {
        /// UTF-16 length of the directory portion that must remain untouched (the part
        /// before and including the last "/"). The accept replaces only what follows.
        public let consumedUTF16: Int
        /// The fragment after the last "/", matched against entry names.
        public let namePrefix: String
        /// Candidate entries for the resolved directory (dotfiles filtered per prefix,
        /// directories first, alpha within each). Empty when the value escapes the grant.
        public let candidates: [ValueCandidate]

        public init(consumedUTF16: Int, namePrefix: String, candidates: [ValueCandidate]) {
            self.consumedUTF16 = consumedUTF16
            self.namePrefix = namePrefix
            self.candidates = candidates
        }
    }

    /// Compute path completions for a half-typed value. Returns `nil` when path
    /// completion can't apply at all (no granted base, or a relative value with no base
    /// to resolve against), so the caller offers nothing for the segment.
    public static func complete(value: String, fileSystem: FileSystemBrowsing) -> Result? {
        guard let base = fileSystem.baseDirectoryPath else { return nil }
        let (directory, namePrefix) = split(value)
        let consumed = directory.utf16.count

        guard
            let absDir = resolveDirectory(
                directory,
                home: fileSystem.homeDirectoryPath,
                base: base)
        else { return nil }

        // Refuse to list outside the grant — return an *empty* result (not nil) so the
        // segment is recognised as a path but simply yields nothing.
        guard isInside(absDir, base: base) else {
            return Result(consumedUTF16: consumed, namePrefix: namePrefix, candidates: [])
        }

        // Hidden entries appear only once the user commits to a leading dot.
        let showHidden = namePrefix.hasPrefix(".")
        let entries = fileSystem.listDirectory(absDir)
            .filter { $0.name != "." && $0.name != ".." }
            .filter { showHidden || !$0.name.hasPrefix(".") }

        // Directories first, then files; alpha within each. (The engine's fuzzy rank
        // reorders on a non-empty prefix; this is the empty-prefix presentation order.)
        let sorted = entries.sorted {
            $0.isDirectory != $1.isDirectory
                ? $0.isDirectory
                : $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }

        let candidates = sorted.map { entry -> ValueCandidate in
            entry.isDirectory
                ? ValueCandidate(value: entry.name + "/", detail: "folder", kind: .folder)
                : ValueCandidate(value: entry.name, detail: "file", kind: .file)
        }

        return Result(consumedUTF16: consumed, namePrefix: namePrefix, candidates: candidates)
    }

    // MARK: - Pure string helpers (unit-tested directly)

    /// Split a path value into the directory part (everything up to and including the
    /// last "/") and the trailing name fragment being completed. No slash → ("", value).
    public static func split(_ value: String) -> (directory: String, namePrefix: String) {
        guard let slash = value.lastIndex(of: "/") else { return ("", value) }
        let directory = String(value[...slash])
        let namePrefix = String(value[value.index(after: slash)...])
        return (directory, namePrefix)
    }

    /// Resolve a directory portion to an absolute path: expand a leading `~` against
    /// `home`, pass through an absolute path, resolve a relative one against `base`.
    /// An empty directory portion resolves to `base` itself. `nil` only when a relative
    /// path is given but there is no base.
    public static func resolveDirectory(_ directory: String, home: String, base: String?) -> String? {
        if directory.isEmpty { return base }
        if directory == "~" || directory.hasPrefix("~/") {
            return home + directory.dropFirst() // drop "~", keep the leading "/"
        }
        if directory.hasPrefix("/") { return directory }
        guard let base else { return nil }
        return base + "/" + directory
    }

    /// Lexically normalize an absolute or relative path: collapse repeated slashes,
    /// resolve `.` / `..`, and drop a trailing slash (except root). No filesystem
    /// access — symlinks are NOT resolved; the provider does the authoritative check.
    public static func normalize(_ path: String) -> String {
        let isAbsolute = path.hasPrefix("/")
        var stack: [String] = []
        for component in path.split(separator: "/", omittingEmptySubsequences: true) {
            switch component {
            case ".":
                continue
            case "..":
                if let last = stack.last, last != ".." {
                    stack.removeLast()
                } else if !isAbsolute {
                    stack.append("..")
                }
            default:
                stack.append(String(component))
            }
        }
        let joined = stack.joined(separator: "/")
        return isAbsolute ? "/" + joined : joined
    }

    /// Whether `path` is `base` itself or lies within it (lexical confinement check,
    /// mirroring `SSHFileAccess.ensureInsideGrantedDirectory`).
    public static func isInside(_ path: String, base: String) -> Bool {
        let p = normalize(path)
        let b = normalize(base)
        return p == b || p.hasPrefix(b + "/")
    }
}
