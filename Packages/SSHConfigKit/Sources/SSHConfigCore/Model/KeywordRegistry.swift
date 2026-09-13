//
//  KeywordRegistry.swift
//  sshconfigmanager
//
//  Metadata about ssh_config keywords, used to render the structured editor and
//  the searchable "add setting" picker. Sourced from the OpenSSH ssh_config(5)
//  manual page.
//

import Foundation

/// How a keyword's value should be presented and validated in the UI.
public enum FieldKind: Equatable {
    case string
    case integer
    case yesNo // yes / no toggle
    case enumeration([String]) // a fixed set of allowed values
    case path // a file path (offers a file picker)
    case list // whitespace/comma-separated list / may repeat
}

/// Which section of the editor a keyword belongs to.
public enum KeywordCategory: String, CaseIterable {
    case connection = "Connection"
    case identity = "Authentication"
    case forwarding = "Forwarding"
    case security = "Security & Host Keys"
    case advanced = "Advanced"
}

/// Static metadata for a single ssh_config keyword.
public struct KeywordInfo: Equatable {
    public let canonical: String // canonical spelling, e.g. "HostName"
    public let field: FieldKind
    public let category: KeywordCategory
    public let help: String

    public var key: String { canonical.lowercased() }
}

public enum KeywordRegistry {
    public static let all: [KeywordInfo] = [
        // MARK: Connection
        //
        // `ControlMaster`/`ControlPath`/`ControlPersist` (SSH connection multiplexing
        // across separate `ssh` invocations) are recognized/linted but intentionally
        // not enforced by the in-process tunnel engine — they're not applicable to
        // this architecture. The engine already keeps one long-lived in-process
        // connection per tunnel with no `ssh` subprocess to multiplex across, and
        // `TunnelCommandBuilder` already hardcodes `ControlPath=none` in the exported
        // CLI command for exactly this reason.
        .init(
            canonical: "HostName", field: .string, category: .connection,
            help: "The real host name to connect to. May use %h for the name on the Host line."),
        .init(
            canonical: "User", field: .string, category: .connection,
            help: "The user name to log in as."),
        .init(
            canonical: "Port", field: .integer, category: .connection,
            help: "Port to connect to on the remote host. Default 22."),
        .init(
            canonical: "AddressFamily", field: .enumeration(["any", "inet", "inet6"]),
            category: .connection, help: "Address family to use when connecting."),
        .init(
            canonical: "BindAddress", field: .string, category: .connection,
            help: "Local source address to use for the connection."),
        .init(
            canonical: "BindInterface", field: .string, category: .connection,
            help: "Use the address of the named interface as the connection source."),
        .init(
            canonical: "ConnectTimeout", field: .integer, category: .connection,
            help: "Timeout (seconds) for establishing the connection and SSH handshake."),
        .init(
            canonical: "ConnectionAttempts", field: .integer, category: .connection,
            help: "Number of connection attempts before exiting."),
        .init(
            canonical: "ServerAliveInterval", field: .integer, category: .connection,
            help: "Seconds between keepalive messages sent to the server."),
        .init(
            canonical: "ServerAliveCountMax", field: .integer, category: .connection,
            help: "How many keepalives may go unanswered before disconnecting."),
        .init(
            canonical: "TCPKeepAlive", field: .yesNo, category: .connection,
            help: "Send TCP keepalive messages to detect a dead connection."),
        .init(
            canonical: "Compression", field: .yesNo, category: .connection,
            help: "Use compression for the connection."),
        .init(
            canonical: "ProxyJump", field: .string, category: .connection,
            help: "Connect through one or more jump hosts, e.g. user@bastion:22."),
        .init(
            canonical: "ProxyCommand", field: .string, category: .connection,
            help: "Command used to connect to the server instead of a direct socket."),
        .init(
            canonical: "ProxyUseFdpass", field: .yesNo, category: .connection,
            help: "ProxyCommand passes a connected file descriptor back to ssh."),
        .init(
            canonical: "IPQoS", field: .string, category: .connection,
            help: "DSCP / QoS class for the connection (e.g. lowdelay, throughput, af21)."),
        .init(
            canonical: "RequestTTY", field: .enumeration(["no", "yes", "force", "auto"]),
            category: .connection, help: "Whether to request a pseudo-terminal."),
        .init(
            canonical: "SessionType", field: .enumeration(["none", "subsystem", "default"]),
            category: .connection, help: "Request a subsystem, or prevent running a remote command."),
        .init(
            canonical: "RemoteCommand", field: .string, category: .connection,
            help: "Command to run on the remote host after connecting."),
        .init(
            canonical: "LocalCommand", field: .string, category: .connection,
            help: "Command to run locally after connecting (needs PermitLocalCommand)."),
        .init(
            canonical: "PermitLocalCommand", field: .yesNo, category: .connection,
            help: "Allow LocalCommand and the !command escape."),
        .init(
            canonical: "EscapeChar", field: .string, category: .connection,
            help: "Escape character for interactive sessions (default ~)."),
        .init(
            canonical: "StdinNull", field: .yesNo, category: .connection,
            help: "Redirect stdin from /dev/null."),
        .init(
            canonical: "ForkAfterAuthentication", field: .yesNo, category: .connection,
            help: "Go to the background just before command execution."),
        .init(
            canonical: "ControlMaster",
            field: .enumeration(["no", "yes", "ask", "auto", "autoask"]),
            category: .connection, help: "Share multiple sessions over a single network connection."),
        .init(
            canonical: "ControlPath", field: .path, category: .connection,
            help: "Path to the control socket for connection sharing (e.g. ~/.ssh/cm-%r@%h:%p)."),
        .init(
            canonical: "ControlPersist", field: .string, category: .connection,
            help: "Keep the master connection open in the background (yes/no or a duration)."),
        .init(
            canonical: "CanonicalizeHostname",
            field: .enumeration(["no", "yes", "always", "none"]),
            category: .connection, help: "Explicitly canonicalize the host name using DNS."),
        .init(
            canonical: "CanonicalDomains", field: .list, category: .connection,
            help: "Domain suffixes searched when canonicalizing the host name."),
        .init(
            canonical: "CanonicalizeFallbackLocal", field: .yesNo, category: .connection,
            help: "Fail or try a local lookup when canonicalization fails."),
        .init(
            canonical: "CanonicalizeMaxDots", field: .integer, category: .connection,
            help: "Maximum dots in a host name before canonicalization is skipped."),
        .init(
            canonical: "CanonicalizePermittedCNAMEs", field: .list, category: .connection,
            help: "Rules for whether to follow CNAMEs when canonicalizing."),

        // MARK: Authentication
        //
        // A handful of directives below are recognized/linted here but deliberately
        // NOT enforced by the in-process tunnel engine (NIOTunnelEngine/
        // NIOTunnelConnection), because doing so would mean new external
        // dependencies and sandbox entitlements this app doesn't have, or features
        // the vendored NIOSSH fork has no protocol support for at all:
        //   - GSSAPIAuthentication / HostbasedAuthentication / HostbasedAcceptedAlgorithms:
        //     no GSS-API/Kerberos binding exists, and NIOSSH's hostbased auth is an
        //     unimplemented stub (`fatalError`s if reached). `=no` already matches
        //     current behavior (neither is ever offered); `=yes` logs an
        //     "unsupported, ignored" notice (see `CompositeAuthDelegate`).
        //   - PKCS11Provider (smart cards) / SecurityKeyProvider (FIDO2/U2F):
        //     would need PKCS#11 middleware or a CTAP2/HID library plus new
        //     `sk-*` key-type support in the fork, and USB/HID/smartcard sandbox
        //     entitlements Apple hasn't granted this app.
        //   - EnableSSHKeysign: only meaningful for hostbased auth, which isn't
        //     implemented — moot.
        // See Vendor/PATCH.md for the vendored-fork patches that *do* land support
        // for related directives (host-key verification policy, KexAlgorithms/
        // HostKeyAlgorithms, CertificateFile, PasswordAuthentication).
        .init(
            canonical: "IdentityFile", field: .path, category: .identity,
            help: "Private key file for public-key authentication. May be repeated."),
        .init(
            canonical: "IdentitiesOnly", field: .yesNo, category: .identity,
            help: "Use only the identities configured here, even if the agent offers more."),
        .init(
            canonical: "IdentityAgent", field: .path, category: .identity,
            help: "Socket used to talk to the authentication agent (or SSH_AUTH_SOCK / none)."),
        .init(
            canonical: "AddKeysToAgent", field: .enumeration(["no", "yes", "ask", "confirm"]),
            category: .identity, help: "Automatically add keys to ssh-agent on use."),
        .init(
            canonical: "UseKeychain", field: .yesNo, category: .identity,
            help: "On macOS, store and retrieve the key's passphrase from the Keychain."),
        .init(
            canonical: "CertificateFile", field: .path, category: .identity,
            help: "Certificate file used for authentication. May be repeated."),
        .init(
            canonical: "PubkeyAuthentication",
            field: .enumeration(["yes", "no", "unbound", "host-bound"]),
            category: .identity, help: "Try public-key authentication."),
        .init(
            canonical: "PasswordAuthentication", field: .yesNo, category: .identity,
            help: "Allow password authentication."),
        .init(
            canonical: "KbdInteractiveAuthentication", field: .yesNo, category: .identity,
            help: "Allow keyboard-interactive authentication."),
        .init(
            canonical: "KbdInteractiveDevices", field: .list, category: .identity,
            help: "Methods to use for keyboard-interactive authentication."),
        .init(
            canonical: "PreferredAuthentications", field: .list, category: .identity,
            help: "Order of authentication methods to try (comma-separated)."),
        .init(
            canonical: "NumberOfPasswordPrompts", field: .integer, category: .identity,
            help: "Number of password prompts before giving up."),
        .init(
            canonical: "BatchMode", field: .yesNo, category: .identity,
            help: "Disable all interactive prompts (passwords, host key confirmation)."),
        .init(
            canonical: "GSSAPIAuthentication", field: .yesNo, category: .identity,
            help: "Allow GSSAPI-based authentication."),
        .init(
            canonical: "GSSAPIDelegateCredentials", field: .yesNo, category: .identity,
            help: "Forward (delegate) GSSAPI credentials to the server."),
        .init(
            canonical: "HostbasedAuthentication", field: .yesNo, category: .identity,
            help: "Try rhosts-based authentication with public keys."),
        .init(
            canonical: "HostbasedAcceptedAlgorithms", field: .list, category: .identity,
            help: "Signature algorithms offered for host-based authentication."),
        .init(
            canonical: "PKCS11Provider", field: .path, category: .identity,
            help: "PKCS#11 shared library to provide keys (or none)."),
        .init(
            canonical: "SecurityKeyProvider", field: .path, category: .identity,
            help: "Library path for FIDO/security-key (sk-) keys."),
        .init(
            canonical: "EnableSSHKeysign", field: .yesNo, category: .identity,
            help: "Enable the ssh-keysign helper for host-based authentication."),

        // MARK: Forwarding
        //
        // `ForwardAgent` isn't enforced yet either, but unlike the X11 directives
        // below it's a real gap, not an architecture mismatch: enforcing it means
        // implementing SSH agent-forwarding to the remote server (the
        // `auth-agent@openssh.com` channel type) — a genuinely new protocol
        // capability, scoped as its own follow-up rather than bundled here.
        .init(
            canonical: "ForwardAgent", field: .yesNo, category: .forwarding,
            help: "Forward the authentication agent to the remote host."),
        // `ForwardX11`/`ForwardX11Trusted`/`ForwardX11Timeout`: not applicable to
        // this architecture — the engine forwards TCP ports/streams, not X11
        // display sockets, and there's no X server integration of any kind.
        .init(
            canonical: "ForwardX11", field: .yesNo, category: .forwarding,
            help: "Forward X11 connections over the secure channel."),
        .init(
            canonical: "ForwardX11Trusted", field: .yesNo, category: .forwarding,
            help: "Give remote X11 clients full access to the local display."),
        .init(
            canonical: "ForwardX11Timeout", field: .string, category: .forwarding,
            help: "Timeout for untrusted X11 forwarding (e.g. 20m)."),
        .init(
            canonical: "LocalForward", field: .list, category: .forwarding,
            help: "Forward a local port to a remote address, e.g. 8080 localhost:80. May repeat."),
        .init(
            canonical: "RemoteForward", field: .list, category: .forwarding,
            help: "Forward a remote port to a local address. May repeat."),
        .init(
            canonical: "DynamicForward", field: .string, category: .forwarding,
            help: "Set up a local SOCKS proxy on the given port. May repeat."),
        .init(
            canonical: "GatewayPorts", field: .yesNo, category: .forwarding,
            help: "Allow remote hosts to connect to locally forwarded ports."),
        .init(
            canonical: "ClearAllForwardings", field: .yesNo, category: .forwarding,
            help: "Clear all forwardings from the configuration and command line."),
        .init(
            canonical: "ExitOnForwardFailure", field: .yesNo, category: .forwarding,
            help: "Terminate the connection if a forwarding cannot be set up."),
        .init(
            canonical: "PermitRemoteOpen", field: .list, category: .forwarding,
            help: "Destinations permitted for remote forwarding (host:port, any, none)."),
        .init(
            canonical: "Tunnel", field: .enumeration(["no", "yes", "point-to-point", "ethernet"]),
            category: .forwarding, help: "Request tun-device (layer 2/3) forwarding."),
        .init(
            canonical: "TunnelDevice", field: .string, category: .forwarding,
            help: "tun devices to open, local_tun[:remote_tun]."),
        .init(
            canonical: "StreamLocalBindMask", field: .string, category: .forwarding,
            help: "umask for Unix-domain socket files created for forwarding."),
        .init(
            canonical: "StreamLocalBindUnlink", field: .yesNo, category: .forwarding,
            help: "Remove an existing Unix-domain socket before creating a new one."),

        // MARK: Security & Host Keys
        .init(
            canonical: "StrictHostKeyChecking",
            field: .enumeration(["yes", "accept-new", "no", "off", "ask"]),
            category: .security, help: "How to handle unknown or changed host keys."),
        .init(
            canonical: "CheckHostIP", field: .yesNo, category: .security,
            help: "Also check the host IP in known_hosts, not just the name."),
        .init(
            canonical: "UserKnownHostsFile", field: .list, category: .security,
            help: "User host-key database file(s)."),
        .init(
            canonical: "GlobalKnownHostsFile", field: .list, category: .security,
            help: "System-wide host-key database file(s)."),
        .init(
            canonical: "HashKnownHosts", field: .yesNo, category: .security,
            help: "Hash host names and addresses written to known_hosts."),
        .init(
            canonical: "KnownHostsCommand", field: .string, category: .security,
            help: "Command run to obtain the list of host keys."),
        .init(
            canonical: "VerifyHostKeyDNS", field: .enumeration(["no", "yes", "ask"]),
            category: .security, help: "Verify the host key using DNS SSHFP records."),
        .init(
            canonical: "UpdateHostKeys", field: .enumeration(["no", "yes", "ask"]),
            category: .security, help: "Accept additional host keys from the server after auth."),
        .init(
            canonical: "RevokedHostKeys", field: .path, category: .security,
            help: "File listing revoked host public keys."),
        .init(
            canonical: "HostKeyAlias", field: .string, category: .security,
            help: "Alias used instead of the real host name in the key database."),
        .init(
            canonical: "HostKeyAlgorithms", field: .list, category: .security,
            help: "Host-key signature algorithms, in preference order."),
        .init(
            canonical: "Ciphers", field: .list, category: .security,
            help: "Allowed ciphers, in preference order. Prefix with +/-/^ to adjust the default."),
        .init(
            canonical: "MACs", field: .list, category: .security,
            help: "Allowed MAC algorithms, in preference order. Use etm variants for encrypt-then-MAC."),
        .init(
            canonical: "KexAlgorithms", field: .list, category: .security,
            help: "Allowed key-exchange algorithms, in preference order."),
        .init(
            canonical: "PubkeyAcceptedAlgorithms", field: .list, category: .security,
            help: "Signature algorithms accepted for public-key authentication."),
        .init(
            canonical: "CASignatureAlgorithms", field: .list, category: .security,
            help: "Algorithms allowed for certificate-authority signatures."),
        .init(
            canonical: "FingerprintHash", field: .enumeration(["sha256", "md5"]),
            category: .security, help: "Hash algorithm used when displaying key fingerprints."),
        .init(
            canonical: "RequiredRSASize", field: .integer, category: .security,
            help: "Minimum accepted RSA key size in bits (default 1024)."),
        .init(
            canonical: "RekeyLimit", field: .string, category: .security,
            help: "Max data and/or time before the session key is renegotiated (e.g. 1G 1h)."),
        .init(
            canonical: "NoHostAuthenticationForLocalhost", field: .yesNo, category: .security,
            help: "Skip host authentication for loopback addresses."),
        .init(
            canonical: "VisualHostKey", field: .yesNo, category: .security,
            help: "Print an ASCII-art fingerprint of the host key on connect."),

        // MARK: Advanced
        .init(
            canonical: "LogLevel",
            field: .enumeration([
                "QUIET", "FATAL", "ERROR", "INFO", "VERBOSE",
                "DEBUG", "DEBUG1", "DEBUG2", "DEBUG3",
            ]),
            category: .advanced, help: "Verbosity of ssh's logging."),
        .init(
            canonical: "SendEnv", field: .list, category: .advanced,
            help: "Environment variables to send to the server. May repeat."),
        .init(
            canonical: "SetEnv", field: .list, category: .advanced,
            help: "Environment variables (NAME=value) to set on the server. May repeat."),
        .init(
            canonical: "Include", field: .path, category: .advanced,
            help: "Include other configuration file(s). May repeat."),
        .init(
            canonical: "Tag", field: .string, category: .advanced,
            help: "Tag name that a later Match tagged directive can select."),
        .init(
            canonical: "IgnoreUnknown", field: .list, category: .advanced,
            help: "Pattern list of unknown options to ignore rather than error on."),
        .init(
            canonical: "XAuthLocation", field: .path, category: .advanced,
            help: "Full path to the xauth program."),
        .init(
            canonical: "ChannelTimeout", field: .list, category: .connection,
            help: "Close an inactive channel after an interval, as type=interval pairs."),
        .init(
            canonical: "RefuseConnection", field: .yesNo, category: .connection,
            help: "Refuse the connection at once. Use it in a Match block to block a host."),
        .init(
            canonical: "NoHostAuthenticationForProxyCommand", field: .yesNo, category: .security,
            help: "Skip host key checking when the connection goes through a ProxyCommand."),
        .init(
            canonical: "ObscureKeystrokeTiming", field: .string, category: .security,
            help: "Hide inter-keystroke timings from a network observer, or set the interval."),
        .init(
            canonical: "WarnWeakCrypto", field: .yesNo, category: .security,
            help: "Warn when the connection negotiates a weak algorithm."),
        .init(
            canonical: "EnableEscapeCommandline", field: .yesNo, category: .advanced,
            help: "Allow the ~C escape to open a command line."),
        .init(
            canonical: "LogVerbose", field: .list, category: .advanced,
            help: "Force verbose logging for matching file:function:line patterns."),
        .init(
            canonical: "SyslogFacility",
            field: .enumeration([
                "DAEMON", "USER", "AUTH", "LOCAL0", "LOCAL1", "LOCAL2",
                "LOCAL3", "LOCAL4", "LOCAL5", "LOCAL6", "LOCAL7",
            ]), category: .advanced,
            help: "The syslog facility ssh logs under."),
        .init(
            canonical: "VersionAddendum", field: .string, category: .advanced,
            help: "Extra text appended to the SSH protocol banner."),
    ]

    private static let byCanonical: [String: KeywordInfo] = {
        Dictionary(uniqueKeysWithValues: all.map { ($0.key, $0) })
    }()

    /// Looks up metadata for a keyword, case-insensitively.
    public static func info(for keyword: String) -> KeywordInfo? {
        byCanonical[keyword.lowercased()]
    }

    /// The known keywords belonging to a category, in display order.
    public static func keywords(in category: KeywordCategory) -> [KeywordInfo] {
        all.filter { $0.category == category }
    }

    /// Keywords that may legitimately appear multiple times in a block.
    public static let repeatable: Set<String> = [
        "identityfile", "certificatefile", "localforward", "remoteforward",
        "dynamicforward", "include", "sendenv", "setenv",
    ]

    public static func isRepeatable(_ keyword: String) -> Bool {
        repeatable.contains(keyword.lowercased())
    }

    /// Whether a keyword's value is a filesystem path (its metadata `field` is
    /// `.path`), e.g. `IdentityFile`, `Include`, `ControlPath`. Used to decide
    /// path-aware quoting. Unknown keywords are treated as non-paths.
    public static func isPath(_ keyword: String) -> Bool {
        info(for: keyword)?.field == .path
    }

    /// Known keywords matching a search query (over name, help, and category),
    /// excluding the given lowercased keys. Powers the "Add Setting" picker.
    public static func search(_ query: String, excluding: Set<String> = []) -> [KeywordInfo] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        return all.filter { info in
            guard !excluding.contains(info.key) else { return false }
            guard !q.isEmpty else { return true }
            return info.canonical.lowercased().contains(q)
                || info.help.lowercased().contains(q)
                || info.category.rawValue.lowercased().contains(q)
        }
    }

    /// The section an arbitrary keyword belongs to. Known keywords use their
    /// registered category; unknown keywords are placed by name heuristics so that
    /// e.g. a future `ForwardSomething` still lands under Forwarding.
    public static func category(for keyword: String) -> KeywordCategory {
        if let info = info(for: keyword) { return info.category }
        let key = keyword.lowercased()
        if key.hasPrefix("forward") || key.contains("forward") || key.contains("tunnel") {
            return .forwarding
        }
        if key.hasPrefix("proxy") || key.hasPrefix("canonical") || key.hasPrefix("control")
            || key.contains("alive") || key.contains("connect")
        {
            return .connection
        }
        if key.contains("cipher") || key.contains("kex") || key.contains("mac")
            || key.contains("hostkey") || key.contains("knownhosts") || key.contains("algorithm")
            || key.contains("fingerprint") || key.contains("rekey")
        {
            return .security
        }
        if key.contains("auth") || key.contains("identity") || key.contains("pubkey")
            || key.contains("password") || key.contains("kbd") || key.contains("gssapi")
            || key.contains("key")
        {
            return .identity
        }
        return .advanced
    }
}
