//
//  SSHErrorText.swift
//  sshconfigmanager
//
//  Turns the errors the NIO stack throws during a connect into something a
//  human can act on.
//
//  `Error.localizedDescription` is worse than useless here: NIO's error types
//  are plain `Error` structs, so Foundation's bridging produces
//  "The operation couldn't be completed. (NIOPosix.NIOConnectionError error 1.)"
//  — which is what a failed tunnel used to report, hiding a perfectly clear
//  "Connection refused" underneath. Most of these types DO implement
//  `CustomStringConvertible`; the fix is to reach for `description` (and, for
//  the connect path, unwrap to the errno underneath) instead.
//

import Foundation
import NIOCore
import NIOPosix
import NIOSSH

public nonisolated enum SSHErrorText {
    /// A human-readable description of `error`, preferring the most specific
    /// wording available: our own `LocalizedError`s, then the structured NIO
    /// connect failure, then any `CustomStringConvertible`, then Foundation.
    public static func describe(_ error: Error) -> String {
        if let connection = error as? NIOConnectionError {
            return describeConnect(connection)
        }
        if let channel = error as? ChannelError {
            return describeChannel(channel)
        }
        if let io = error as? IOError {
            return errnoText(io.errnoCode)
        }
        if let localized = (error as? LocalizedError)?.errorDescription {
            return localized
        }
        if let ssh = error as? NIOSSHError {
            return "SSH protocol error: \(ssh)"
        }
        if let printable = error as? CustomStringConvertible {
            return printable.description
        }
        return error.localizedDescription
    }

    /// Describes a `direct-tcpip` channel the server would not open.
    ///
    /// This failure never touches the connect path: the SSH link is up, the local
    /// listener is bound, and the tunnel reports itself active. Only the individual
    /// forward dies, so the client sees an accepted TCP connection that closes with
    /// zero bytes — `NS_ERROR_NET_EMPTY_RESPONSE` in a browser.
    ///
    /// The reason code and the server's own text live in `NIOSSHError.diagnostics`,
    /// which the type keeps private and exposes only through `description`. Splitting
    /// that string is the only way to reach them without patching the fork.
    public static func describeForwardRejection(_ error: Error, targetHost: String, targetPort: Int) -> String {
        let target = "\(targetHost):\(targetPort)"
        guard let ssh = error as? NIOSSHError, ssh.type == .channelSetupRejected else {
            return "The forward to \(target) failed. \(describe(error))"
        }
        let detail = ssh.description.components(separatedBy: "Reason: ").dropFirst().joined(separator: "Reason: ")
        let code = UInt32(detail.prefix(while: \.isNumber)) ?? 0
        let text = detail.drop(while: \.isNumber).trimmingCharacters(in: .whitespaces)
        switch code {
        case 1: // SSH_OPEN_ADMINISTRATIVELY_PROHIBITED
            return "The server refused the forward to \(target). "
                + "Check AllowTcpForwarding and PermitOpen in its sshd_config."
        case 2: // SSH_OPEN_CONNECT_FAILED
            return "The server could not reach \(target). \(text)"
        case 4: // SSH_OPEN_RESOURCE_SHORTAGE
            return "The server has no resources for a new forward to \(target)."
        default:
            return "The server rejected the forward to \(target). \(text)"
        }
    }

    /// Happy Eyeballs collects a DNS failure per address family plus one failure
    /// per address it actually tried. Report the name-resolution problem first —
    /// "host not found" and "connection refused" call for very different fixes —
    /// and otherwise the first connect failure, which on a single-homed host is
    /// the only one.
    private static func describeConnect(_ error: NIOConnectionError) -> String {
        let target = "\(error.host):\(error.port)"
        if let dns = error.dnsAError ?? error.dnsAAAAError {
            return "Couldn't resolve \(error.host) — \(describe(dns))"
        }
        if let first = error.connectionErrors.first {
            return "Couldn't reach \(target) — \(describe(first.error))"
        }
        return "Couldn't reach \(target)."
    }

    private static func describeChannel(_ error: ChannelError) -> String {
        switch error {
        case .connectTimeout(let amount):
            return "Timed out connecting after \(Int(amount.nanoseconds / 1_000_000_000))s "
                + "(raise ConnectTimeout if the host is just slow)."
        case .connectPending:
            return "A connection attempt is already in flight."
        case .alreadyClosed, .ioOnClosedChannel, .outputClosed, .inputClosed:
            return "The connection was already closed."
        default:
            return "\(error)"
        }
    }

    /// The system's own wording for an errno (`strerror`) — "Connection refused",
    /// "No route to host", "Operation timed out". Exactly what `ssh` prints, and
    /// far more actionable than anything we'd paraphrase.
    private static func errnoText(_ code: CInt) -> String {
        guard let text = strerror(code) else { return "Error \(code)." }
        return String(cString: text)
    }
}
