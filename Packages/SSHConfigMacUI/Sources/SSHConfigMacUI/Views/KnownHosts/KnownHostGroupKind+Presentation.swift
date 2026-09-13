import AppKit
import SSHConfigCore
import SSHConfigEngine
import SSHConfigServices
import SwiftUI

extension KnownHostGroup.Kind {
    var symbol: String {
        switch self {
        case .hostname: return "server.rack"
        case .ipAddress: return "network"
        case .hashed: return "lock.shield"
        }
    }
    var tile: Color {
        switch self {
        case .hostname: return TilePalette.knownHosts
        case .ipAddress: return TilePalette.tunnels
        case .hashed: return TilePalette.host
        }
    }
}
