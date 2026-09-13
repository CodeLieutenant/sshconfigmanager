//
//  TextDiff.swift
//  sshconfigmanager
//
//  A simple line-based unified diff (LCS) for the backup-history view.
//

import Foundation

public enum TextDiff {
    public enum Kind { case context, added, removed }

    public struct Line: Equatable {
        public let kind: Kind
        public let text: String

        public init(kind: Kind, text: String) {
            self.kind = kind
            self.text = text
        }
    }

    /// Produces a unified diff of two texts, line by line.
    public static func diff(old: String, new: String) -> [Line] {
        let a = old.isEmpty ? [] : old.components(separatedBy: "\n")
        let b = new.isEmpty ? [] : new.components(separatedBy: "\n")
        let n = a.count
        let m = b.count

        // lcs[i][j] = length of the longest common subsequence of a[i...] and b[j...].
        var lcs = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        if n > 0 && m > 0 {
            for i in stride(from: n - 1, through: 0, by: -1) {
                for j in stride(from: m - 1, through: 0, by: -1) {
                    lcs[i][j] =
                        a[i] == b[j]
                        ? lcs[i + 1][j + 1] + 1
                        : max(lcs[i + 1][j], lcs[i][j + 1])
                }
            }
        }

        var result: [Line] = []
        var i = 0
        var j = 0
        while i < n && j < m {
            if a[i] == b[j] {
                result.append(Line(kind: .context, text: a[i]))
                i += 1
                j += 1
            } else if lcs[i + 1][j] >= lcs[i][j + 1] {
                result.append(Line(kind: .removed, text: a[i]))
                i += 1
            } else {
                result.append(Line(kind: .added, text: b[j]))
                j += 1
            }
        }
        while i < n {
            result.append(Line(kind: .removed, text: a[i]))
            i += 1
        }
        while j < m {
            result.append(Line(kind: .added, text: b[j]))
            j += 1
        }
        return result
    }

    /// Counts of added and removed lines.
    public static func stat(old: String, new: String) -> (added: Int, removed: Int) {
        let lines = diff(old: old, new: new)
        return (
            lines.filter { $0.kind == .added }.count,
            lines.filter { $0.kind == .removed }.count
        )
    }
}
