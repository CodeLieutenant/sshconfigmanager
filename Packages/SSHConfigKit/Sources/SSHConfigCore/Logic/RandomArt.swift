//
//  RandomArt.swift
//  SSHConfigCore
//
//  The OpenSSH "drunken bishop" randomart — the ASCII-art picture of a key
//  fingerprint that `ssh-keygen -lv` prints. It's a recognition aid: the same key
//  always draws the same picture, so a human can eyeball-match a key against one
//  they've seen before. Pure (no crypto): it walks the already-computed SHA-256
//  digest, so it stays unit-testable and matches `ssh-keygen` byte-for-byte.
//

import Foundation

public enum RandomArt {
    // Field dimensions and symbol ramp, verbatim from OpenSSH's sshkey.c.
    private static let fieldX = 17
    private static let fieldY = 9
    private static let symbols = Array(" .o+=*BOX@%&#/^SE")

    /// Renders the randomart for a fingerprint `digest` (e.g. the 32 SHA-256 bytes).
    /// `title` labels the top border (e.g. `"ED25519 256"`), `hashName` the bottom
    /// (e.g. `"SHA256"`). The art field depends only on the digest, so it matches
    /// `ssh-keygen -lv` regardless of the labels.
    public static func drunkenBishop(digest: [UInt8], title: String, hashName: String) -> String {
        let last = symbols.count - 1 // 16: 'E' (end marker)
        var field = Array(repeating: Array(repeating: 0, count: fieldX), count: fieldY)

        var x = fieldX / 2 // 8
        var y = fieldY / 2 // 4
        for byte in digest {
            var input = Int(byte)
            for _ in 0..<4 {
                x += (input & 0x1) != 0 ? 1 : -1
                y += (input & 0x2) != 0 ? 1 : -1
                x = min(max(x, 0), fieldX - 1)
                y = min(max(y, 0), fieldY - 1)
                if field[y][x] < last - 2 { field[y][x] += 1 }
                input >>= 2
            }
        }
        field[fieldY / 2][fieldX / 2] = last - 1 // 'S' start marker
        field[y][x] = last // 'E' end marker

        var lines = [borderLine(label: "[\(title)]")]
        for row in field {
            lines.append("|" + String(row.map { symbols[min($0, last)] }) + "|")
        }
        lines.append(borderLine(label: "[\(hashName)]"))
        return lines.joined(separator: "\n")
    }

    /// A `+---[label]---+` border, centering `label` in `fieldX` dashes the same way
    /// OpenSSH does (left = `(fieldX - len) / 2`, remainder on the right).
    private static func borderLine(label: String) -> String {
        let label = label.count <= fieldX ? label : ""
        let left = (fieldX - label.count) / 2
        let right = fieldX - label.count - left
        return "+" + String(repeating: "-", count: left) + label
            + String(repeating: "-", count: right) + "+"
    }

    /// Recovers the raw digest bytes from a `SHA256:<base64>` fingerprint string
    /// (the form `KeyFingerprint.sha256` produces, with `=` padding stripped), or
    /// nil if it isn't that format.
    public static func digest(fromSHA256Fingerprint fingerprint: String) -> [UInt8]? {
        let prefix = "SHA256:"
        guard fingerprint.hasPrefix(prefix) else { return nil }
        var base64 = String(fingerprint.dropFirst(prefix.count))
        let remainder = base64.count % 4
        if remainder > 0 { base64 += String(repeating: "=", count: 4 - remainder) }
        guard let data = Data(base64Encoded: base64) else { return nil }
        return [UInt8](data)
    }
}
