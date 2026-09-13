//
//  FuzzyMatch.swift
//  sshconfigmanager
//
//  Lightweight subsequence fuzzy matching for the command palette.
//

import Foundation

public enum FuzzyMatch {
    /// Returns a score if every character of `query` appears in order within
    /// `candidate` (case-insensitive), else nil. Higher is better; contiguous
    /// runs and earlier matches score higher. An empty query matches with score 0.
    public static func score(query: String, candidate: String) -> Int? {
        match(query: query, candidate: candidate)?.score
    }

    /// Like `score`, but also reports *which* `candidate` character offsets the
    /// query consumed, so a UI can bold the matched run (à la VS Code / JetBrains).
    /// Offsets index into `candidate`'s characters (NOT UTF-16); the caller maps to
    /// display ranges. An empty query matches with score 0 and no indices.
    public static func match(query: String, candidate: String) -> (score: Int, matchedIndices: [Int])? {
        let q = Array(query.lowercased())
        let c = Array(candidate.lowercased())
        if q.isEmpty { return (0, []) }
        if q.count > c.count { return nil }

        var score = 0
        var qi = 0
        var lastMatch = -1
        var matched: [Int] = []
        matched.reserveCapacity(q.count)
        for (ci, char) in c.enumerated() {
            guard qi < q.count, char == q[qi] else { continue }
            // Reward contiguous matches and matches at word starts.
            if lastMatch == ci - 1 { score += 5 } else { score += 1 }
            if ci == 0 || c[ci - 1] == "." || c[ci - 1] == "-" || c[ci - 1] == "_" { score += 3 }
            lastMatch = ci
            matched.append(ci)
            qi += 1
            if qi == q.count { break }
        }
        guard qi == q.count else { return nil }
        // Prefer shorter candidates when scores tie.
        return (score - (c.count - q.count) / 8, matched)
    }

    /// Whether `query` fuzzy-matches `candidate`.
    public static func matches(query: String, candidate: String) -> Bool {
        score(query: query, candidate: candidate) != nil
    }

    // MARK: - Typo-tolerant (Levenshtein) matching

    public static func contains(_ needle: String, in haystack: String) -> Bool {
        guard !needle.isEmpty else { return true }
        if haystack.contains(needle) { return true }
        let tolerance = max(1, needle.count / 4)
        let needleChars = Array(needle)

        for token in haystack.split(whereSeparator: { !$0.isLetter && !$0.isNumber }) {
            let t = String(token)
            if t.contains(needle) { return true }
            if abs(t.count - needle.count) <= tolerance,
                distance(needleChars, Array(t)) <= tolerance
            {
                return true
            }
        }

        // Sliding window over the whole haystack, for needles that straddle separators.
        if needle.count >= 4 {
            let hay = Array(haystack)
            let n = needleChars.count
            if hay.count >= n {
                for start in 0...(hay.count - n) where distance(needleChars, Array(hay[start..<start + n])) <= tolerance
                {
                    return true
                }
            }
        }
        return false
    }

    /// Classic Levenshtein edit distance via a two-row DP.
    public static func distance(_ a: [Character], _ b: [Character]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var prev = Array(0...b.count)
        var cur = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            cur[0] = i
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                cur[j] = Swift.min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + cost)
            }
            swap(&prev, &cur)
        }
        return prev[b.count]
    }

    public static func distance(_ a: String, _ b: String) -> Int { distance(Array(a), Array(b)) }
}
