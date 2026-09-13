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

struct UserAuthenticationStateMachine {
    private var state: State
    private var delegate: UserAuthDelegate
    private let loop: EventLoop
    private var sessionID: ByteBuffer

    // NIOSSH patch (sshconfigmanager): tracks which auth method the client sent last so that
    // incoming wire ID 60 can be decoded as PK_OK or INFO_REQUEST based on context.
    private var lastSentAuthMethod: LastSentAuthMethod = .none
    /// Delegate for keyboard-interactive challenge prompts (RFC 4256). NIOSSH patch (sshconfigmanager).
    var keyboardInteractiveDelegate: (any NIOSSHKeyboardInteractiveDelegate)?

    // TODO: The server SHOULD limit the number of authentication attempts the client may make.
    init(role: SSHConnectionRole, loop: EventLoop, sessionID: ByteBuffer) {
        self.state = .idle
        self.delegate = UserAuthDelegate(role: role)
        self.loop = loop
        self.sessionID = sessionID
    }

    fileprivate static let serviceName: String = "ssh-userauth"

    fileprivate static let nextServiceName: String = "ssh-connection"
}

extension UserAuthenticationStateMachine {
    fileprivate enum State {
        /// In this state, we have not received any user auth messages yet
        case idle
        case awaitingServiceAcceptance
        case awaitingNextRequest
        case awaitingResponses(Int)
        case authenticationSucceeded
        case authenticationFailed
    }

    /// Tracks which auth method the client most recently sent so that wire ID 60 can be
    /// decoded correctly. NIOSSH patch (sshconfigmanager).
    fileprivate enum LastSentAuthMethod {
        case none
        case publicKey
        case keyboardInteractive
    }
}

extension UserAuthenticationStateMachine {
    fileprivate static let protocolName = "userauth"
}

// MARK: Receiving Messages

extension UserAuthenticationStateMachine {
    /// A ServiceRequest message was received from the remote peer.
    mutating func receiveServiceRequest(
        _ message: SSHMessage.ServiceRequestMessage
    ) throws -> SSHMessage.ServiceAcceptMessage? {
        switch (self.delegate, self.state) {
        case (.server, .idle):
            guard message.service == Self.serviceName else {
                throw NIOSSHError.protocolViolation(
                    protocolName: Self.protocolName,
                    violation: "unexpected service request: \(message)"
                )
            }

            self.state = .awaitingServiceAcceptance
            return .init(service: Self.serviceName)

        case (.server, .awaitingServiceAcceptance),
            (.server, .awaitingNextRequest),
            (.server, .awaitingResponses):
            throw NIOSSHError.protocolViolation(
                protocolName: Self.protocolName,
                violation: "unexpected state for service request: \(message)"
            )

        case (.server, .authenticationSucceeded):
            // We ignore messages after authentication succeeded.
            return nil

        case (.server, .authenticationFailed):
            // TODO(cory): We should be limiting the maximum number of authentication attempts.
            preconditionFailure("Servers cannot enter authentication failed")

        case (.client, _):
            // Clients may never receive user service request messages.
            throw NIOSSHError.protocolViolation(
                protocolName: Self.protocolName,
                violation: "server sent service request: \(message)"
            )
        }
    }

    /// A ServiceAccept message was received from the remote peer.
    mutating func receiveServiceAccept(
        _ message: SSHMessage.ServiceAcceptMessage
    ) throws -> EventLoopFuture<SSHMessage.UserAuthRequestMessage?>? {
        switch (self.delegate, self.state) {
        case (.client(let delegate), .awaitingServiceAcceptance):
            guard message.service == Self.serviceName else {
                throw NIOSSHError.protocolViolation(
                    protocolName: Self.protocolName,
                    violation: "unexpected service accept: \(message)"
                )
            }

            // Cool, we can begin the auth dance.
            self.state = .awaitingNextRequest
            return self.requestNextAuthRequest(methods: .all, delegate: delegate)
        case (.client, .authenticationSucceeded):
            // We should ignore all further auth messages in this state.
            return nil
        case (.client, .idle):
            // Server sent a service accept but we didn't ask them to!
            throw NIOSSHError.protocolViolation(
                protocolName: Self.protocolName,
                violation: "unsolicited service accept message: \(message)"
            )
        case (.client, .awaitingNextRequest),
            (.client, .awaitingResponses),
            (.client, .authenticationFailed):
            // In these states we aren't expecting a service accept message
            throw NIOSSHError.protocolViolation(
                protocolName: Self.protocolName,
                violation: "unsolicited service accept message: \(message)"
            )
        case (.server, _):
            // Servers may never receive user auth success messages.
            throw NIOSSHError.protocolViolation(
                protocolName: Self.protocolName,
                violation: "client sent user auth success"
            )
        }
    }

    /// A UserAuthRequest message was received from the remote peer.
    mutating func receiveUserAuthRequest(
        _ message: SSHMessage.UserAuthRequestMessage
    ) throws -> EventLoopFuture<NIOSSHUserAuthenticationResponseMessage>? {
        guard message.service == Self.nextServiceName else {
            throw NIOSSHError.protocolViolation(
                protocolName: Self.protocolName,
                violation: "requested unsupported service: \(message.service)"
            )
        }

        switch (self.delegate, self.state) {
        case (.server(let delegate), .awaitingNextRequest):
            self.state = .awaitingResponses(1)
            return self.nextAuthResponse(request: message, delegate: delegate)

        case (.server(let delegate), .awaitingResponses(let pending)):
            self.state = .awaitingResponses(pending + 1)
            return self.nextAuthResponse(request: message, delegate: delegate)

        case (.server, .idle), (.server, .awaitingServiceAcceptance):
            throw NIOSSHError.protocolViolation(
                protocolName: Self.protocolName,
                violation: "user auth request before service accepted"
            )

        case (.server, .authenticationSucceeded):
            // We ignore messages after authentication succeeded.
            return nil

        case (.server, .authenticationFailed):
            // TODO(cory): We should be limiting the maximum number of authentication attempts.
            preconditionFailure("Servers cannot enter authentication failed")

        case (.client, _):
            // Clients may never receive user auth request messages.
            throw NIOSSHError.protocolViolation(
                protocolName: Self.protocolName,
                violation: "server sent user auth request"
            )
        }
    }

    /// We've received a user auth success message.
    ///
    /// If this method completes without throwing, user auth has completed.
    mutating func receiveUserAuthSuccess() throws {
        switch (self.delegate, self.state) {
        case (.client, .awaitingResponses):
            // Great, we got a response, and it's a success! Disregard all future responses
            self.state = .authenticationSucceeded
        case (.client, .authenticationSucceeded):
            // We should ignore all further auth messages in this state.
            break
        case (.client, .idle), (.client, .awaitingServiceAcceptance):
            // Server sent a user auth success but we didn't ask them to!
            throw NIOSSHError.protocolViolation(
                protocolName: Self.protocolName,
                violation: "unsolicited auth success message"
            )
        case (.client, .awaitingNextRequest), (.client, .authenticationFailed):
            // In these states we believe we received all our auth responses, so this is wrong.
            throw NIOSSHError.protocolViolation(
                protocolName: Self.protocolName,
                violation: "unsolicited auth success message"
            )
        case (.server, _):
            // Servers may never receive user auth success messages.
            throw NIOSSHError.protocolViolation(
                protocolName: Self.protocolName,
                violation: "client sent user auth success"
            )
        }
    }

    mutating func receiveUserAuthFailure(
        _ message: SSHMessage.UserAuthFailureMessage
    ) throws -> EventLoopFuture<SSHMessage.UserAuthRequestMessage?>? {
        switch (self.delegate, self.state) {
        case (.client(let delegate), .awaitingResponses(let responseCount)):
            // Ok, the server didn't like that much. Let's try another one.
            self.state = .awaitingNextRequest
            precondition(responseCount == 1, "We don't support parallel authentication attempts yet!")
            return self.requestNextAuthRequest(methods: .init(message), delegate: delegate)
        case (.client, .authenticationSucceeded):
            // We should ignore all further auth messages in this state.
            return nil
        case (.client, .idle), (.client, .awaitingServiceAcceptance):
            // Server sent a user auth success but we didn't ask them to!
            throw NIOSSHError.protocolViolation(
                protocolName: Self.protocolName,
                violation: "server sent user auth failure unprompted"
            )
        case (.client, .awaitingNextRequest), (.client, .authenticationFailed):
            // In these states we believe we received all our auth responses, so this is wrong.
            throw NIOSSHError.protocolViolation(
                protocolName: Self.protocolName,
                violation: "unsolicited auth failure message"
            )
        case (.server, _):
            // Servers may never receive user auth failure messages.
            throw NIOSSHError.protocolViolation(
                protocolName: Self.protocolName,
                violation: "client sent user auth failure"
            )
        }
    }

    mutating func receiveUserAuthBanner(_: SSHMessage.UserAuthBannerMessage) throws {
        switch (self.delegate, self.state) {
        case (.client, .idle), (.client, .authenticationSucceeded):
            // Server sent a user auth success but we didn't ask them to!
            throw NIOSSHError.protocolViolation(
                protocolName: Self.protocolName,
                violation: "server sent user auth banner at the wrong time"
            )
        case (.server, _):
            // Servers may never receive user auth banner messages.
            throw NIOSSHError.protocolViolation(
                protocolName: Self.protocolName,
                violation: "client sent user auth banner"
            )
        default:
            // In all other instances, receiving user auth banner is legal and must be dealt with by client
            return
        }
    }

    /// Decodes wire ID 60 as SSH_MSG_USERAUTH_INFO_REQUEST (keyboard-interactive) or
    /// SSH_MSG_USERAUTH_PK_OK (publickey-probe) based on which method is in flight.
    /// Returns a future that resolves to the INFO_RESPONSE to send, or nil for PK_OK.
    /// NIOSSH patch (sshconfigmanager).
    mutating func receiveUserAuth60Raw(
        _ buffer: ByteBuffer
    ) throws -> EventLoopFuture<SSHMessage.UserAuthInfoResponseMessage>? {
        guard self.lastSentAuthMethod == .keyboardInteractive else {
            // The current delegates never send a publickey-probe (no-signature) request, so
            // receiving ID 60 outside of keyboard-interactive is a protocol violation here.
            throw NIOSSHError.protocolViolation(
                protocolName: Self.protocolName,
                violation: "received wire ID 60 but last sent method was not keyboard-interactive"
            )
        }

        var buf = buffer
        guard let infoRequest = buf.readUserAuthInfoRequestMessage() else {
            throw NIOSSHError.invalidSSHMessage(reason: "malformed SSH_MSG_USERAUTH_INFO_REQUEST")
        }

        guard let kbdDelegate = self.keyboardInteractiveDelegate else {
            // No delegate — respond with empty strings so the server can send a FAILURE.
            return self.loop.makeSucceededFuture(
                SSHMessage.UserAuthInfoResponseMessage(
                    responses: Array(repeating: "", count: infoRequest.prompts.count))
            )
        }

        let promise = self.loop.makePromise(of: [String].self)
        kbdDelegate.handleChallenge(
            name: infoRequest.name,
            instruction: infoRequest.instruction,
            prompts: infoRequest.prompts,
            responsePromise: promise
        )
        return promise.futureResult.map { responses in
            SSHMessage.UserAuthInfoResponseMessage(responses: responses)
        }
    }

    /// Called when INFO_RESPONSE is about to be sent. NIOSSH patch (sshconfigmanager).
    mutating func sendUserAuthInfoResponse(_: SSHMessage.UserAuthInfoResponseMessage) {
        // State stays in .awaitingResponses(1) until SUCCESS/FAILURE arrives from the server.
    }
}

// MARK: Sending Messages

extension UserAuthenticationStateMachine {
    mutating func sendServiceRequest(_ message: SSHMessage.ServiceRequestMessage) {
        switch (self.delegate, self.state) {
        case (.client, .idle):
            precondition(message.service == Self.serviceName)
            self.state = .awaitingServiceAcceptance
        case (.client, .awaitingServiceAcceptance):
            preconditionFailure("Duplicate service request")
        case (.client, .awaitingNextRequest),
            (.client, .awaitingResponses),
            (.client, .authenticationSucceeded),
            (.client, .authenticationFailed):
            preconditionFailure("May not send service request in \(self.state)")
        case (.server, _):
            preconditionFailure("Servers may not send service requests")
        }
    }

    mutating func sendServiceAccept(_ message: SSHMessage.ServiceAcceptMessage) {
        switch (self.delegate, self.state) {
        case (.server, .awaitingServiceAcceptance):
            precondition(message.service == Self.serviceName)
            self.state = .awaitingNextRequest
        case (.server, .idle):
            preconditionFailure("Cannot accept a service that hasn't been requested")
        case (.server, .awaitingNextRequest),
            (.server, .awaitingResponses),
            (.server, .authenticationSucceeded),
            (.server, .authenticationFailed):
            preconditionFailure("May not send service request in \(self.state)")
        case (.client, _):
            preconditionFailure("Clients may not send service acceptance")
        }
    }

    mutating func sendUserAuthRequest(_ message: SSHMessage.UserAuthRequestMessage) {
        switch (self.delegate, self.state) {
        case (.client, .awaitingNextRequest):
            self.state = .awaitingResponses(1)
            // Track which method was sent so we can disambiguate wire ID 60 on receipt.
            // NIOSSH patch (sshconfigmanager).
            switch message.method {
            case .publicKey:
                self.lastSentAuthMethod = .publicKey
            case .keyboardInteractive:
                self.lastSentAuthMethod = .keyboardInteractive
            default:
                self.lastSentAuthMethod = .none
            }
        case (.client, .idle),
            (.client, .awaitingServiceAcceptance):
            preconditionFailure("Sent an auth request without asking us first")
        case (.client, .awaitingResponses):
            // TODO(cory): We could probably support parallel auth attempts if we wanted to.
            preconditionFailure(
                "Attempted to send a user auth request while we were waiting for a response to the last one."
            )
        case (.client, .authenticationSucceeded):
            preconditionFailure("Attempted to send a user auth request after auth succeeded")
        case (.client, .authenticationFailed):
            preconditionFailure("Attempted to send a user auth request after auth failed")
        case (.server, _):
            // Servers may never send user auth request messages.
            preconditionFailure("Servers may not authenticate")
        }
    }

    mutating func sendUserAuthPKOK(_: SSHMessage.UserAuthPKOKMessage) {
        switch (self.delegate, self.state) {
        case (.server, .idle),
            (.server, .awaitingServiceAcceptance):
            preconditionFailure("Server sent an auth response prior to receiving an auth request")
        case (.server, .awaitingNextRequest):
            preconditionFailure("Too many auth responses sent")
        case (.server, .awaitingResponses(let responseCount)):
            if responseCount > 1 {
                self.state = .awaitingResponses(responseCount - 1)
            } else {
                self.state = .awaitingNextRequest
            }
        case (.server, .authenticationSucceeded):
            preconditionFailure("Authentication already succeeded, further messages are unnecessary.")
        case (.server, .authenticationFailed):
            preconditionFailure("Servers can never enter authenticationFailed")
        case (.client, _):
            preconditionFailure("Clients never send auth responses")
        }
    }

    mutating func sendUserAuthSuccess() {
        self.sendUserAuthResponseMessage(success: true)
    }

    mutating func sendUserAuthFailure(_: SSHMessage.UserAuthFailureMessage) {
        self.sendUserAuthResponseMessage(success: false)
    }

    mutating func sendUserAuthBanner(_: SSHMessage.UserAuthBannerMessage) {
        // Relevant passage from RFC 4252:
        //
        // The SSH server may send an SSH_MSG_USERAUTH_BANNER message at any
        // time after this authentication protocol starts and before
        // authentication is successful.  This message contains text to be
        // displayed to the client user before authentication is attempted.  The
        // format is as follows:
        switch (self.delegate, self.state) {
        case (.server, .idle):
            preconditionFailure("Banner sent before authentication protocol start")
        case (.server, .authenticationSucceeded):
            preconditionFailure("Banner sent after authentication suceeded")
        case (.server, _):
            break
        case (.client, _):
            preconditionFailure("Clients never send auth responses")
        }
    }

    private mutating func sendUserAuthResponseMessage(success: Bool) {
        switch (self.delegate, self.state) {
        case (.server, .idle),
            (.server, .awaitingServiceAcceptance):
            preconditionFailure("Server sent an auth response prior to receiving an auth request")
        case (.server, .awaitingNextRequest):
            preconditionFailure("Too many auth responses sent")
        case (.server, .awaitingResponses(let responseCount)):
            if success {
                self.state = .authenticationSucceeded
            } else if responseCount > 1 {
                self.state = .awaitingResponses(responseCount - 1)
            } else {
                self.state = .awaitingNextRequest
            }
        case (.server, .authenticationSucceeded):
            preconditionFailure("Authentication already succeeded, further messages are unnecessary.")
        case (.server, .authenticationFailed):
            preconditionFailure("Servers can never enter authenticationFailed")
        case (.client, _):
            preconditionFailure("Clients never send auth responses")
        }
    }
}

// MARK: Client authentication methods

extension UserAuthenticationStateMachine {
    /// Called to begin authentication in the state machine.
    func beginAuthentication() -> SSHMessage.ServiceRequestMessage? {
        switch (self.delegate, self.state) {
        case (.client, .idle):
            return SSHMessage.ServiceRequestMessage(service: Self.serviceName)
        case (.client, .awaitingServiceAcceptance),
            (.client, .awaitingNextRequest),
            (.client, .awaitingResponses),
            (.client, .authenticationSucceeded),
            (.client, .authenticationFailed):
            // TODO(cory): We could probably support parallel auth attempts if we wanted to.
            preconditionFailure("Cannot start authentication twice, state: \(self.state)")
        case (.server, _):
            return nil
        }
    }

    /// Called when the last call to obtain an authentication request returned nil.
    mutating func noFurtherMethods() {
        switch (self.delegate, self.state) {
        case (.client, .awaitingNextRequest):
            self.state = .authenticationFailed
        case (.client, .idle),
            (.client, .awaitingServiceAcceptance):
            preconditionFailure("Ran out of auth methods before asking for any")
        case (.client, .awaitingResponses),
            (.client, .authenticationSucceeded),
            (.client, .authenticationFailed):
            // TODO(cory): We could probably support parallel auth attempts if we wanted to.
            preconditionFailure("Request for further auth failed when no such request should be outstanding")
        case (.server, _):
            preconditionFailure("Servers may not authenticate")
        }
    }
}

// MARK: Interacting with client delegate

extension UserAuthenticationStateMachine {
    fileprivate func requestNextAuthRequest(
        methods: NIOSSHAvailableUserAuthenticationMethods,
        delegate: NIOSSHClientUserAuthenticationDelegate
    ) -> EventLoopFuture<SSHMessage.UserAuthRequestMessage?> {
        let promise = self.loop.makePromise(of: NIOSSHUserAuthenticationOffer?.self)
        delegate.nextAuthenticationType(availableMethods: methods, nextChallengePromise: promise)

        // The explicit capture list is here to force a copy of the buffer, rather than capturing self.
        let loop = self.loop
        return promise.futureResult.flatMap { [sessionID = self.sessionID] request -> EventLoopFuture<SSHMessage.UserAuthRequestMessage?> in
            guard let request else { return loop.makeSucceededFuture(nil) }

            // External-signer (e.g. ssh-agent) offers sign asynchronously: NIOSSH
            // builds the exact signable payload, then awaits the caller's signer
            // off the event loop. NIOSSH patch (sshconfigmanager); see Vendor/PATCH.md.
            if case .externalKey(let external) = request.offer {
                let payload = UserAuthSignablePayload(
                    sessionIdentifier: sessionID,
                    userName: request.username,
                    serviceName: "ssh-connection",
                    publicKey: external.publicKey
                )
                return loop.makeFutureWithTask {
                    try await external.sign(payload.bytes)
                }.map { signature in
                    SSHMessage.UserAuthRequestMessage(
                        username: request.username,
                        service: "ssh-connection",
                        method: .publicKey(.known(key: external.publicKey, signature: signature))
                    )
                }
            }

            return loop.makeCompletedFuture {
                try SSHMessage.UserAuthRequestMessage(request: request, sessionID: sessionID)
            }
        }
    }
}

// MARK: Interacting with server delegate

extension UserAuthenticationStateMachine {
    fileprivate func nextAuthResponse(
        request: SSHMessage.UserAuthRequestMessage,
        delegate: NIOSSHServerUserAuthenticationDelegate
    ) -> EventLoopFuture<NIOSSHUserAuthenticationResponseMessage> {
        switch request.method {
        case .password(let password):
            let request = NIOSSHUserAuthenticationRequest(
                username: request.username,
                serviceName: request.service,
                request: .password(.init(password: password))
            )
            let promise = self.loop.makePromise(of: NIOSSHUserAuthenticationOutcome.self)
            delegate.requestReceived(request: request, responsePromise: promise)
            let supportedMethods = delegate.supportedAuthenticationMethods

            return promise.futureResult.map { outcome in
                .init(outcome, supportedMethods: supportedMethods)
            }

        case .publicKey(.known(key: let key, signature: .some(let signature))):
            // This is a direct request to auth, just pass it through.
            let dataToSign = UserAuthSignablePayload(
                sessionIdentifier: sessionID,
                userName: request.username,
                serviceName: request.service,
                publicKey: key
            )
            let supportedMethods = delegate.supportedAuthenticationMethods

            guard key.isValidSignature(signature, for: dataToSign) else {
                // Whoops, signature not valid.
                return self.loop.makeSucceededFuture(
                    .failure(.init(authentications: supportedMethods.strings, partialSuccess: false))
                )
            }

            // Signature is valid, ask if the delegate is happy.
            let request = NIOSSHUserAuthenticationRequest(
                username: request.username,
                serviceName: request.service,
                request: .publicKey(.init(publicKey: key))
            )
            let promise = self.loop.makePromise(of: NIOSSHUserAuthenticationOutcome.self)
            delegate.requestReceived(request: request, responsePromise: promise)

            return promise.futureResult.map { outcome in
                .init(outcome, supportedMethods: supportedMethods)
            }

        case .publicKey(.known(key: let key, signature: .none)):
            // This is a weird wrinkle in public key auth: it's a request to ask whether a given key is valid, but not to validate that key itself.
            // For now we do a shortcut: we just say that all keys are acceptable, rather than ask the delegate.
            return self.loop.makeSucceededFuture(.publicKeyOK(.init(key: key)))

        case .publicKey(.unknown):
            // We don't known the algorithm, the auth attempt has failed.
            return self.loop.makeSucceededFuture(
                .failure(.init(authentications: delegate.supportedAuthenticationMethods.strings, partialSuccess: false))
            )

        case .none:
            let request = NIOSSHUserAuthenticationRequest(
                username: request.username,
                serviceName: request.service,
                request: .none
            )
            let promise = self.loop.makePromise(of: NIOSSHUserAuthenticationOutcome.self)
            delegate.requestReceived(request: request, responsePromise: promise)
            let supportedMethods = delegate.supportedAuthenticationMethods

            return promise.futureResult.map { outcome in
                .init(outcome, supportedMethods: supportedMethods)
            }

        case .keyboardInteractive:
            // Server-side: keyboard-interactive is client-driven via RFC 4256; a server that
            // receives this request should reject it if it doesn't support the method.
            // NIOSSH patch (sshconfigmanager).
            return self.loop.makeSucceededFuture(
                .failure(.init(authentications: delegate.supportedAuthenticationMethods.strings, partialSuccess: false))
            )
        }
    }
}
