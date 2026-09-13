//
//  RevokedHostKeysParser.swift
//  SSHConfigCore
//
//  Parses an OpenSSH `RevokedHostKeys` file into the set of SHA256 fingerprints to
//  refuse. Crucially this is NOT known_hosts format: OpenSSH's RevokedHostKeys file is
//  a bare public key per line (`keytype base64blob [comment]`) with no host field, and
//  a revoked key is refused for EVERY host, not just one. The engine previously parsed
//  it with the known_hosts parser, which mis-bound the fields and host-scoped the
//  match, so a standard revocation file never actually refused anything (audit #8).
//
//  Pure + Foundation-only: the base64-blob → "SHA256:…" fingerprint is injected so the
//  crypto stays in the platform layer (SSHConfigCrypto), mirroring KnownHostsVerifier.
//

import Foundation

public enum RevokedHostKeysParser {
    /// The revoked fingerprints in `text`. `fingerprint` converts a base64 key blob to
    /// a canonical "SHA256:…" string (nil if the token isn't a decodable key blob).
    ///
    /// Each non-comment line's key type ("ssh-ed25519", "ecdsa-sha2-*", "ssh-rsa") all
    /// contain '-', which isn't valid base64, so the first token that fingerprints is
    /// the real key blob — this tolerates the documented bare-pubkey format as well as a
    /// stray host- or marker-prefixed line without mis-fingerprinting the key type.
    public static func parse(_ text: String, fingerprint: (String) -> String?) -> Set<String> {
        var result: Set<String> = []
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            for field in line.split(whereSeparator: \.isWhitespace) {
                if let fp = fingerprint(String(field)) {
                    result.insert(fp)
                    break
                }
            }
        }
        return result
    }
}
