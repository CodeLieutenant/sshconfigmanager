import Foundation

public enum ProjectLinks {
    public static let repository = URL(string: "https://github.com/CodeLieutenant/sshconfigmanager")!
    public static let issues = repository.appendingPathComponent("issues")

    public static func bugReport(appVersion: String, platform: String) -> URL {
        newIssue(template: "bug_report.yml", fields: [("version", appVersion), ("platform", platform)])
    }

    public static func featureRequest() -> URL {
        newIssue(template: "feature_request.yml", fields: [])
    }

    private static func newIssue(template: String, fields: [(name: String, value: String)]) -> URL {
        var components = URLComponents(
            url: issues.appendingPathComponent("new"), resolvingAgainstBaseURL: false)!
        components.queryItems =
            [URLQueryItem(name: "template", value: template)]
            + fields.map { URLQueryItem(name: $0.name, value: $0.value) }
        return components.url!
    }
}
