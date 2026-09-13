//
//  ConfigLinter.swift
//  sshconfigmanager
//
//  Static analysis of the SSH config: correctness warnings and security audit.
//

import Foundation

/// A safe, one-click remediation a finding can offer. Kept in the shared finding
/// model (rather than a key-only type) so any analysis pass — config lints today,
/// the key audit now — can attach a fix the UI renders as an inline button.
public enum LintFix: Equatable {
    /// chmod `path` to the POSIX `mode` (e.g. `0o600`). `label` is the button title.
    /// The executor must confine `path` to the granted directory. Safe to apply
    /// inline (reversible, unambiguous target).
    case setPermissions(path: String, mode: Int, label: String)
    /// Delete an orphaned key's file(s). Destructive — the UI must confirm and the
    /// executor backs up first. Either path may be nil (a key can lack a `.pub`).
    case deleteOrphanedKey(privateKeyPath: String?, publicKeyPath: String?, name: String)
    /// Offer to generate a modern replacement for a weak key, carrying the original's
    /// comment so it can be pre-filled. Drives a navigation, not an inline mutation.
    case generateReplacement(comment: String, originalName: String)
    /// Request sandbox access to the directory containing `target` — the resolved
    /// destination of a symlinked config/Include that lives outside every granted
    /// folder (e.g. a dotfiles repo). Drives an NSOpenPanel, not an inline mutation.
    case grantSymlinkAccess(target: URL)
    /// Move a `Host *` block to the end of its file. ssh uses the first value it
    /// finds for each setting, so a `Host *` placed before other `Host` blocks wins
    /// over anything those later blocks try to override — it only behaves as a
    /// fallback default when it's last.
    case moveWildcardLast(blockID: HostBlock.ID)
}

public struct LintFinding: Identifiable, Equatable {
    public enum Severity: Int, Comparable {
        case info, warning, error
        public static func < (lhs: Severity, rhs: Severity) -> Bool { lhs.rawValue < rhs.rawValue }

        public var label: String {
            switch self {
            case .info: return "Info"
            case .warning: return "Warning"
            case .error: return "Error"
            }
        }
        public var symbol: String {
            switch self {
            case .info: return "info.circle"
            case .warning: return "exclamationmark.triangle"
            case .error: return "xmark.octagon"
            }
        }
    }

    public let id = UUID()
    public let severity: Severity
    /// The host the finding belongs to, or nil for file-wide and key findings.
    public let blockID: HostBlock.ID?
    public let title: String
    public let detail: String
    /// An optional one-click remediation (e.g. fix file permissions). nil for
    /// purely informational findings.
    public let fix: LintFix?

    public init(
        severity: Severity, blockID: HostBlock.ID?, title: String,
        detail: String, fix: LintFix? = nil
    ) {
        self.severity = severity
        self.blockID = blockID
        self.title = title
        self.detail = detail
        self.fix = fix
    }

    public static func == (lhs: LintFinding, rhs: LintFinding) -> Bool {
        lhs.severity == rhs.severity && lhs.blockID == rhs.blockID
            && lhs.title == rhs.title && lhs.detail == rhs.detail && lhs.fix == rhs.fix
    }
}

public enum ConfigLinter {
    /// Substrings that flag weak/legacy crypto in Ciphers/MACs/KexAlgorithms.
    private static let weakCryptoMarkers = [
        "3des", "arcfour", "blowfish", "cast128", "-cbc",
        "hmac-md5", "hmac-sha1", "-96",
        "diffie-hellman-group1-sha1", "diffie-hellman-group14-sha1",
        "diffie-hellman-group-exchange-sha1",
    ]

    /// Keywords removed/renamed in modern OpenSSH.
    private static let deprecatedKeywords: Set<String> = [
        "protocol", "cipher", "rsaauthentication", "rhostsrsaauthentication",
        "compressionlevel", "useroaming", "gssapikeyexchange",
        "challengeresponseauthentication", "useprivilegedport",
    ]

    /// Runs all checks. `existingFiles` is the set of file names present in the
    /// SSH folder, used to flag IdentityFiles that don't exist there. `graph`, when
    /// supplied, gives the wildcard-position check the real Include-spliced stream
    /// order; without it, that check falls back to `documents`' flat load order.
    public static func lint(
        _ documents: [SSHConfigDocument], existingFiles: Set<String> = [], graph: ConfigGraph? = nil
    ) -> [LintFinding] {
        var findings: [LintFinding] = []
        let linearized = graph?.linearizedBlocks ?? documents.flatMap(\.blocks)
        findings.append(contentsOf: duplicateAliasFindings(documents))
        findings.append(contentsOf: wildcardPositionFindings(linearized))
        findings.append(contentsOf: shadowedAcrossBlocksFindings(linearized))

        for document in documents {
            for block in document.blocks where block.kind == .host {
                findings.append(contentsOf: lintBlock(block, existingFiles: existingFiles))
                findings.append(contentsOf: shadowedWithinBlockFindings(block))
            }
        }
        return findings.sorted { $0.severity > $1.severity }
    }

    private static func shadowedWithinBlockFindings(_ block: HostBlock) -> [LintFinding] {
        var winningValueByKeyword: [String: String] = [:]
        var findings: [LintFinding] = []
        for directive in block.body.compactMap(\.directive) {
            let key = directive.canonicalKeyword
            guard !KeywordRegistry.isRepeatable(key) else { continue }
            let value = directive.value.trimmingCharacters(in: .whitespaces)
            guard let winningValue = winningValueByKeyword[key] else {
                winningValueByKeyword[key] = value
                continue
            }
            guard winningValue != value else { continue }
            findings.append(
                LintFinding(
                    severity: .warning, blockID: block.id,
                    title: "\(directive.keyword) is set twice in \(block.title)",
                    detail: "ssh keeps the first value it reads, so this host uses “\(winningValue)” and “\(value)” "
                        + "never applies. Delete the line that does not apply, or change the first one. Run "
                        + "`ssh -G \(block.primaryAlias ?? "<host>")` to see the value that survives."))
        }
        return findings
    }

    private static func shadowedAcrossBlocksFindings(_ blocks: [HostBlock]) -> [LintFinding] {
        var findings: [LintFinding] = []
        var winnerByAliasAndKeyword: [String: (value: String, block: HostBlock)] = [:]
        for block in blocks where block.kind == .host {
            for alias in block.concreteAliases {
                for directive in block.body.compactMap(\.directive) {
                    let key = directive.canonicalKeyword
                    guard !KeywordRegistry.isRepeatable(key) else { continue }
                    let value = directive.value.trimmingCharacters(in: .whitespaces)
                    let slot = alias.lowercased() + "\u{1}" + key
                    guard let winner = winnerByAliasAndKeyword[slot] else {
                        winnerByAliasAndKeyword[slot] = (value, block)
                        continue
                    }
                    guard winner.value != value, winner.block.id != block.id else { continue }
                    findings.append(
                        LintFinding(
                            severity: .warning, blockID: block.id,
                            title: "\(directive.keyword) for “\(alias)” is already set earlier",
                            detail: "\(winner.block.sourceURL.lastPathComponent) sets \(directive.keyword) "
                                + "“\(winner.value)” for this host first, and ssh keeps the first value it reads, so "
                                + "“\(value)” never applies. Run `ssh -G \(alias)` to see the value that survives."))
                }
            }
        }
        return findings
    }

    /// Flags any `Host *` block that isn't the last `Host` block in the linearized
    /// stream. ssh keeps the first value it finds for each keyword, so a `Host *`
    /// ahead of other `Host` blocks silently wins over anything they try to
    /// override — it only behaves as a fallback default when placed last.
    private static func wildcardPositionFindings(_ blocks: [HostBlock]) -> [LintFinding] {
        let hostBlocks = blocks.filter { $0.kind == .host }
        var findings: [LintFinding] = []
        for (index, block) in hostBlocks.enumerated() where block.isWildcard {
            guard hostBlocks[(index + 1)...].contains(where: { !$0.isWildcard }) else { continue }
            findings.append(
                LintFinding(
                    severity: .warning, blockID: block.id,
                    title: "Host * is not the last block",
                    detail: "ssh uses the first value it finds for each setting, so this Host * silently wins over "
                        + "anything the Host blocks after it try to override. Move it to the end of the file so it "
                        + "only fills in defaults for settings those hosts don't already set.",
                    fix: .moveWildcardLast(blockID: block.id)))
        }
        return findings
    }

    private static func duplicateAliasFindings(_ documents: [SSHConfigDocument]) -> [LintFinding] {
        var firstSeen: [String: HostBlock.ID] = [:]
        var findings: [LintFinding] = []
        for document in documents {
            for block in document.blocks where block.kind == .host {
                for alias in block.concreteAliases {
                    if firstSeen[alias] != nil {
                        findings.append(
                            LintFinding(
                                severity: .warning, blockID: block.id,
                                title: "Duplicate host alias “\(alias)”",
                                detail:
                                    "Defined more than once. ssh uses the first match, so later blocks for this alias are partly shadowed."
                            ))
                    } else {
                        firstSeen[alias] = block.id
                    }
                }
            }
        }
        return findings
    }

    private static func lintBlock(_ block: HostBlock, existingFiles: Set<String>) -> [LintFinding] {
        var findings: [LintFinding] = []

        func add(_ severity: LintFinding.Severity, _ title: String, _ detail: String) {
            findings.append(LintFinding(severity: severity, blockID: block.id, title: title, detail: detail))
        }

        let ignoredUnknownPatterns = block.values(for: "IgnoreUnknown")
            .flatMap { $0.split(whereSeparator: { $0 == " " || $0 == "," }).map(String.init) }

        for directive in block.body.compactMap(\.directive) {
            let key = directive.canonicalKeyword
            let value = directive.value.trimmingCharacters(in: .whitespaces)
            let lowerValue = value.lowercased()

            if deprecatedKeywords.contains(key) {
                add(
                    .warning, "Deprecated option “\(directive.keyword)” in \(block.title)",
                    "This keyword is obsolete in current OpenSSH and is ignored or unsupported.")
            } else if KeywordRegistry.info(for: key) == nil,
                !EffectiveConfigResolver.matchesHostPatterns(ignoredUnknownPatterns, target: key)
            {
                add(
                    .error, "Unknown option “\(directive.keyword)” in \(block.title)",
                    "ssh does not know this keyword. It stops with “Bad configuration option: "
                        + "\(key)” and exit status 255 before it opens a connection, so every host that reads "
                        + "this file fails, not just this one. Correct the spelling, or list it in IgnoreUnknown.")
            }

            switch key {
            case "stricthostkeychecking" where lowerValue == "no" || lowerValue == "off":
                add(
                    .warning, "Host key checking disabled in \(block.title)",
                    "StrictHostKeyChecking \(value) silently trusts new and changed host keys, exposing you to man-in-the-middle attacks. Prefer accept-new."
                )
            case "port":
                if Int(value) == nil {
                    add(.error, "Invalid Port in \(block.title)", "“\(value)” is not a number.")
                }
            case "hostname" where value.isEmpty:
                add(.warning, "Empty HostName in \(block.title)", "HostName has no value.")
            case "ciphers", "macs", "kexalgorithms":
                for marker in weakCryptoMarkers where lowerValue.contains(marker) {
                    add(
                        .warning, "Weak algorithm in \(directive.keyword) (\(block.title))",
                        "“\(marker)” is considered weak or legacy. Consider removing it from \(directive.keyword).")
                    break
                }
            case "identityfile":
                if let name = identityFileName(value), !existingFiles.isEmpty,
                    !existingFiles.contains(name), !existingFiles.contains(name + ".pub")
                {
                    add(
                        .info, "IdentityFile may be missing in \(block.title)",
                        "“\(value)” wasn’t found in your SSH folder. It may live elsewhere, or the path may be stale.")
                }
            default:
                break
            }
        }
        return findings
    }

    /// The file name of an IdentityFile path if it points inside ~/.ssh, else nil.
    private static func identityFileName(_ path: String) -> String? {
        let expanded = (path as NSString).expandingTildeInPath
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let sshDir = home + "/.ssh/"
        guard expanded.hasPrefix(sshDir) else { return nil }
        return String(expanded.dropFirst(sshDir.count))
    }
}
