//
//  AuthSeams.swift
//  SSHConfigEngine
//
//  The two places SSH authentication has to leave the engine and reach the host
//  program: asking a human for a secret, and asking an ssh-agent to sign.
//
//  Both were direct calls into macOS code (an NSAlert, and the app's
//  SSHAgentService actor), which is what kept the auth delegates tied to AppKit.
//  As protocols, the engine states what it needs and each front end supplies it:
//  the Mac app shows an alert and talks to its agent service, a terminal client
//  reads the tty and opens SSH_AUTH_SOCK itself.
//

import Foundation

/// One field of a keyboard-interactive (RFC 4256) challenge.
///
/// A struct rather than the `(text:echo:)` tuple NIOSSH hands over, because the
/// prompt crosses an actor boundary and tuples cannot conform to `Sendable`.
public struct SSHAuthPrompt: Sendable, Equatable {
    /// The label to show, supplied by the server.
    public let text: String
    /// `false` for secrets — the entry field must not echo what is typed.
    public let echo: Bool

    public init(text: String, echo: Bool) {
        self.text = text
        self.echo = echo
    }
}

/// Collects secrets from the user during authentication. Every method returns
/// `nil` when the user cancels, which the delegates treat as "stop offering this
/// method" rather than as a failure.
///
/// Implementations may take as long as they like — the tunnel supervisor is told
/// a prompt is open and suspends its timeout until the answer arrives.
public protocol SSHCredentialPrompting: Sendable {
    /// Password for the `password` auth method.
    func promptForPassword(username: String) async -> String?

    /// Responses to a keyboard-interactive challenge, in prompt order. Returning
    /// an array of a different length than `prompts` is a programming error.
    func promptForChallenges(
        name: String, instruction: String, prompts: [SSHAuthPrompt]
    ) async -> [String]?
}

/// Signs an authentication challenge with a key held by an ssh-agent, so the
/// private key never enters this process.
public protocol SSHAgentSigning: Sendable {
    /// - Parameters:
    ///   - keyBlob: the identity's public key blob, as the agent listed it.
    ///   - data: the challenge to sign.
    ///   - flags: SSH_AGENT_RSA_SHA2_* request flags. RSA identities must pass a
    ///     SHA-2 flag; a zero flag yields a SHA-1 signature that modern servers reject.
    ///   - socketPath: overrides `SSH_AUTH_SOCK`, set from `IdentityAgent`.
    /// - Returns: the signature in SSH wire format.
    func sign(
        keyBlob: [UInt8], data: [UInt8], flags: UInt32, socketPath: String?
    ) async throws -> [UInt8]
}

/// Refuses every prompt, for non-interactive callers (a daemon, a test) where
/// there is no one to ask. Auth then falls through to the next method.
public struct NonInteractivePrompter: SSHCredentialPrompting {
    public init() {}

    public func promptForPassword(username: String) async -> String? { nil }

    public func promptForChallenges(
        name: String, instruction: String, prompts: [SSHAuthPrompt]
    ) async -> [String]? { nil }
}
