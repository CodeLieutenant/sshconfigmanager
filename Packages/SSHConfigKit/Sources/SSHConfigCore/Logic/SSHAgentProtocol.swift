//
//  SSHAgentProtocol.swift
//  sshconfigmanager
//
//  Pure encode/decode for the SSH agent protocol (draft-miller-ssh-agent), used
//  to list identities and request signatures over SSH_AUTH_SOCK. No I/O here so
//  the framing can be unit-tested directly; the socket lives in SSHAgentService.
//

import Foundation

/// One identity advertised by the agent: its public-key blob and comment.
public struct AgentIdentity: Equatable, Sendable {
    /// The SSH wire-format public key blob (as the agent returns it).
    public let keyBlob: [UInt8]
    public let comment: String
    /// The key type, parsed from the blob's first string field (e.g. "ssh-ed25519").
    public let keyType: String

    public init(keyBlob: [UInt8], comment: String, keyType: String) {
        self.keyBlob = keyBlob
        self.comment = comment
        self.keyType = keyType
    }
}

public enum SSHAgentError: LocalizedError {
    case socketUnavailable // SSH_AUTH_SOCK unset
    case connectionFailed(String)
    case truncated
    case unexpectedResponse(UInt8)
    case agentFailure

    public var errorDescription: String? {
        switch self {
        case .socketUnavailable: return "No SSH agent found (SSH_AUTH_SOCK is not set)."
        case .connectionFailed(let detail): return "Couldn't reach the SSH agent: \(detail)"
        case .truncated: return "The SSH agent returned a malformed (truncated) reply."
        case .unexpectedResponse(let type): return "Unexpected SSH agent reply (type \(type))."
        case .agentFailure: return "The SSH agent reported a failure."
        }
    }
}

public enum SSHAgentProtocol {
    // Message type bytes.
    public static let requestIdentities: UInt8 = 11 // SSH2_AGENTC_REQUEST_IDENTITIES
    public static let identitiesAnswer: UInt8 = 12 // SSH2_AGENT_IDENTITIES_ANSWER
    public static let signRequest: UInt8 = 13 // SSH2_AGENTC_SIGN_REQUEST
    public static let signResponse: UInt8 = 14 // SSH2_AGENT_SIGN_RESPONSE
    public static let addIdentity: UInt8 = 17 // SSH2_AGENTC_ADD_IDENTITY
    public static let removeIdentity: UInt8 = 18 // SSH2_AGENTC_REMOVE_IDENTITY
    public static let removeAllIdentities: UInt8 = 19 // SSH2_AGENTC_REMOVE_ALL_IDENTITIES
    public static let success: UInt8 = 6 // SSH_AGENT_SUCCESS
    public static let failure: UInt8 = 5 // SSH_AGENT_FAILURE

    // SIGN_REQUEST flags (draft-miller-ssh-agent §4.5). A plain `ssh-rsa` sign request
    // with flags=0 makes the agent return a legacy SHA-1 `ssh-rsa` signature, which
    // OpenSSH >= 8.8 servers reject and the vendored NIOSSHRSA plugin refuses to parse
    // (it only accepts `rsa-sha2-256`). RSA keys MUST request SHA-256 (audit #20).
    public static let signFlagRSASHA2256: UInt32 = 2 // SSH_AGENT_RSA_SHA2_256
    public static let signFlagRSASHA2512: UInt32 = 4 // SSH_AGENT_RSA_SHA2_512

    /// The SIGN_REQUEST flags to use for `keyType`: any RSA identity requests
    /// rsa-sha2-256; every other key type (ed25519, ecdsa-*) uses no flags.
    ///
    /// Matching only the bare `"ssh-rsa"` was audit #20 half-fixed: an agent
    /// identity backed by an OpenSSH *certificate* advertises
    /// `ssh-rsa-cert-v01@openssh.com`, and a modern agent may report
    /// `rsa-sha2-256`/`rsa-sha2-512` — all of which fell through to flags=0, got a
    /// legacy SHA-1 signature back, and were rejected by OpenSSH >= 8.8 and by the
    /// vendored NIOSSHRSA plugin. Every RSA spelling maps to rsa-sha2-256 because
    /// that is the one signature algorithm the plugin parses.
    public static func signFlags(forKeyType keyType: String) -> UInt32 {
        isRSA(keyType) ? signFlagRSASHA2256 : 0
    }

    /// Whether `keyType` names an RSA identity, in any of its wire spellings —
    /// plain, SHA-2-qualified, and the `-cert-v01@openssh.com` certificate forms.
    public static func isRSA(_ keyType: String) -> Bool {
        let certSuffix = "-cert-v01@openssh.com"
        let base = keyType.hasSuffix(certSuffix) ? String(keyType.dropLast(certSuffix.count)) : keyType
        return base == "ssh-rsa" || base == "rsa-sha2-256" || base == "rsa-sha2-512"
    }

    // MARK: - Requests (framed: uint32 length + payload)

    public static func requestIdentitiesMessage() -> [UInt8] {
        frame([requestIdentities])
    }

    public static func signRequestMessage(keyBlob: [UInt8], data: [UInt8], flags: UInt32) -> [UInt8] {
        var payload: [UInt8] = [signRequest]
        payload += string(keyBlob)
        payload += string(data)
        payload += uint32(flags)
        return frame(payload)
    }

    /// Loads a private key into the agent. `body` is the ADD_IDENTITY payload
    /// after the message-type byte — `string keyType · <private fields> · string
    /// comment` — built by `AgentKeySerializer.addIdentityBody`.
    public static func addIdentityMessage(body: [UInt8]) -> [UInt8] {
        frame([addIdentity] + body)
    }

    /// Unloads a single identity, addressed by its public-key blob.
    public static func removeIdentityMessage(keyBlob: [UInt8]) -> [UInt8] {
        var payload: [UInt8] = [removeIdentity]
        payload += string(keyBlob)
        return frame(payload)
    }

    /// Unloads every identity the agent holds.
    public static func removeAllIdentitiesMessage() -> [UInt8] {
        frame([removeAllIdentities])
    }

    /// Prepends the 4-byte big-endian length prefix.
    public static func frame(_ payload: [UInt8]) -> [UInt8] {
        uint32(UInt32(payload.count)) + payload
    }

    // MARK: - Responses (payload = the message body without the length prefix)

    /// Parses an IDENTITIES_ANSWER payload into identities.
    public static func parseIdentities(_ payload: [UInt8]) throws -> [AgentIdentity] {
        var reader = ByteReader(payload)
        let type = try reader.readUInt8()
        guard type == identitiesAnswer else {
            if type == failure { throw SSHAgentError.agentFailure }
            throw SSHAgentError.unexpectedResponse(type)
        }
        let count = try reader.readUInt32()
        var identities: [AgentIdentity] = []
        for _ in 0..<count {
            let blob = try reader.readString()
            let comment = try reader.readString()
            identities.append(
                AgentIdentity(
                    keyBlob: blob,
                    comment: String(decoding: comment, as: UTF8.self),
                    keyType: keyType(fromBlob: blob)
                ))
        }
        return identities
    }

    /// Parses a bare status reply (SUCCESS/FAILURE) returned by mutating requests
    /// such as REMOVE_IDENTITY. Throws `.agentFailure` on anything but SUCCESS so
    /// the UI can report agents that refuse removal (e.g. 1Password, Secretive).
    public static func parseStatus(_ payload: [UInt8]) throws {
        var reader = ByteReader(payload)
        let type = try reader.readUInt8()
        guard type == success else {
            if type == failure { throw SSHAgentError.agentFailure }
            throw SSHAgentError.unexpectedResponse(type)
        }
    }

    /// Parses a SIGN_RESPONSE payload, returning the raw signature blob.
    public static func parseSignature(_ payload: [UInt8]) throws -> [UInt8] {
        var reader = ByteReader(payload)
        let type = try reader.readUInt8()
        guard type == signResponse else {
            if type == failure { throw SSHAgentError.agentFailure }
            throw SSHAgentError.unexpectedResponse(type)
        }
        return try reader.readString()
    }

    /// The key type string is the first length-prefixed field inside a key blob.
    public static func keyType(fromBlob blob: [UInt8]) -> String {
        var reader = ByteReader(blob)
        guard let typeBytes = try? reader.readString() else { return "" }
        return String(decoding: typeBytes, as: UTF8.self)
    }

    // MARK: - Primitives (SSH wire format, big-endian)

    public static func uint32(_ value: UInt32) -> [UInt8] {
        [
            UInt8(value >> 24 & 0xFF), UInt8(value >> 16 & 0xFF),
            UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF),
        ]
    }

    /// A length-prefixed string: uint32 length + bytes.
    public static func string(_ bytes: [UInt8]) -> [UInt8] {
        uint32(UInt32(bytes.count)) + bytes
    }
}

/// A cursor over a byte buffer for reading SSH wire-format values.
public struct ByteReader {
    private let bytes: [UInt8]
    private var index = 0

    public init(_ bytes: [UInt8]) { self.bytes = bytes }

    public mutating func readUInt8() throws -> UInt8 {
        guard index < bytes.count else { throw SSHAgentError.truncated }
        defer { index += 1 }
        return bytes[index]
    }

    public mutating func readUInt32() throws -> UInt32 {
        guard index + 4 <= bytes.count else { throw SSHAgentError.truncated }
        defer { index += 4 }
        return UInt32(bytes[index]) << 24 | UInt32(bytes[index + 1]) << 16
            | UInt32(bytes[index + 2]) << 8 | UInt32(bytes[index + 3])
    }

    public mutating func readBytes(_ count: Int) throws -> [UInt8] {
        guard count >= 0, index + count <= bytes.count else { throw SSHAgentError.truncated }
        defer { index += count }
        return Array(bytes[index..<index + count])
    }

    public mutating func readString() throws -> [UInt8] {
        let length = try readUInt32()
        return try readBytes(Int(length))
    }
}
