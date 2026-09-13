//
//  AgentKeySerializer.swift
//  sshconfigmanager
//
//  Serializes a parsed private key into the body of an ssh-agent ADD_IDENTITY
//  message (draft-miller-ssh-agent §3.2). This is what lets us load a key into
//  the agent *in-app over the socket* — no `ssh-add` subprocess, sandbox-safe —
//  reusing the same decrypt/parse the tunnel engine already does. Pure (no I/O)
//  so the wire layout is unit-tested directly.
//
//  The private-key fields are per key type and mirror the OpenSSH private blob
//  layout. Everything we need is already in `ParsedOpenSSHKey`: the ed25519 point
//  and the ECDSA point Q live in `publicKey`, and RSA's `iqmp` is retained in
//  `rsaIQMP`.
//

import Foundation
import SSHConfigCore

public enum AgentKeySerializer {
    /// The ADD_IDENTITY body: `string keyType · <private fields> · string comment`
    /// (everything after the message-type byte). Throws if the key type can't be
    /// serialized (e.g. an RSA key parsed without its `iqmp`).
    public static func addIdentityBody(for key: ParsedOpenSSHKey, comment: String) throws -> [UInt8] {
        var body = string(Array(key.keyType.utf8))
        body += try privateFields(for: key)
        body += string(Array(comment.utf8))
        return body
    }

    private static func privateFields(for key: ParsedOpenSSHKey) throws -> [UInt8] {
        switch key.material {
        case .ed25519(let seed):
            // string ENC(A) (32-byte public) + string (k || ENC(A)) (64-byte secret).
            guard key.publicKey.count == 32, seed.count == 32 else { throw OpenSSHKeyError.malformed }
            return string(key.publicKey) + string(seed + key.publicKey)

        case .ecdsa(let curve, let scalar):
            // string curveName + string Q (point) + mpint d (private scalar).
            guard !key.publicKey.isEmpty else { throw OpenSSHKeyError.malformed }
            return string(Array(curve.rawValue.utf8)) + string(key.publicKey) + mpint(scalar)

        case .rsa(let n, let e, let d, let p, let q):
            // mpint n, e, d, iqmp, p, q.
            guard let iqmp = key.rsaIQMP else { throw OpenSSHKeyError.malformed }
            return mpint(n) + mpint(e) + mpint(d) + mpint(iqmp) + mpint(p) + mpint(q)
        }
    }

    // MARK: - SSH wire primitives

    /// A length-prefixed string: uint32 length + bytes. Shares the encoding with
    /// `SSHAgentProtocol.string`.
    public static func string(_ bytes: [UInt8]) -> [UInt8] {
        SSHAgentProtocol.string(bytes)
    }

    /// An `mpint`: a two's-complement big-endian integer, length-prefixed. A
    /// leading 0x00 is prepended when the top bit is set so the value stays
    /// positive; leading zero bytes are otherwise trimmed.
    public static func mpint(_ magnitude: [UInt8]) -> [UInt8] {
        var bytes = magnitude
        while bytes.first == 0 { bytes.removeFirst() }
        if bytes.isEmpty { return SSHAgentProtocol.uint32(0) }
        if bytes[0] & 0x80 != 0 { bytes.insert(0, at: 0) }
        return string(bytes)
    }
}
