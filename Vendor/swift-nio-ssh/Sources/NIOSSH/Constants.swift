//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2019 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

public enum Constants: Sendable {
    static let version = "SSH-2.0-SwiftNIOSSH_1.0"

    public static let bundledTransportProtectionSchemes: [(NIOSSHTransportProtection & _NIOSSHSendableMetatype).Type] =
        [
            // AEAD first: AES-GCM needs no separate MAC and runs on BoringSSL.
            AES256GCMOpenSSHTransportProtection.self, AES128GCMOpenSSHTransportProtection.self,
            // AES-CTR fallbacks, for servers that disable GCM. SSH negotiates the cipher and
            // the MAC separately, so the full cross product has to be offered: whichever
            // (cipher, MAC) pair negotiation lands on must have a scheme that implements it.
            // The order here also *is* the preference order we advertise, after de-duplication
            // in SSHKeyExchangeStateMachine — encrypt-then-MAC ahead of encrypt-and-MAC.
            AES256CTRSHA256ETMTransportProtection.self, AES256CTRSHA512ETMTransportProtection.self,
            AES256CTRSHA256TransportProtection.self, AES256CTRSHA512TransportProtection.self,
            AES192CTRSHA256ETMTransportProtection.self, AES192CTRSHA512ETMTransportProtection.self,
            AES192CTRSHA256TransportProtection.self, AES192CTRSHA512TransportProtection.self,
            AES128CTRSHA256ETMTransportProtection.self, AES128CTRSHA512ETMTransportProtection.self,
            AES128CTRSHA256TransportProtection.self, AES128CTRSHA512TransportProtection.self,
        ]

    /// The largest `packet_length` header this parser will believe.
    ///
    /// The length arrives before anything authenticates it — in the clear for AES-GCM and
    /// the encrypt-then-MAC schemes, merely decrypted for `chacha20-poly1305@openssh.com`
    /// and AES-CTR encrypt-and-MAC. Unchecked, a peer could name any 32-bit length: 4 GiB
    /// of buffering to wait for a packet that never comes, and — because `decryptLength`
    /// adds the MAC size to it — a `UInt32` overflow that traps and kills the process.
    ///
    /// The value is not RFC 4253 § 6.1's 35000. It is tied to the `maximumPacketSize` this
    /// implementation advertises when it opens a child channel (`1 << 24`, in
    /// `SSHChildChannel`): a peer that takes us at our word may send a channel data message
    /// that large, so anything smaller would refuse traffic we asked for. The slack covers
    /// the packet header, the channel-data framing and the padding. Raise both together or
    /// neither.
    static let maximumPacketLength: UInt32 = (1 << 24) + 1024
}
