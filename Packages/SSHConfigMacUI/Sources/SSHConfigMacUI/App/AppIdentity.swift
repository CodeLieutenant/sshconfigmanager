import Foundation

nonisolated enum AppIdentity {
    static let bundleIdentifier = Bundle.main.bundleIdentifier ?? "sshconfigmanager"

    static func scoped(_ suffix: String) -> String {
        "\(bundleIdentifier).\(suffix)"
    }
}
