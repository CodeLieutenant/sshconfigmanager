//
//  ConnectionResult.swift
//  SSHConfigCore
//
//  The result of a TCP reachability probe. The probe itself (Network.framework)
//  is platform code; this pure verdict type is shared (the tunnel-health reducer
//  consumes it).
//

import Foundation

public enum ConnectionResult: Equatable, Sendable {
    case reachable(milliseconds: Int)
    case unreachable // refused / no route / waiting
    case timedOut
    case failed(String)

    public var isReachable: Bool {
        if case .reachable = self { return true }
        return false
    }

    public var summary: String {
        switch self {
        case .reachable(let ms): return "Reachable · \(ms) ms"
        case .unreachable: return "Unreachable (refused or no route)"
        case .timedOut: return "Timed out"
        case .failed(let message): return "Failed: \(message)"
        }
    }
}
