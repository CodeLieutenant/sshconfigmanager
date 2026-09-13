//
//  AgentSignFlagsTests.swift
//  sshconfigmanagerTests
//
//  Regression coverage for bug #20 in docs/macos-prerelease-bug-audit.md:
//  the agent SIGN_REQUEST hardcoded flags=0, so for an `ssh-rsa` identity the agent
//  returned a legacy SHA-1 signature that OpenSSH >= 8.8 and the NIOSSHRSA plugin
//  reject — RSA agent keys could never authenticate. RSA must request rsa-sha2-256.
//

import Foundation
import SSHConfigCore
import Testing

struct AgentSignFlagsTests {
    @Test func rsaKeyRequestsSHA2256() {
        #expect(SSHAgentProtocol.signFlags(forKeyType: "ssh-rsa") == SSHAgentProtocol.signFlagRSASHA2256)
        #expect(SSHAgentProtocol.signFlags(forKeyType: "ssh-rsa") == 2)
    }

    @Test func nonRSAKeysUseNoFlags() {
        for keyType in ["ssh-ed25519", "ecdsa-sha2-nistp256", "ecdsa-sha2-nistp521", "sk-ssh-ed25519@openssh.com"] {
            #expect(SSHAgentProtocol.signFlags(forKeyType: keyType) == 0)
        }
    }

    @Test func signRequestEncodesFlagsBigEndian() {
        // The flags occupy the final 4 bytes of the (framed) SIGN_REQUEST message.
        let msg = SSHAgentProtocol.signRequestMessage(
            keyBlob: [1, 2, 3], data: [4, 5],
            flags: SSHAgentProtocol.signFlagRSASHA2256)
        #expect(Array(msg.suffix(4)) == [0, 0, 0, 2])
    }
}
