//
//  ValueCatalog.swift
//  SSHConfigIntelliSense
//
//  The "I know what this keyword means, so I know what goes here" half of the engine.
//  Given a keyword, it returns the candidate values worth offering: the fixed cases
//  from `KeywordRegistry` (yes/no, enumerations), the OpenSSH crypto algorithm sets
//  for the list-of-algorithm keywords, the handful of magic tokens (SSH_AUTH_SOCK,
//  none, …), and document-derived values (Host aliases for ProxyJump).
//
//  Algorithm lists track current OpenSSH (≈9.x) names — including the post-quantum
//  `sntrup761x25519` KEX and the `-etm@openssh.com` MACs — ordered roughly by the
//  preference OpenSSH itself ships, so an empty-prefix completion reads as "the good
//  ones first".
//

import Foundation
import SSHConfigCore

/// One offerable value plus how to describe it.
public struct ValueCandidate: Equatable, Sendable {
    public let value: String
    public let detail: String?
    public let documentation: String?
    public let kind: CompletionKind

    public init(
        value: String, detail: String? = nil, documentation: String? = nil,
        kind: CompletionKind = .value
    ) {
        self.value = value
        self.detail = detail
        self.documentation = documentation
        self.kind = kind
    }
}

public enum ValueCatalog {
    /// Keywords whose value is a comma-separated algorithm list and that accept a
    /// leading `+` / `-` / `^` operator to amend (rather than replace) the default set.
    public static let algorithmListKeywords: Set<String> = [
        "ciphers", "macs", "kexalgorithms", "hostkeyalgorithms",
        "pubkeyacceptedalgorithms", "hostbasedacceptedalgorithms", "casignaturealgorithms",
    ]

    /// True when this keyword's value is a filesystem path, so completion should offer
    /// files/folders from disk rather than (or in addition to) a fixed catalog. Driven
    /// by `KeywordRegistry`'s `.path` field — IdentityFile, CertificateFile,
    /// UserKnownHostsFile, ControlPath, PKCS11Provider, XAuthLocation, … — plus
    /// `IdentityAgent`, whose value is a socket path (alongside its env/none tokens).
    public static func isPathKeyword(_ keyword: String) -> Bool {
        if KeywordRegistry.info(for: keyword)?.field == .path { return true }
        return keyword.lowercased() == "identityagent"
    }

    /// True when an element of this keyword's value is comma-separated (algorithm
    /// lists, auth method lists) rather than whitespace-separated.
    public static func isCommaSeparatedList(_ keyword: String) -> Bool {
        let key = keyword.lowercased()
        return algorithmListKeywords.contains(key)
            || key == "preferredauthentications" || key == "kbdinteractivedevices"
            || key == "canonicaldomains"
    }

    public static func candidates(
        forKeyword keyword: String,
        symbols: DocumentSymbols = .empty
    ) -> [ValueCandidate] {
        let key = keyword.lowercased()

        // Fixed cases from the registry come first: yes/no and enumerations are the
        // most authoritative thing we can say.
        if let info = KeywordRegistry.info(for: keyword) {
            switch info.field {
            case .yesNo:
                return [
                    ValueCandidate(value: "yes", documentation: info.help, kind: .enumCase),
                    ValueCandidate(value: "no", documentation: info.help, kind: .enumCase),
                ]
            case .enumeration(let cases):
                return cases.map { ValueCandidate(value: $0, documentation: info.help, kind: .enumCase) }
            case .string, .integer, .path, .list:
                break // fall through to the keyword-specific catalogs below
            }
        }

        switch key {
        case "ciphers":
            return algorithms(ciphers, label: "cipher")
        case "macs":
            return algorithms(macs, label: "MAC")
        case "kexalgorithms":
            return algorithms(kexAlgorithms, label: "key exchange")
        case "hostkeyalgorithms":
            return algorithms(hostKeyAlgorithms, label: "host-key")
        case "pubkeyacceptedalgorithms", "hostbasedacceptedalgorithms":
            return algorithms(publicKeyAlgorithms, label: "public-key")
        case "casignaturealgorithms":
            return algorithms(caSignatureAlgorithms, label: "CA signature")
        case "preferredauthentications":
            return authMethods.map { ValueCandidate(value: $0, detail: "auth method") }
        case "kbdinteractivedevices":
            return ["pam", "bsdauth", "skey"].map { ValueCandidate(value: $0, detail: "device") }
        case "proxyjump":
            var out: [ValueCandidate] = [
                ValueCandidate(
                    value: "none", detail: "disable",
                    documentation: "Disable a ProxyJump inherited from an earlier match.")
            ]
            out += symbols.hostAliases.map {
                ValueCandidate(
                    value: $0, detail: "host", documentation: "Jump through this host (defined in your config).",
                    kind: .host)
            }
            return out
        case "identityagent":
            return [
                ValueCandidate(
                    value: "SSH_AUTH_SOCK", detail: "env", documentation: "Use the agent socket from the environment."),
                ValueCandidate(value: "none", detail: "disable", documentation: "Do not use an authentication agent."),
            ]
        case "pkcs11provider", "securitykeyprovider":
            return [ValueCandidate(value: "none", detail: "disable")]
        case "ipqos":
            return ipqosClasses.map { ValueCandidate(value: $0.0, detail: $0.1) }
        case "canonicaldomains":
            return [] // user-specific; nothing to suggest
        default:
            return []
        }
    }

    private static func algorithms(_ names: [String], label: String) -> [ValueCandidate] {
        names.map { ValueCandidate(value: $0, detail: label, kind: .algorithm) }
    }

    // MARK: - OpenSSH algorithm sets

    static let ciphers = [
        "chacha20-poly1305@openssh.com",
        "aes128-ctr", "aes192-ctr", "aes256-ctr",
        "aes128-gcm@openssh.com", "aes256-gcm@openssh.com",
        "aes128-cbc", "aes192-cbc", "aes256-cbc", "3des-cbc",
    ]

    static let macs = [
        "hmac-sha2-256-etm@openssh.com", "hmac-sha2-512-etm@openssh.com",
        "umac-128-etm@openssh.com", "umac-64-etm@openssh.com",
        "hmac-sha1-etm@openssh.com",
        "hmac-sha2-256", "hmac-sha2-512",
        "umac-128@openssh.com", "umac-64@openssh.com", "hmac-sha1",
    ]

    static let kexAlgorithms = [
        "sntrup761x25519-sha512@openssh.com", "sntrup761x25519-sha512",
        "mlkem768x25519-sha256",
        "curve25519-sha256", "curve25519-sha256@libssh.org",
        "ecdh-sha2-nistp256", "ecdh-sha2-nistp384", "ecdh-sha2-nistp521",
        "diffie-hellman-group-exchange-sha256",
        "diffie-hellman-group16-sha512", "diffie-hellman-group18-sha512",
        "diffie-hellman-group14-sha256",
    ]

    static let hostKeyAlgorithms = [
        "ssh-ed25519", "ssh-ed25519-cert-v01@openssh.com",
        "sk-ssh-ed25519@openssh.com", "sk-ssh-ed25519-cert-v01@openssh.com",
        "ecdsa-sha2-nistp256", "ecdsa-sha2-nistp384", "ecdsa-sha2-nistp521",
        "ecdsa-sha2-nistp256-cert-v01@openssh.com",
        "sk-ecdsa-sha2-nistp256@openssh.com",
        "rsa-sha2-512", "rsa-sha2-256",
        "rsa-sha2-512-cert-v01@openssh.com", "rsa-sha2-256-cert-v01@openssh.com",
    ]

    static let publicKeyAlgorithms = hostKeyAlgorithms

    static let caSignatureAlgorithms = [
        "ssh-ed25519",
        "ecdsa-sha2-nistp256", "ecdsa-sha2-nistp384", "ecdsa-sha2-nistp521",
        "sk-ssh-ed25519@openssh.com", "sk-ecdsa-sha2-nistp256@openssh.com",
        "rsa-sha2-512", "rsa-sha2-256",
    ]

    static let authMethods = [
        "publickey", "keyboard-interactive", "password",
        "gssapi-with-mic", "hostbased",
    ]

    static let ipqosClasses: [(String, String)] = [
        ("af11", "class"), ("af12", "class"), ("af13", "class"),
        ("af21", "class"), ("af22", "class"), ("af23", "class"),
        ("af31", "class"), ("af32", "class"), ("af33", "class"),
        ("af41", "class"), ("af42", "class"), ("af43", "class"),
        ("cs0", "class"), ("cs1", "class"), ("cs2", "class"), ("cs3", "class"),
        ("cs4", "class"), ("cs5", "class"), ("cs6", "class"), ("cs7", "class"),
        ("ef", "expedited"), ("le", "lower-effort"),
        ("lowdelay", "tos"), ("throughput", "tos"), ("reliability", "tos"),
        ("none", "disable"),
    ]
}
