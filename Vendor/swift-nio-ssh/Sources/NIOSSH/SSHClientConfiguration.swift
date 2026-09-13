//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2020 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

/// Configuration for an SSH client.
public struct SSHClientConfiguration {
    /// The user authentication delegate to be used with this client.
    public var userAuthDelegate: NIOSSHClientUserAuthenticationDelegate

    /// The server authentication delegate to be used with this client.
    public var serverAuthDelegate: NIOSSHClientServerAuthenticationDelegate

    /// The global request delegate to be used with this client.
    public var globalRequestDelegate: GlobalRequestDelegate

    /// Supported data encryption algorithms
    public var transportProtectionSchemes: [NIOSSHTransportProtection.Type]

    /// Handles keyboard-interactive (RFC 4256) challenge prompts. Optional; if nil, the
    /// connection will fail gracefully when the server requests keyboard-interactive auth.
    /// NIOSSH patch (sshconfigmanager).
    public var keyboardInteractiveDelegate: (any NIOSSHKeyboardInteractiveDelegate)?

    /// Restricts the key-exchange algorithms offered to the server, from `KexAlgorithms`.
    /// nil (default) offers every key-exchange algorithm this implementation supports —
    /// unchanged from upstream behavior. Set post-init, same as `keyboardInteractiveDelegate`.
    /// NIOSSH patch (sshconfigmanager).
    public var keyExchangeAlgorithmsOverride: [String]?

    /// Restricts which server host-key algorithms this client will accept, from
    /// `HostKeyAlgorithms`. nil (default) accepts every host-key algorithm this
    /// implementation supports — unchanged from upstream behavior. Set post-init,
    /// same as `keyboardInteractiveDelegate`. NIOSSH patch (sshconfigmanager).
    public var hostKeyAlgorithmsOverride: [String]?

    public init(
        userAuthDelegate: NIOSSHClientUserAuthenticationDelegate,
        serverAuthDelegate: NIOSSHClientServerAuthenticationDelegate,
        globalRequestDelegate: GlobalRequestDelegate? = nil
    ) {
        self.init(
            userAuthDelegate: userAuthDelegate,
            serverAuthDelegate: serverAuthDelegate,
            globalRequestDelegate: globalRequestDelegate,
            transportProtectionSchemes: Constants.bundledTransportProtectionSchemes
        )
    }

    public init(
        userAuthDelegate: NIOSSHClientUserAuthenticationDelegate,
        serverAuthDelegate: NIOSSHClientServerAuthenticationDelegate,
        globalRequestDelegate: GlobalRequestDelegate? = nil,
        transportProtectionSchemes: [NIOSSHTransportProtection.Type]
    ) {
        self.userAuthDelegate = userAuthDelegate
        self.serverAuthDelegate = serverAuthDelegate
        self.globalRequestDelegate = globalRequestDelegate ?? DefaultGlobalRequestDelegate()
        self.transportProtectionSchemes = transportProtectionSchemes
    }
}

// The various delegates aren't required to be Sendable, so the config isn't sendable.
@available(*, unavailable)
extension SSHClientConfiguration: Sendable {}

extension SSHClientConfiguration {
    /// Key-exchange algorithm names this implementation supports, in order of
    /// preference — the valid values for `keyExchangeAlgorithmsOverride`. Exposed so
    /// callers can validate a `KexAlgorithms` value before connecting rather than
    /// discovering an empty/no-op override mid-handshake. NIOSSH patch (sshconfigmanager).
    public static var supportedKeyExchangeAlgorithms: [String] {
        SSHKeyExchangeStateMachine.supportedKeyExchangeAlgorithms.map(String.init)
    }

    /// Host-key algorithm names this implementation supports, in order of preference —
    /// the valid values for `hostKeyAlgorithmsOverride`. Exposed for the same reason as
    /// `supportedKeyExchangeAlgorithms`. NIOSSH patch (sshconfigmanager).
    public static var supportedHostKeyAlgorithms: [String] {
        SSHKeyExchangeStateMachine.supportedServerHostKeyAlgorithms.map(String.init)
    }
}
