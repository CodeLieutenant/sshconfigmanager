//
//  ParserPropertyTests.swift
//  sshconfigmanagerTests
//
//  Property-based + fuzz + golden tests for the lossless ssh_config parser.
//
//  The core invariant: for ANY input string, `serialize(parse(text))` reproduces
//  the input byte-for-byte. Rather than asserting it on a handful of examples,
//  these generate thousands of inputs (both config-shaped and arbitrary) from a
//  seeded RNG, so failures are reproducible from the printed seed.
//

import Foundation
import SSHConfigCore
import Testing

/// A small deterministic RNG (xorshift64*) so property failures reproduce from the
/// seed instead of being flaky.
private struct SeededRNG: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed == 0 ? 0x9E37_79B9_7F4A_7C15 : seed }
    mutating func next() -> UInt64 {
        state ^= state >> 12
        state ^= state << 25
        state ^= state >> 27
        return state &* 0x2545_F491_4F6C_DD1D
    }
}

private let cfgURL = URL(fileURLWithPath: "/tmp/config")
private func parse(_ t: String) -> SSHConfigDocument { SSHConfigParser.parse(t, sourceURL: cfgURL) }
private func serialize(_ d: SSHConfigDocument) -> String { SSHConfigSerializer.serialize(d) }
private func roundTrip(_ t: String) -> String { serialize(parse(t)) }

// MARK: - Generators

private enum Gen {
    static let keywords = [
        "HostName", "User", "Port", "IdentityFile", "ProxyJump",
        "ForwardAgent", "Compression", "StrictHostKeyChecking", "Ciphers",
    ]
    static let indents = ["", "  ", "    ", "\t", "\t  "]
    static let separators = [" ", "  ", "=", " = ", "= ", " =", "\t"]
    static let trailings = ["", " ", "   ", "\t"]
    static let values = [
        "example.com", "10.0.0.1", "22", "~/.ssh/id_ed25519", "yes",
        "no", "accept-new", "a,b,c", "bastion", "",
    ]

    static func pick<T>(_ xs: [T], _ rng: inout SeededRNG) -> T { xs[Int(rng.next() % UInt64(xs.count))] }

    /// A plausible-but-randomized ssh_config (exercises headers, indentation,
    /// separators, leading comments, blank lines, Match blocks).
    static func configText(_ rng: inout SeededRNG) -> String {
        let lineCount = Int(rng.next() % 25)
        var lines: [String] = []
        for _ in 0..<lineCount {
            switch rng.next() % 6 {
            case 0: lines.append(pick(indents, &rng)) // blank-ish
            case 1: lines.append("#" + pick(["", " note", " a=b", "\tx"], &rng)) // comment
            case 2: lines.append("Host " + pick(["a", "*.x", "a b", "git"], &rng)) // header
            case 3: lines.append("Match " + pick(["all", "host a", "final"], &rng)) // match header
            default: // directive
                lines.append(
                    pick(indents, &rng) + pick(keywords, &rng)
                        + pick(separators, &rng) + pick(values, &rng) + pick(trailings, &rng))
            }
        }
        let body = lines.joined(separator: "\n")
        return (rng.next() % 2 == 0) ? body + "\n" : body // sometimes a trailing newline
    }

    /// Arbitrary text: a mix of structurally significant characters and random
    /// (valid) unicode scalars — true fuzzing of the line splitter/parser.
    static func arbitraryText(_ rng: inout SeededRNG) -> String {
        let alphabet: [Character] = [
            "\n", " ", "\t", "#", "=", "H", "o", "s", "t",
            "M", "a", "c", "h", "x", "1", "\r", "é", "界", "🔑", ".",
        ]
        let n = Int(rng.next() % 60)
        var out = ""
        for _ in 0..<n {
            if rng.next() % 8 == 0 {
                // occasionally a fully random scalar (skip invalid/surrogate ranges)
                let v = UInt32(rng.next() % 0x110000)
                if let scalar = Unicode.Scalar(v) { out.unicodeScalars.append(scalar) }
            } else {
                out.append(alphabet[Int(rng.next() % UInt64(alphabet.count))])
            }
        }
        return out
    }
}

struct ParserRoundTripPropertyTests {

    @Test func losslessOnGeneratedConfigs() {
        for seed in UInt64(1)...800 {
            var rng = SeededRNG(seed: seed)
            let text = Gen.configText(&rng)
            #expect(roundTrip(text) == text, "round-trip differed for config seed \(seed)")
        }
    }

    @Test func losslessOnArbitraryText() {
        for seed in UInt64(1)...800 {
            var rng = SeededRNG(seed: seed &* 2_654_435_761)
            let text = Gen.arbitraryText(&rng)
            #expect(roundTrip(text) == text, "round-trip differed for arbitrary seed \(seed)")
        }
    }

    @Test func losslessOnPathologicalInputs() {
        let cases = [
            "", "\n", "\n\n\n", " ", "   ", "\t", "\t\t  ",
            "Host", "Host ", "Match", "=", "==", "  =  ",
            "Host a\n  HostName b", // no trailing newline
            "Host a\r\n  User b\r\n", // CRLF
            "# only a comment",
            "# label\nHost web\n  HostName w\n", // comment attaches to host
            "# label\n\nHost web\n", // blank breaks the attachment
            "\u{FEFF}Host bom\n", // leading BOM
            "Port    22    ", // padded separator + trailing
            "Höst ünïcode 界\n", // unicode
            String(repeating: "x", count: 5000), // one very long line
            "Host a\nHost a\nHost a\n", // duplicate headers
        ]
        for text in cases {
            #expect(roundTrip(text) == text, "round-trip differed for: \(text.debugDescription)")
        }
    }

    @Test func parseNeverCrashesOnRandomBytes() {
        for seed in UInt64(1)...300 {
            var rng = SeededRNG(seed: seed ^ 0xABCD_1234)
            var bytes = [UInt8]()
            for _ in 0..<Int(rng.next() % 200) { bytes.append(UInt8(rng.next() % 256)) }
            let text = String(decoding: bytes, as: UTF8.self) // lossy-clean UTF-8
            #expect(roundTrip(text) == text) // never traps; always round-trips
        }
    }

    @Test func serializeIsIdempotent() {
        for seed in UInt64(1)...400 {
            var rng = SeededRNG(seed: seed &+ 7)
            let once = roundTrip(Gen.configText(&rng))
            #expect(roundTrip(once) == once) // a serialized doc re-parses to itself
        }
    }

    /// Editing a single directive's value changes exactly one output line and nothing
    /// else — the property that makes "save touches only what you edited" hold.
    @Test func editingOneValueChangesOnlyThatLine() {
        let text = """
            # my hosts
            Host web
                HostName web.example.com
                User deploy
                Port 22

            Host db
                HostName db.example.com
            """
        var doc = parse(text)
        let bi = try! #require(doc.blocks.firstIndex { $0.body.contains { $0.directive != nil } })
        let li = try! #require(doc.blocks[bi].body.firstIndex { $0.directive != nil })
        let edited = doc.blocks[bi].body[li].directive!.settingValue("CHANGED")
        doc.blocks[bi].body[li] = .directive(edited)

        let before = text.components(separatedBy: "\n")
        let after = serialize(doc).components(separatedBy: "\n")
        #expect(before.count == after.count)
        let changed = zip(before, after).filter { $0 != $1 }
        #expect(changed.count == 1)
        #expect(changed.first?.1.contains("CHANGED") == true)
    }
}

// MARK: - Golden anchors

struct SerializerGoldenTests {
    /// Hand-picked inputs that must round-trip byte-for-byte. These pin specific
    /// formatting the lossless guarantee must never mangle (regression anchors).
    @Test func goldenRoundTrips() {
        let goldens = [
            "Host web\n    HostName web.example.com\n    Port 22\n",
            "Host a\n\tUser root\n", // tab indent
            "Host eq\n    Port=2222\n    User = admin\n", // = separators, spaced & not
            "# bastion\nHost jump\n    HostName 10.0.0.1\n", // leading comment kept on host
            "Match host db user admin\n    ForwardAgent yes\n",
            "Host trail\n    HostName x   \n", // trailing whitespace on value
            "Host a\n\n\nHost b\n", // multiple blank lines preserved
        ]
        for golden in goldens {
            #expect(roundTrip(golden) == golden)
        }
    }
}
