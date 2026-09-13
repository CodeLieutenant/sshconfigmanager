//
//  SOCKS5.swift
//  sshconfigmanager
//
//  Minimal SOCKS5 server-side parsing for the dynamic (-D) tunnel: enough to
//  accept a no-auth client and read its CONNECT target. The byte parsing is pure
//  and unit-tested; the NIO handler that drives it lives in NIOTunnelEngine.
//

import Foundation

public enum SOCKS5 {
    public static let version: UInt8 = 0x05
    public static let noAuth: UInt8 = 0x00
    public static let cmdConnect: UInt8 = 0x01

    public enum AddressType: UInt8 {
        case ipv4 = 0x01
        case domain = 0x03
        case ipv6 = 0x04
    }

    public enum Reply: UInt8 {
        case success = 0x00
        case generalFailure = 0x01
        case commandNotSupported = 0x07
        case addressTypeNotSupported = 0x08
    }

    public struct Target: Equatable {
        public let host: String
        public let port: Int

        public init(host: String, port: Int) {
            self.host = host
            self.port = port
        }
    }

    public enum ParseError: Error, Equatable { case incomplete, badVersion, unsupportedCommand, unsupportedAddress }

    /// Parses the client's method-selection greeting; returns true if it offers
    /// the "no authentication" method. Throws `.incomplete` if more bytes are needed.
    public static func parseGreeting(_ bytes: [UInt8]) throws -> Bool {
        guard bytes.count >= 2 else { throw ParseError.incomplete }
        guard bytes[0] == version else { throw ParseError.badVersion }
        let count = Int(bytes[1])
        guard bytes.count >= 2 + count else { throw ParseError.incomplete }
        return bytes[2..<2 + count].contains(noAuth)
    }

    /// The 2-byte method-selection response (choose no-auth).
    public static func methodSelection(_ method: UInt8 = noAuth) -> [UInt8] { [version, method] }

    /// Parses a CONNECT request: VER CMD RSV ATYP ADDR PORT.
    public static func parseConnectRequest(_ bytes: [UInt8]) throws -> Target {
        guard bytes.count >= 4 else { throw ParseError.incomplete }
        guard bytes[0] == version else { throw ParseError.badVersion }
        guard bytes[1] == cmdConnect else { throw ParseError.unsupportedCommand }
        guard let atyp = AddressType(rawValue: bytes[3]) else { throw ParseError.unsupportedAddress }

        let host: String
        var index = 4
        switch atyp {
        case .ipv4:
            guard bytes.count >= index + 4 + 2 else { throw ParseError.incomplete }
            host = bytes[index..<index + 4].map(String.init).joined(separator: ".")
            index += 4
        case .domain:
            guard bytes.count >= index + 1 else { throw ParseError.incomplete }
            let length = Int(bytes[index])
            index += 1
            // A zero-length domain is not a valid target: without this guard it parses to
            // `host == ""`, the -D handler opens `direct-tcpip` to an empty host, and on
            // channel-open success replies SOCKS `success` — so the client believes the
            // tunnel is up while the target is bogus. Reject it as an unsupported address
            // so the handler replies `generalFailure` instead. (Audit NET-1.)
            guard length > 0 else { throw ParseError.unsupportedAddress }
            guard bytes.count >= index + length + 2 else { throw ParseError.incomplete }
            host = String(decoding: bytes[index..<index + length], as: UTF8.self)
            index += length
        case .ipv6:
            guard bytes.count >= index + 16 + 2 else { throw ParseError.incomplete }
            host = ipv6String(Array(bytes[index..<index + 16]))
            index += 16
        }
        let port = Int(bytes[index]) << 8 | Int(bytes[index + 1])
        return Target(host: host, port: port)
    }

    /// The byte length of a (already-validated) CONNECT request, so the caller can
    /// drop exactly those bytes and forward anything pipelined after it.
    public static func connectRequestLength(_ bytes: [UInt8]) -> Int {
        guard bytes.count >= 4, let atyp = AddressType(rawValue: bytes[3]) else { return bytes.count }
        switch atyp {
        case .ipv4: return 4 + 4 + 2
        case .ipv6: return 4 + 16 + 2
        case .domain: return bytes.count >= 5 ? 4 + 1 + Int(bytes[4]) + 2 : bytes.count
        }
    }

    /// A CONNECT reply (we report 0.0.0.0:0 as the bound address — clients ignore it).
    public static func connectReply(_ reply: Reply) -> [UInt8] {
        [version, reply.rawValue, 0x00, AddressType.ipv4.rawValue, 0, 0, 0, 0, 0, 0]
    }

    private static func ipv6String(_ bytes: [UInt8]) -> String {
        stride(from: 0, to: 16, by: 2)
            .map { String(format: "%x", Int(bytes[$0]) << 8 | Int(bytes[$0 + 1])) }
            .joined(separator: ":")
    }
}
