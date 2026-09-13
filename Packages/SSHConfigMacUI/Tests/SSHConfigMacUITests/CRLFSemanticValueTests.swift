//
//  CRLFSemanticValueTests.swift
//  sshconfigmanagerTests
//
//  Reproducers for a family of CRLF bugs. The parser deliberately keeps a CRLF
//  file's trailing `\r` inside `Directive.value` so an unedited document
//  round-trips byte-for-byte (see `SSHConfigParser.parseLine`), which makes two
//  things the *consumer's* responsibility — and several consumers get it wrong:
//
//   1. Reading a value for analysis must strip the `\r` (`HostBlock.firstValue`
//      does; `ConfigLinter` and `KeyAuditor` read `directive.value` raw).
//   2. Writing a value must put the `\r` back (`HostBlock.setValue`,
//      `HostBlock.addDirective` and `HostNaming.renamingFirstAlias` don't), or the
//      edited line silently becomes LF-only and the file ends up mixed-ending.
//
//  Every test here asserts the behaviour a CRLF file *should* get — the same
//  behaviour its LF twin already gets — so each one fails until the consumer is
//  fixed.
//

import Foundation
import SSHConfigCore
import Testing

@testable import SSHConfigMacUI

private let cfgURL = URL(fileURLWithPath: "/tmp/config")

private func parse(_ text: String) -> SSHConfigDocument {
    SSHConfigParser.parse(text, sourceURL: cfgURL)
}

// MARK: - Analysis passes must read the semantic (CR-stripped) value

struct CRLFLinterTests {
    /// `ConfigLinter` parses `Port` with `Int(value)`. On a CRLF file the value is
    /// `"2222\r"`, and `trimmingCharacters(in: .whitespaces)` does not remove `\r`
    /// (that's `.whitespacesAndNewlines`), so every valid port in a CRLF config is
    /// reported as "not a number".
    @Test func crlfPortIsNotReportedInvalid() {
        let findings = ConfigLinter.lint([parse("Host web\r\n    Port 2222\r\n")])
        #expect(
            !findings.contains { $0.title.hasPrefix("Invalid Port") },
            "a valid Port in a CRLF config must not be flagged invalid")
    }

    /// Control: the LF twin is clean today, which is what makes the CRLF case a bug
    /// rather than an intended difference.
    @Test func lfPortIsNotReportedInvalid() {
        let findings = ConfigLinter.lint([parse("Host web\n    Port 2222\n")])
        #expect(!findings.contains { $0.title.hasPrefix("Invalid Port") })
    }

    /// The reverse failure, and the more dangerous one: the
    /// `StrictHostKeyChecking no` warning compares against the exact string `"no"`,
    /// so on a CRLF file (`"no\r"`) the security warning is silently dropped.
    @Test func crlfStrictHostKeyCheckingNoStillWarns() {
        let findings = ConfigLinter.lint([parse("Host web\r\n    StrictHostKeyChecking no\r\n")])
        #expect(
            findings.contains { $0.title.hasPrefix("Host key checking disabled") },
            "StrictHostKeyChecking no must warn regardless of line endings")
    }

    /// `identityFileName` builds a file name out of the raw value, so the `\r`
    /// lands in the name, never matches `existingFiles`, and every host in a CRLF
    /// config gets a spurious "IdentityFile may be missing" note.
    @Test func crlfIdentityFileThatExistsIsNotReportedMissing() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let text = "Host web\r\n    IdentityFile \(home)/.ssh/id_ed25519\r\n"
        let findings = ConfigLinter.lint([parse(text)], existingFiles: ["id_ed25519", "id_ed25519.pub"])
        #expect(
            !findings.contains { $0.title.hasPrefix("IdentityFile may be missing") },
            "an IdentityFile that exists must not be reported missing in a CRLF config")
    }
}

struct CRLFKeyAuditTests {
    private func key(named name: String) -> SSHPublicKey {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return SSHPublicKey(
            publicKeyURL: URL(fileURLWithPath: "\(home)/.ssh/\(name).pub"),
            privateKeyURL: URL(fileURLWithPath: "\(home)/.ssh/\(name)"),
            algorithm: "ssh-ed25519", fingerprint: "SHA256:abc", comment: "me@mac")
    }

    /// `referencedIdentityNames` reads `directive.value` raw, so on a CRLF config
    /// the referenced name is `"work_key\r"` and never matches the key's `name`.
    /// The key is then reported as orphaned — and that finding carries a
    /// `.deleteOrphanedKey` fix, i.e. a one-click delete of a key that IS in use.
    @Test func crlfReferencedKeyIsNotReportedOrphaned() {
        let document = parse("Host web\r\n    IdentityFile ~/.ssh/work_key\r\n")
        let findings = KeyAuditor.audit(
            keys: [KeyAuditor.KeyInput(key: key(named: "work_key"), isEncrypted: true)],
            documents: [document],
            enabled: [.orphan])
        #expect(
            findings.isEmpty,
            "a key referenced by an IdentityFile in a CRLF config must not be reported orphaned")
    }

    /// Control: the same config with LF endings correctly reports nothing.
    @Test func lfReferencedKeyIsNotReportedOrphaned() {
        let document = parse("Host web\n    IdentityFile ~/.ssh/work_key\n")
        let findings = KeyAuditor.audit(
            keys: [KeyAuditor.KeyInput(key: key(named: "work_key"), isEncrypted: true)],
            documents: [document],
            enabled: [.orphan])
        #expect(findings.isEmpty)
    }

    /// And the direct unit: the referenced-name set must hold the bare file name.
    @Test func referencedIdentityNamesStripsCR() {
        let document = parse("Host web\r\n    IdentityFile ~/.ssh/work_key\r\n")
        #expect(KeyAuditor.referencedIdentityNames([document]) == ["work_key"])
    }
}

// MARK: - splitLines must see a CRLF file's trailing newline

struct CRLFSplitLinesTests {
    /// Swift folds `"\r\n"` into a single grapheme cluster, so `hasSuffix("\n")` is
    /// false for every CRLF file. `splitLines` therefore reported
    /// `trailingNewline == false` and kept the trailing empty component as a real
    /// line — a phantom blank at the end of the last block.
    @Test func crlfTrailingNewlineIsDetected() {
        let (lines, trailingNewline) = SSHConfigParser.splitLines("Host web\r\n    HostName x\r\n")
        #expect(trailingNewline, #"a file ending in "\r\n" ends with a newline"#)
        #expect(lines == ["Host web\r", "    HostName x\r"], "no phantom trailing blank line")
    }

    /// Control: LF text was always right.
    @Test func lfTrailingNewlineIsDetected() {
        let (lines, trailingNewline) = SSHConfigParser.splitLines("Host web\n    HostName x\n")
        #expect(trailingNewline)
        #expect(lines == ["Host web", "    HostName x"])
    }

    @Test func crlfWithoutTrailingNewlineIsDetected() {
        let (lines, trailingNewline) = SSHConfigParser.splitLines("Host web\r\n    HostName x")
        #expect(!trailingNewline)
        #expect(lines == ["Host web\r", "    HostName x"])
    }

    /// The phantom line's user-visible symptom: a CRLF document's last block gained a
    /// blank body line, so an appended directive landed after it and the file lost its
    /// final newline.
    @Test func crlfLastBlockHasNoPhantomBlankLine() {
        let document = parse("Host web\r\n    HostName example.com\r\n")
        #expect(document.blocks.count == 1)
        #expect(document.blocks[0].body.count == 1, "the trailing newline is not a blank line")
    }

    /// A line that is nothing but a carriage return is a blank line, not a directive
    /// whose keyword is `"\r"`.
    @Test func bareCarriageReturnLineIsBlank() {
        let document = parse("Host web\r\n\r\n    HostName x\r\n")
        let blanks = document.blocks[0].body.filter { if case .blank = $0 { return true } else { return false } }
        #expect(blanks.count == 1)
        #expect(document.blocks[0].body.compactMap(\.directive).map(\.keyword) == ["HostName"])
    }
}

// MARK: - Edits must preserve the file's line endings

struct CRLFEditFidelityTests {
    /// Editing one directive in a CRLF file must leave the file CRLF. Today
    /// `setValue` stores the new value with no `\r`, so the edited line alone
    /// becomes LF-terminated and the file is left with mixed line endings.
    @Test func editingADirectiveKeepsCRLF() {
        var document = parse("Host web\r\n    HostName old.example.com\r\n    Port 22\r\n")
        document.blocks[0].setValue("new.example.com", for: "HostName")
        #expect(
            SSHConfigSerializer.serialize(document)
                == "Host web\r\n    HostName new.example.com\r\n    Port 22\r\n")
    }

    /// Same for a directive that didn't exist yet — a newly inserted line in a
    /// CRLF file must be CRLF too.
    @Test func addingADirectiveKeepsCRLF() {
        var document = parse("Host web\r\n    HostName example.com\r\n")
        document.blocks[0].setValue("2222", for: "Port")
        #expect(
            SSHConfigSerializer.serialize(document)
                == "Host web\r\n    HostName example.com\r\n    Port 2222\r\n")
    }

    @Test func addDirectiveKeepsCRLF() {
        var document = parse("Host web\r\n    HostName example.com\r\n")
        document.blocks[0].addDirective(keyword: "Compression", value: "yes")
        #expect(
            SSHConfigSerializer.serialize(document)
                == "Host web\r\n    HostName example.com\r\n    Compression yes\r\n")
    }

    /// Control: the LF file is already correct, so the expectation above is just
    /// "behave the same way for both line endings".
    @Test func editingADirectiveKeepsLF() {
        var document = parse("Host web\n    HostName old.example.com\n")
        document.blocks[0].setValue("new.example.com", for: "HostName")
        #expect(SSHConfigSerializer.serialize(document) == "Host web\n    HostName new.example.com\n")
    }

    /// Deleting a directive must not disturb the surviving lines' endings.
    @Test func removingADirectiveKeepsCRLF() {
        var document = parse("Host web\r\n    HostName example.com\r\n    Port 2222\r\n")
        document.blocks[0].setValue(nil, for: "Port")
        #expect(SSHConfigSerializer.serialize(document) == "Host web\r\n    HostName example.com\r\n")
    }
}

struct CRLFHostRenameTests {
    /// `HostNaming.tokenRanges` only treats space/tab as separators, so for the
    /// header value `"web\r"` the single token *includes* the `\r` and replacing it
    /// destroys the carriage return — the `Host` line of a duplicated/renamed host
    /// in a CRLF file loses its CRLF.
    @Test func renamingASinglePatternHeaderKeepsCR() {
        #expect(HostNaming.renamingFirstAlias(in: "web\r", to: "web-copy") == "web-copy\r")
    }

    /// A multi-pattern header keeps the `\r` today (only the first token is
    /// replaced), which is exactly why the single-pattern case is an oversight and
    /// not a decision.
    @Test func renamingAMultiPatternHeaderKeepsCR() {
        #expect(HostNaming.renamingFirstAlias(in: "web bastion\r", to: "web-copy") == "web-copy bastion\r")
    }

    /// The rename must also not smuggle the `\r` into the middle of the value.
    @Test func renamedHeaderHasNoInteriorCR() {
        let renamed = HostNaming.renamingFirstAlias(in: "web\r", to: "web-copy")
        #expect(!renamed.dropLast().contains("\r"))
    }
}
