import Foundation

public enum SystemInfo {
    public static var platformSummary: String {
        let distribution = prettyName(
            osRelease: (try? String(contentsOfFile: "/etc/os-release", encoding: .utf8)) ?? "")
        let packaging = ProcessInfo.processInfo.environment["FLATPAK_ID"] == nil ? nil : "Flatpak"
        return [distribution ?? "Linux", packaging.map { "(\($0))" }].compactMap { $0 }.joined(separator: " ")
    }

    static func prettyName(osRelease: String) -> String? {
        for line in osRelease.split(separator: "\n") where line.hasPrefix("PRETTY_NAME=") {
            let value = line.dropFirst("PRETTY_NAME=".count).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            return value.isEmpty ? nil : value
        }
        return nil
    }
}
