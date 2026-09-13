//
//  AgentCertificateSignFlagsTests.swift
//  sshconfigmanagerTests
//
//  Reproducer: `SSHAgentProtocol.signFlags` matches only the bare `"ssh-rsa"`.
//
//  This is audit #20 all over again, one key type over. An agent identity backed
//  by an OpenSSH *certificate* advertises its key type as
//  `ssh-rsa-cert-v01@openssh.com`, so the `keyType == "ssh-rsa"` test misses it,
//  flags stay 0, and the agent returns a legacy SHA-1 `ssh-rsa` signature — which
//  OpenSSH >= 8.8 servers reject and the vendored NIOSSHRSA plugin refuses to
//  parse. An RSA certificate held in the agent therefore can never authenticate,
//  the exact failure #20 fixed for plain RSA keys.
//
//  Certificates are a supported path here (`TunnelHop.certificateFile`,
//  `PublicKeyAuthDelegate.certifiedKey`), so this is reachable, not theoretical.
//

import Foundation
import SSHConfigCore
import SSHConfigEngine
import Testing

struct AgentCertificateSignFlagsTests {
    @Test func rsaCertificateRequestsSHA2256() {
        #expect(
            SSHAgentProtocol.signFlags(forKeyType: "ssh-rsa-cert-v01@openssh.com")
                == SSHAgentProtocol.signFlagRSASHA2256,
            "an RSA certificate identity must request rsa-sha2-256, same as a bare RSA key")
    }

    /// The modern spellings an agent may also report for an RSA identity.
    @Test(arguments: ["rsa-sha2-256", "rsa-sha2-512", "rsa-sha2-256-cert-v01@openssh.com"])
    func rsaVariantsRequestSHA2(_ keyType: String) {
        #expect(
            SSHAgentProtocol.signFlags(forKeyType: keyType) != 0,
            "no RSA identity may be signed with flags=0 (legacy SHA-1)")
    }

    /// Control: the bare RSA key already works (audit #20).
    @Test func bareRSARequestsSHA2256() {
        #expect(SSHAgentProtocol.signFlags(forKeyType: "ssh-rsa") == SSHAgentProtocol.signFlagRSASHA2256)
    }

    /// Non-RSA identities — including their certificate forms — must keep flags=0;
    /// the SHA-2 flags are RSA-only and an agent may reject them elsewhere.
    @Test(
        arguments: [
            "ssh-ed25519", "ssh-ed25519-cert-v01@openssh.com",
            "ecdsa-sha2-nistp256", "ecdsa-sha2-nistp256-cert-v01@openssh.com",
            "sk-ssh-ed25519@openssh.com",
        ])
    func nonRSAIdentitiesUseNoFlags(_ keyType: String) {
        #expect(SSHAgentProtocol.signFlags(forKeyType: keyType) == 0)
    }
}
