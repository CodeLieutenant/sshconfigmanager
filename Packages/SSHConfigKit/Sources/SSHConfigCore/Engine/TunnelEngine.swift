//
//  TunnelEngine.swift
//  sshconfigmanager
//
//  The pluggable engine that actually runs a tunnel, behind a protocol so the
//  store/monitor/UI don't care which strategy is used. The app runs tunnels
//  in-process via `NIOTunnelEngine` (swift-nio-ssh) — no Terminal, no subprocess —
//  so they can be started, stopped, logged, and metered from inside the app.
//  See docs/plans/tunneling/engine.md.
//

import Foundation

/// What an engine can and can't do — drives how the monitor and UI behave.
public struct TunnelEngineCapabilities: Sendable {
    /// The engine reports connection liveness directly (vs. only via port probe).
    public var reportsLiveness: Bool
    /// The engine can stop a running tunnel from inside the app.
    public var canStop: Bool
    /// Tunnels keep running after the app quits.
    public var survivesAppQuit: Bool
    /// The engine can report bytes pushed through the tunnel.
    public var reportsThroughput: Bool = false

    public init(reportsLiveness: Bool, canStop: Bool, survivesAppQuit: Bool, reportsThroughput: Bool = false) {
        self.reportsLiveness = reportsLiveness
        self.canStop = canStop
        self.survivesAppQuit = survivesAppQuit
        self.reportsThroughput = reportsThroughput
    }
}

/// An immediate liveness signal from a running tunnel. Engines that can observe
/// the connection (the in-process NIO engine) emit these so the supervisor reacts
/// at once instead of waiting for the next probe tick. See monitor.md §2.1.
public enum EngineEvent: Sendable {
    case connected // the tunnel is up (auth + forward established)
    case closed(reason: String?) // the connection dropped — retryable
    case failed(reason: String) // a hard fault (auth/key/host-key) — don't retry blindly
    case log(TunnelLogLevel, String) // a human-readable lifecycle line for the console
    case awaitingInput(Bool) // true: blocked on an interactive prompt (2FA/passphrase); false: answered
}

public enum TunnelEngineError: LocalizedError {
    case invalidPreset
    case launchFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidPreset: return "The tunnel is incomplete or has an invalid port."
        case .launchFailed(let detail): return "Couldn't launch the tunnel: \(detail)"
        }
    }
}

@MainActor
public protocol TunnelEngine {
    var capabilities: TunnelEngineCapabilities { get }
    /// Starts the tunnel. Throws if it can't be launched.
    func start(_ preset: TunnelPreset) throws
    /// Stops the tunnel if the engine is able to (no-op otherwise).
    func stop(_ preset: TunnelPreset)
    /// Immediate liveness events for a running tunnel, or nil if the engine can't
    /// observe the connection. Valid after `start`, until `stop`.
    func events(for preset: TunnelPreset) -> AsyncStream<EngineEvent>?
    /// Bytes pushed through the tunnel so far, or nil if the engine can't count it.
    func throughput(for preset: TunnelPreset) -> TunnelThroughput?
}

extension TunnelEngine {
    public func events(for preset: TunnelPreset) -> AsyncStream<EngineEvent>? { nil }
    public func throughput(for preset: TunnelPreset) -> TunnelThroughput? { nil }
}
