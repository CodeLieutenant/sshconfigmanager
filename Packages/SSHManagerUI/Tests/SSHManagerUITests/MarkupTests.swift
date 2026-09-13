import Foundation
import Testing

@testable import SSHManagerUI

@Suite("Escaping")
struct EscapingTests {
    @Test("markup escaping covers the three characters Pango parses")
    func markupEscaping() {
        #expect("Prod & Staging".markupEscaped == "Prod &amp; Staging")
        #expect("<b>x</b>".markupEscaped == "&lt;b&gt;x&lt;/b&gt;")
        #expect("plain".markupEscaped == "plain")
    }

    @Test("an escaped ampersand is not escaped twice")
    func ampersandOrder() {
        #expect("a & <b>".markupEscaped == "a &amp; &lt;b&gt;")
    }

    @Test("mnemonic escaping doubles the underscore")
    func mnemonicEscaping() {
        #expect("my_server".mnemonicEscaped == "my__server")
        #expect("plain".mnemonicEscaped == "plain")
    }
}

/// libadwaita parses Pango markup in several places that this application feeds
/// with names out of the user's files. The rules are in `CLAUDE.md`,
/// and this suite reads the sources so a new screen cannot quietly break them.
@Suite("libadwaita text rules")
struct MarkupRuleTests {
    private static let sources: [(name: String, text: String)] = {
        var result: [(String, String)] = []
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/SSHManagerUI")
        guard
            let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        else { return result }
        for case let url as URL in files where url.pathExtension == "swift" {
            if let text = try? String(contentsOf: url, encoding: .utf8) {
                result.append((url.lastPathComponent, text))
            }
        }
        return result
    }()

    @Test("the sources are readable from the test bundle")
    func sourcesFound() {
        #expect(Self.sources.count > 20)
    }

    /// `AdwPreferencesGroup` and `AdwStatusPage` parse markup in the description
    /// and offer no way to turn it off, so an interpolated value has to arrive
    /// escaped.
    @Test("no unescaped interpolation reaches a group title or a description")
    func groupTitlesAreEscaped() {
        var offenders: [String] = []
        for source in Self.sources {
            for line in source.text.split(separator: "\n", omittingEmptySubsequences: false) {
                let text = String(line)
                let interpolates = text.contains("\\(")
                guard interpolates, !text.contains("markupEscaped") else { continue }
                if text.contains("PreferencesGroup(") || text.contains("description:") {
                    offenders.append("\(source.name): \(text.trimmingCharacters(in: .whitespaces))")
                }
            }
        }
        #expect(offenders.isEmpty, "\(offenders)")
    }

    /// `gtk_widget_set_tooltip_markup` is what the binding calls, so a tooltip is
    /// markup as well.
    @Test("no unescaped interpolation reaches a tooltip")
    func tooltipsAreEscaped() {
        var offenders: [String] = []
        for source in Self.sources {
            for line in source.text.split(separator: "\n", omittingEmptySubsequences: false)
            where line.contains(".tooltip(") && line.contains("\\(") {
                let text = String(line)
                guard !text.contains("markupEscaped") else { continue }
                offenders.append("\(source.name): \(text.trimmingCharacters(in: .whitespaces))")
            }
        }
        #expect(offenders.isEmpty, "\(offenders)")
    }

    /// A view carries one alert dialog. Every `alertDialog` modifier on a view
    /// shares that view's storage under the same key, so a second one closes the
    /// first as soon as it is presented.
    @Test("no view declares more than one alert dialog")
    func oneAlertDialogPerView() {
        var offenders: [String] = []
        for source in Self.sources {
            let count = source.text.components(separatedBy: ".alertDialog(").count - 1
            if count > 1 { offenders.append("\(source.name): \(count)") }
        }
        #expect(offenders.isEmpty, "\(offenders)")
    }

    /// `AdwAboutDialog` keys its dialog by the same name a plain dialog uses, so
    /// every `dialog` in the window that also carries the about dialog needs an
    /// explicit identifier.
    @Test("every dialog in the window view has an identifier")
    func windowDialogsAreIdentified() {
        guard let root = Self.sources.first(where: { $0.name == "RootView.swift" }) else {
            Issue.record("RootView.swift not found")
            return
        }
        let calls = root.text.components(separatedBy: ".dialog(visible:").dropFirst()
        for call in calls {
            let head = String(call.prefix(200))
            #expect(head.contains("id:"), "a dialog in RootView has no id: \(head.prefix(80))")
        }
    }
}
