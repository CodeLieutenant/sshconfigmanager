//
//  PathCompletionBrowser.swift
//  sshconfigmanager
//
//  The macOS adapter that lets the pure IntelliSense engine offer file-path
//  completions for IdentityFile / CertificateFile / … without itself doing I/O.
//
//  It's a plain `Sendable` value — just two path strings — so the (non-isolated)
//  engine can call it from wherever it runs. The directory read is allowed because
//  `SSHFileAccess` keeps the granted `~/.ssh` security scope active for the whole
//  session; once that scope is open, any thread may read inside it. Listing is
//  confined to the grant (mirroring `SSHFileAccess.ensureInsideGrantedDirectory`):
//  anything outside resolves to nothing rather than leaking a directory listing.
//

import Foundation
import SSHConfigIntelliSense

public struct PathCompletionBrowser: FileSystemBrowsing {
    public let homeDirectoryPath: String
    public let baseDirectoryPath: String?

    public init(homeDirectoryPath: String, baseDirectoryPath: String?) {
        self.homeDirectoryPath = homeDirectoryPath
        self.baseDirectoryPath = baseDirectoryPath
    }

    public func listDirectory(_ absolutePath: String) -> [FileEntry] {
        guard let base = baseDirectoryPath,
            PathCompletion.isInside(absolutePath, base: base)
        else { return [] }

        let fileManager = FileManager.default
        guard let names = try? fileManager.contentsOfDirectory(atPath: absolutePath) else { return [] }

        return names.map { name in
            var isDirectory: ObjCBool = false
            let full = (absolutePath as NSString).appendingPathComponent(name)
            fileManager.fileExists(atPath: full, isDirectory: &isDirectory)
            return FileEntry(name: name, isDirectory: isDirectory.boolValue)
        }
    }
}
