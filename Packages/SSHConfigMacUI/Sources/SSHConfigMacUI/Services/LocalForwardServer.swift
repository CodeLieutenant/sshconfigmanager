//
//  LocalForwardServer.swift
//  sshconfigmanager
//
//  Binds a local TCP listener (127.0.0.1:<port>) and hands each accepted
//  connection to a callback. This is the local end of an `-L`/`-D` forward; the
//  in-process tunnel engine bridges each accepted connection to an SSH channel.
//
//  Sandbox note: binding a listening socket requires the
//  com.apple.security.network.server entitlement. This type is the spike for
//  "can a sandboxed app bind a localhost listener?" — see
//  docs/plans/tunneling/engine.md.
//

import Foundation
import Network
import SSHConfigEngine
import Synchronization

/// A localhost TCP listener. Lifecycle: `start()` to bind, `cancel()` to stop.
nonisolated final class LocalForwardServer: Sendable {
    enum State: Equatable, Sendable {
        case idle
        case listening(port: UInt16)
        case failed(String)
    }

    private struct Guarded {
        var listener: NWListener?
        var onAccept: (@Sendable (NWConnection) -> Void)?
        var onStateChange: (@Sendable (State) -> Void)?
    }

    private let queue = DispatchQueue(label: AppIdentity.scoped("localforward"))
    private let guarded = Mutex(Guarded())

    /// Called on `queue` for each accepted inbound connection.
    var onAccept: (@Sendable (NWConnection) -> Void)? {
        get { guarded.withLock { $0.onAccept } }
        set { guarded.withLock { $0.onAccept = newValue } }
    }
    /// Called on `queue` when the listening state changes.
    var onStateChange: (@Sendable (State) -> Void)? {
        get { guarded.withLock { $0.onStateChange } }
        set { guarded.withLock { $0.onStateChange = newValue } }
    }

    /// Starts listening on 127.0.0.1 at `port` (0 = an OS-assigned free port).
    /// Throws synchronously only on parameter errors; bind failures arrive via
    /// `onStateChange(.failed)`.
    func start(port: UInt16) throws {
        let params = NWParameters.tcp
        params.requiredInterfaceType = .loopback
        params.allowLocalEndpointReuse = true

        let nwPort = NWEndpoint.Port(rawValue: port) ?? .any
        let listener = try NWListener(using: params, on: nwPort)
        guarded.withLock { $0.listener = listener }

        listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                let bound = listener.port?.rawValue ?? port
                self?.onStateChange?(.listening(port: bound))
            case .failed(let error):
                self?.onStateChange?(.failed(SSHErrorText.describe(error)))
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            connection.start(queue: self?.queue ?? .global())
            self?.onAccept?(connection)
        }
        listener.start(queue: queue)
    }

    func cancel() {
        let listener = guarded.withLock { state in
            defer { state.listener = nil }
            return state.listener
        }
        listener?.cancel()
    }

    deinit { guarded.withLock { $0.listener }?.cancel() }
}
