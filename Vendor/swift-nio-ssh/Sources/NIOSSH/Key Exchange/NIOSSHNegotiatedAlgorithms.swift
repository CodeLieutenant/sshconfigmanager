//===----------------------------------------------------------------------===//
//
// This file is part of the vendored, patched swift-nio-ssh. See Vendor/PATCH.md.
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

/// What a connection actually negotiated, fired down the pipeline as a user inbound event
/// once NEWKEYS lands — and again after every rekey, since the algorithms can change.
///
/// Upstream keeps the negotiation result entirely private, so an application could not tell
/// whether it was talking over `aes256-gcm` or `3des-cbc`. SSH Config Manager reports it in
/// the tunnel console and flags weak choices, which needs the real negotiated values rather
/// than a re-derivation of the negotiation rules that could silently disagree.
public struct NIOSSHNegotiatedAlgorithms: Hashable, Sendable {
    /// The key exchange method, e.g. `mlkem768x25519-sha256`.
    public var keyExchange: String
    /// The server host key algorithm, e.g. `ssh-ed25519`. This is the *signature*
    /// algorithm, so `ssh-rsa` here means SHA-1 signing.
    public var hostKey: String
    /// The transport cipher, e.g. `aes256-gcm@openssh.com`.
    public var cipher: String
    /// The MAC, or `<implicit>` when the cipher is an AEAD and negotiated none.
    public var mac: String

    public init(keyExchange: String, hostKey: String, cipher: String, mac: String) {
        self.keyExchange = keyExchange
        self.hostKey = hostKey
        self.cipher = cipher
        self.mac = mac
    }

    /// True when the cipher authenticates the packet itself and no MAC was negotiated.
    public var usesImplicitMAC: Bool { self.mac == "<implicit>" }
}
