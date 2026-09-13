import Foundation
import SSHConfigCore

/// A tunnel the user defined in the app, as opposed to one the configuration
/// declares with LocalForward and friends.
///
/// The in-process engine is not linked on Linux yet (see TunnelsView), so this
/// type carries the definition and the command, and `status` stays `.stopped`
/// until the engine lands.
public struct TunnelDraft: Codable, Identifiable, Equatable {
    public enum Mode: String, Codable, CaseIterable {
        case local
        case remote
        case dynamic

        public var label: String {
            switch self {
            case .local: "Local (-L)"
            case .remote: "Remote (-R)"
            case .dynamic: "Dynamic (-D)"
            }
        }

        public var flag: String {
            switch self {
            case .local: "-L"
            case .remote: "-R"
            case .dynamic: "-D"
            }
        }
    }

    public enum Status: String, Codable {
        case stopped
        case starting
        case running
        case failed

        public var label: String {
            switch self {
            case .stopped: "Stopped"
            case .starting: "Starting"
            case .running: "Running"
            case .failed: "Failed"
            }
        }
    }

    public struct PortMapping: Codable, Identifiable, Equatable {
        public var id: UUID = UUID()
        public var localPort: String = ""
        public var remoteHost: String = "localhost"
        public var remotePort: String = ""

        public init(
            id: UUID = UUID(),
            localPort: String = "",
            remoteHost: String = "localhost",
            remotePort: String = ""
        ) {
            self.id = id
            self.localPort = localPort
            self.remoteHost = remoteHost
            self.remotePort = remotePort
        }
    }

    public var id: UUID = UUID()
    public var name: String = ""
    public var hostAlias: String = ""
    public var mode: Mode = .local
    public var mappings: [PortMapping] = [PortMapping()]
    public var keepAlive = true
    public var compression = false
    public var failIfPortBusy = true
    public var startOnLaunch = false
    public var status: Status = .stopped

    public init() {}

    /// The ssh command this tunnel is equivalent to. Shown in the editor so the
    /// user can check the app understood them, and copied when the engine is not
    /// available.
    public var command: String {
        var parts = ["ssh"]
        for mapping in mappings {
            switch mode {
            case .local, .remote:
                let spec = "\(mapping.localPort):\(mapping.remoteHost):\(mapping.remotePort)"
                parts.append(contentsOf: [mode.flag, spec])
            case .dynamic:
                parts.append(contentsOf: [mode.flag, mapping.localPort])
            }
        }
        if compression { parts.append("-C") }
        if keepAlive { parts.append(contentsOf: ["-o", "ServerAliveInterval=30"]) }
        if failIfPortBusy { parts.append(contentsOf: ["-o", "ExitOnForwardFailure=yes"]) }
        parts.append("-N")
        parts.append(hostAlias.isEmpty ? "<host>" : hostAlias)
        return parts.map(SSHCommandBuilder.shellQuote).joined(separator: " ")
    }

    public var summary: String {
        mappings
            .map { mapping in
                switch mode {
                case .dynamic: "localhost:\(mapping.localPort)"
                default: "\(mapping.localPort) → \(mapping.remoteHost):\(mapping.remotePort)"
                }
            }
            .joined(separator: ", ")
    }
}

/// Stores the tunnels the user defined. One JSON file, same reasoning as
/// `AppSettings`.
public enum TunnelStore {
    public static var path: String {
        let base =
            ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"]
            ?? "\(SSHDirectory.home)/.config"
        return "\(base)/sshmanager/tunnels.json"
    }

    public static func load() -> [TunnelDraft] {
        guard let data = FileManager.default.contents(atPath: path),
            let tunnels = try? JSONDecoder().decode([TunnelDraft].self, from: data)
        else { return [] }
        return tunnels
    }

    public static func save(_ tunnels: [TunnelDraft]) {
        let directory = URL(fileURLWithPath: path).deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(tunnels) else { return }
        try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }
}
