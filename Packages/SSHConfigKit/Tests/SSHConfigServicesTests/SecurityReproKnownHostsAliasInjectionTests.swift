import Foundation
import SSHConfigCore
import SSHConfigServices
import Testing

struct KnownHostsAliasInjectionTests {
    @Test func baselinePlainHostProducesOneNormalEntry() {
        let line = KnownHostsService.formatTrustLine(
            host: "prod.example.com", port: 22,
            openSSHKeyLine: "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIREALHOSTKEYREALHOSTKEYREALHOSTKEYRE",
            hashed: false, salt: Data(count: 20), hmacSHA1: { _, _ in Data() })

        let entries = KnownHostsService.parse(line)
        #expect(entries.count == 1)
        #expect(entries.first?.resolvedMarker == KnownHostMarker.none)
        #expect(entries.first?.hostsDisplay == "prod.example.com")
    }

    @Test func bracketedNonDefaultPortHostStillFormats() {
        let line = KnownHostsService.formatTrustLine(
            host: "prod.example.com", port: 2222,
            openSSHKeyLine: "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIREALHOSTKEYREALHOSTKEYREALHOSTKEYRE",
            hashed: false, salt: Data(count: 20), hmacSHA1: { _, _ in Data() })

        let entries = KnownHostsService.parse(line)
        #expect(entries.count == 1)
        #expect(entries.first?.hostsDisplay == "[prod.example.com]:2222")
    }

    @Test func hostKeyAliasWithSpacesIsRefused() {
        let attackerAlias = "@cert-authority * ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIATTACKERCA"

        let line = KnownHostsService.formatTrustLine(
            host: attackerAlias, port: 22,
            openSSHKeyLine: "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIREALHOSTKEYREALHOSTKEYREALHOSTKEYRE",
            hashed: false, salt: Data(count: 20), hmacSHA1: { _, _ in Data() })

        #expect(line.isEmpty)
        #expect(!KnownHostsService.isValidLine(line))

        let entries = KnownHostsService.parse(line)
        #expect(entries.isEmpty)
        #expect(!entries.contains { $0.resolvedMarker == KnownHostMarker.certAuthority })
    }

    @Test func unsafeHostTokensAreRejectedAndSafeOnesAccepted() {
        #expect(!KnownHostsService.isSafeHostToken("@cert-authority * ssh-ed25519 KEY"))
        #expect(!KnownHostsService.isSafeHostToken("host with space"))
        #expect(!KnownHostsService.isSafeHostToken("host\ttab"))
        #expect(!KnownHostsService.isSafeHostToken("host#comment"))
        #expect(!KnownHostsService.isSafeHostToken("@marker"))
        #expect(!KnownHostsService.isSafeHostToken("line\nbreak"))
        #expect(!KnownHostsService.isSafeHostToken(""))

        #expect(KnownHostsService.isSafeHostToken("prod.example.com"))
        #expect(KnownHostsService.isSafeHostToken("10.0.0.1"))
        #expect(KnownHostsService.isSafeHostToken("::1"))
        #expect(KnownHostsService.isSafeHostToken("my-alias_1"))
    }
}
