import Foundation
import SSHConfigServices
import Testing

struct ProjectLinksTests {
    private func query(_ url: URL) -> [String: String] {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { _, last in last })
    }

    @Test func bugReportOpensTheBugFormWithVersionAndPlatform() {
        let url = ProjectLinks.bugReport(appVersion: "1.2.0 (45)", platform: "macOS 15.3 & Mac14,2")
        #expect(url.path == "/CodeLieutenant/sshconfigmanager/issues/new")
        #expect(
            query(url) == [
                "template": "bug_report.yml", "version": "1.2.0 (45)", "platform": "macOS 15.3 & Mac14,2",
            ])
        #expect(url.absoluteString.contains("platform=macOS%2015.3%20%26%20Mac14,2"))
    }

    @Test func featureRequestOpensTheFeatureForm() {
        #expect(query(ProjectLinks.featureRequest()) == ["template": "feature_request.yml"])
    }
}
