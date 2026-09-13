//
//  PortMappingIPv6Tests.swift
//  sshconfigmanagerTests
//
//  Reproducer: `PortMapping` renders IPv6 literals unbracketed.
//
//  `PortMapping.parsing` correctly *reads* `[::1]:5432` — brackets and all — but
//  `forwardSpec` and `forwardDirectives` interpolate the host straight into
//  `host:port`, so a mapping whose target (or bind address) is an IPv6 literal
//  renders as `8080:::1:5432`. That string is ambiguous garbage: it is what the
//  tunnel console shows, it is what "write forwards into ssh config" puts in
//  `~/.ssh/config` (where ssh will reject or misparse it), and it does not
//  round-trip back through `parsing`.
//
//  `isValid(for:)` accepts an IPv6 target too, so nothing upstream stops it.
//

import Foundation
import SSHConfigCore
import Testing

struct PortMappingIPv6Tests {
    // MARK: - forwardSpec

    @Test func ipv6TargetIsBracketedInForwardSpec() {
        let mapping = PortMapping(listenPort: 8080, targetHost: "::1", targetPort: 5432)
        #expect(mapping.forwardSpec(for: .local) == "8080:[::1]:5432")
    }

    @Test func ipv6BindAddressIsBracketedInForwardSpec() {
        let mapping = PortMapping(bindAddress: "::1", listenPort: 8080, targetHost: "db", targetPort: 5432)
        #expect(mapping.forwardSpec(for: .local) == "[::1]:8080:db:5432")
    }

    @Test func ipv6BindAddressIsBracketedForDynamicForward() {
        let mapping = PortMapping(bindAddress: "::1", listenPort: 1080)
        #expect(mapping.forwardSpec(for: .dynamic) == "[::1]:1080")
    }

    /// Control: IPv4 and host names must stay exactly as they are today.
    @Test func ipv4AndHostnamesAreUnchanged() {
        #expect(
            PortMapping(listenPort: 8080, targetHost: "127.0.0.1", targetPort: 5432)
                .forwardSpec(for: .local) == "8080:127.0.0.1:5432")
        #expect(
            PortMapping(bindAddress: "127.0.0.1", listenPort: 8080, targetHost: "db.internal", targetPort: 5432)
                .forwardSpec(for: .local) == "127.0.0.1:8080:db.internal:5432")
    }

    /// An already-bracketed value must not be double-bracketed.
    @Test func alreadyBracketedTargetIsNotDoubleBracketed() {
        let mapping = PortMapping(listenPort: 8080, targetHost: "[::1]", targetPort: 5432)
        #expect(mapping.forwardSpec(for: .local) == "8080:[::1]:5432")
    }

    // MARK: - forwardDirectives (what gets written into ~/.ssh/config)

    @Test func ipv6TargetIsBracketedInForwardDirective() {
        let preset = TunnelPreset(
            hostAlias: "web", mode: .local,
            mappings: [PortMapping(listenPort: 8080, targetHost: "::1", targetPort: 5432)])
        #expect(preset.forwardDirectives.map(\.value) == ["8080 [::1]:5432"])
    }

    @Test func ipv6BindAddressIsBracketedInForwardDirective() {
        let preset = TunnelPreset(
            hostAlias: "web", mode: .dynamic,
            mappings: [PortMapping(bindAddress: "::1", listenPort: 1080)])
        #expect(preset.forwardDirectives.map(\.value) == ["[::1]:1080"])
    }

    // MARK: - Round-trip

    /// The rendered directive must parse back to the same mapping. `parsing`
    /// already handles brackets, so this only fails because the render side omits
    /// them — the clearest statement of the asymmetry.
    @Test func ipv6ForwardDirectiveRoundTrips() {
        let original = PortMapping(listenPort: 8080, targetHost: "::1", targetPort: 5432)
        let preset = TunnelPreset(hostAlias: "web", mode: .local, mappings: [original])
        let rendered = preset.forwardDirectives[0].value
        let parsed = PortMapping.parsing(rendered, mode: .local)
        #expect(parsed?.targetHost == "::1")
        #expect(parsed?.listenPort == 8080)
        #expect(parsed?.targetPort == 5432)
    }
}
