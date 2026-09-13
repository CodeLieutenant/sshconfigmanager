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

import NIOCore

/// A ``NIOSSHClientUserAuthenticationDelegate`` is an object that can provide a sequence of
/// SSH user authentication methods based on the the acceptable list from the server.
///
/// This protocol defines the interface that will be used by the user authentication state
/// machine to move forward with challenges. Implementers of this protocol are free to take
/// time to actually get responses: for example, for password authentication it is possible
/// that the application would like to provide a user-interactive password prompt. This is
/// enabled by allowing implementers to satisfy a promise, rather than requiring that they
/// synchronously provide a response.
public protocol NIOSSHClientUserAuthenticationDelegate {
    /// Called when ``NIOSSH`` would like to attempt to offer a new authentication method.
    ///
    /// The callback is provided the authentication methods that the server is willing to accept in
    /// `availableMethods`. The delegate needs to provide an authentication offer by completing
    /// `nextChallengePromise`. If no further authentication offers are available (perhaps because the server
    /// has rejected them all) then this promise should be failed, which will terminate connection establishment.
    ///
    /// - parameters:
    ///     - availableMethods: The authentication methods the server is willing to accept.
    ///     - nextChallengePromise: An `EventLoopPromise` to be fulfilled with the next authentication offer.
    func nextAuthenticationType(
        availableMethods: NIOSSHAvailableUserAuthenticationMethods,
        nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
    )
}

/// Handles the challenge-response dialog for keyboard-interactive authentication (RFC 4256).
///
/// Implementations receive each INFO_REQUEST from the server, prompt the user (one field per
/// prompt), and fulfil `responsePromise` with the corresponding responses.  The promise must
/// always be fulfilled — succeed with an empty array if the interaction is cancelled so that
/// the connection can transition to a failure state rather than hanging.
///
/// NIOSSH patch (sshconfigmanager).
public protocol NIOSSHKeyboardInteractiveDelegate {
    /// Called for each SSH_MSG_USERAUTH_INFO_REQUEST from the server.
    ///
    /// - Parameters:
    ///   - name: Dialog title (often empty).
    ///   - instruction: Description shown above the prompts (often empty).
    ///   - prompts: One entry per prompt; `echo` indicates whether typed characters are visible.
    ///   - responsePromise: Fulfill with one response string per prompt, in order.
    func handleChallenge(
        name: String,
        instruction: String,
        prompts: [(text: String, echo: Bool)],
        responsePromise: EventLoopPromise<[String]>
    )
}
