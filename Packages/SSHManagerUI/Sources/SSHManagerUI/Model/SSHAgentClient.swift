import Foundation
import SSHConfigCore

#if canImport(Glibc)
    import Glibc
#endif

/// Talks to a running ssh-agent over its UNIX socket.
///
/// `SSHAgentProtocol` in Core builds and reads the messages but deliberately owns
/// no socket, and the macOS package keeps its socket half internal, so the
/// transport is written here. It is blocking and synchronous, which matches the
/// rest of the services layer. Calls are small and local, so they finish inside a
/// GTK main-loop turn.
public enum SSHAgentClient {
    public static var socketPath: String? {
        ProcessInfo.processInfo.environment["SSH_AUTH_SOCK"]
    }

    public static var isAvailable: Bool {
        guard let socketPath else { return false }
        return FileManager.default.fileExists(atPath: socketPath)
    }

    public static func listIdentities() throws -> [AgentIdentity] {
        let payload = try roundTrip(SSHAgentProtocol.requestIdentitiesMessage())
        return try SSHAgentProtocol.parseIdentities(payload)
    }

    public static func removeIdentity(keyBlob: [UInt8]) throws {
        let payload = try roundTrip(SSHAgentProtocol.removeIdentityMessage(keyBlob: keyBlob))
        try SSHAgentProtocol.parseStatus(payload)
    }

    public static func removeAll() throws {
        let payload = try roundTrip(SSHAgentProtocol.removeAllIdentitiesMessage())
        try SSHAgentProtocol.parseStatus(payload)
    }

    public static func addIdentity(body: [UInt8]) throws {
        let payload = try roundTrip(SSHAgentProtocol.addIdentityMessage(body: body))
        try SSHAgentProtocol.parseStatus(payload)
    }

    // MARK: - Transport

    private static func roundTrip(_ message: [UInt8]) throws -> [UInt8] {
        guard let socketPath else { throw SSHAgentError.socketUnavailable }
        let descriptor = try connect(to: socketPath)
        defer { close(descriptor) }
        try writeAll(descriptor, message)

        let header = try readExactly(descriptor, count: 4)
        let length =
            UInt32(header[0]) << 24 | UInt32(header[1]) << 16 | UInt32(header[2]) << 8
            | UInt32(header[3])
        // An agent that answers with a gigabyte is broken or hostile. The largest
        // real response is a key list, which stays far below this.
        guard length > 0, length <= 1 << 20 else { throw SSHAgentError.truncated }
        return try readExactly(descriptor, count: Int(length))
    }

    private static func connect(to path: String) throws -> Int32 {
        let descriptor = socket(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0)
        guard descriptor >= 0 else {
            throw SSHAgentError.connectionFailed(errnoText())
        }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard path.utf8.count < capacity else {
            close(descriptor)
            throw SSHAgentError.connectionFailed("socket path is too long")
        }
        _ = withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            path.withCString { source in
                strncpy(
                    UnsafeMutableRawPointer(pointer).assumingMemoryBound(to: CChar.self), source, capacity - 1
                )
            }
        }
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { rebound in
                Glibc.connect(descriptor, rebound, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            let message = errnoText()
            close(descriptor)
            throw SSHAgentError.connectionFailed(message)
        }
        return descriptor
    }

    private static func writeAll(_ descriptor: Int32, _ bytes: [UInt8]) throws {
        var offset = 0
        while offset < bytes.count {
            let written = bytes[offset...].withUnsafeBufferPointer { buffer in
                write(descriptor, buffer.baseAddress, buffer.count)
            }
            guard written > 0 else { throw SSHAgentError.connectionFailed(errnoText()) }
            offset += written
        }
    }

    private static func readExactly(_ descriptor: Int32, count: Int) throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: count)
        var offset = 0
        while offset < count {
            let received = bytes[offset...].withUnsafeMutableBufferPointer { buffer in
                read(descriptor, buffer.baseAddress, buffer.count)
            }
            guard received > 0 else { throw SSHAgentError.truncated }
            offset += received
        }
        return bytes
    }

    private static func errnoText() -> String {
        String(cString: strerror(errno))
    }
}
