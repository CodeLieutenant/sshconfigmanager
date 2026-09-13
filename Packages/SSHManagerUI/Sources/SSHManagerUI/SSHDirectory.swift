import Foundation

/// Resolves and checks the SSH directory. This is the Linux half of the
/// `SSHFileAccess` seam (linux-port.md §4.2): there is no sandbox and no
/// security-scoped bookmark, so a grant reduces to "does the path exist, and can
/// this user read and write it".
public enum SSHDirectory {
    public enum State: Equatable, Sendable {
        case ready(path: String)
        case missing(path: String)
        case unreadable(path: String)
    }

    /// getpwuid rather than NSHomeDirectory, which honours $HOME and so reports the
    /// wrong directory under sudo and inside a service manager's environment.
    public static var home: String {
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir {
            return String(cString: dir)
        }
        return NSHomeDirectory()
    }

    public static var defaultPath: String { "\(home)/.ssh" }

    public static func inspect(path: String = defaultPath) -> State {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
            isDirectory.boolValue
        else {
            return .missing(path: path)
        }
        guard FileManager.default.isReadableFile(atPath: path),
            FileManager.default.isWritableFile(atPath: path)
        else {
            return .unreadable(path: path)
        }
        return .ready(path: path)
    }

    /// Creates the directory with the permissions OpenSSH insists on. ssh refuses
    /// to use a config directory that is group or world accessible.
    public static func create(path: String = defaultPath) throws {
        try FileManager.default.createDirectory(
            atPath: path,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
    }
}
