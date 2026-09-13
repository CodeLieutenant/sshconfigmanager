//
//  HostTemplate.swift
//  sshconfigmanager
//
//  Predefined starting points for new hosts.
//

import Foundation

public struct HostTemplate: Identifiable {
    public let id = UUID()
    public let name: String
    public let detail: String
    public let systemImage: String
    /// Suggested alias for the new Host line.
    public let alias: String
    /// Directives to prefill, in order, as (keyword, value) pairs.
    public let directives: [(String, String)]

    public static let all: [HostTemplate] = [
        .init(
            name: "Basic Server", detail: "HostName, User, Port",
            systemImage: "server.rack", alias: "my-server",
            directives: [("HostName", "example.com"), ("User", "root"), ("Port", "22")]),
        .init(
            name: "Behind a Jump Host", detail: "Reach a private host through a bastion",
            systemImage: "arrow.triangle.branch", alias: "private-host",
            directives: [
                ("HostName", "10.0.0.10"), ("User", "ubuntu"),
                ("ProxyJump", "bastion"),
            ]),
        .init(
            name: "Git Host", detail: "Dedicated key for a git remote",
            systemImage: "arrow.triangle.pull", alias: "github.com",
            directives: [
                ("HostName", "github.com"), ("User", "git"),
                ("IdentityFile", "~/.ssh/id_ed25519"), ("IdentitiesOnly", "yes"),
            ]),
        .init(
            name: "AWS EC2", detail: "EC2 instance with a .pem key",
            systemImage: "cloud", alias: "ec2-instance",
            directives: [
                ("HostName", "ec2-1-2-3-4.compute.amazonaws.com"),
                ("User", "ec2-user"), ("IdentityFile", "~/.ssh/aws-key.pem"),
                ("IdentitiesOnly", "yes"),
            ]),
        .init(
            name: "Hardened", detail: "Strong crypto and safe host-key policy",
            systemImage: "lock.shield", alias: "secure-host",
            directives: [
                ("HostName", "example.com"), ("User", "admin"),
                ("StrictHostKeyChecking", "accept-new"),
                ("KexAlgorithms", "sntrup761x25519-sha512@openssh.com,curve25519-sha256"),
                ("Ciphers", "chacha20-poly1305@openssh.com,aes256-gcm@openssh.com"),
                ("MACs", "hmac-sha2-512-etm@openssh.com,hmac-sha2-256-etm@openssh.com"),
            ]),
    ]
}
