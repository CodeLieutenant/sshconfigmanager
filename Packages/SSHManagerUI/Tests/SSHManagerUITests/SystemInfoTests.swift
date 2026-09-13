import Testing

@testable import SSHManagerUI

struct SystemInfoTests {
    @Test func readsQuotedPrettyName() {
        let osRelease = "NAME=\"Fedora Linux\"\nPRETTY_NAME=\"Fedora Linux 41 (Workstation Edition)\"\nID=fedora\n"
        #expect(SystemInfo.prettyName(osRelease: osRelease) == "Fedora Linux 41 (Workstation Edition)")
    }

    @Test func missingPrettyNameGivesNil() {
        #expect(SystemInfo.prettyName(osRelease: "ID=arch\n") == nil)
        #expect(SystemInfo.prettyName(osRelease: "PRETTY_NAME=\"\"\n") == nil)
    }
}
