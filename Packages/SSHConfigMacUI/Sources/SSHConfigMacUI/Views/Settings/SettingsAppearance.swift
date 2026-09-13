//
//  SettingsAppearance.swift
//  sshconfigmanager
//
//  Bridges the persisted preference enums (`AppearanceMode`, `AccentChoice`,
//  `UIDensity`) to the SwiftUI/AppKit values the views apply, plus the resolved code
//  font. Kept out of `AppSettings` so that state file stays free of SwiftUI imports;
//  this is the view-layer half of the same vocabulary.
//

import AppKit
import SwiftUI

extension AppearanceMode {
    /// `nil` means "follow the system" — exactly what `.preferredColorScheme(nil)` does.
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

extension AccentChoice {
    /// `nil` keeps SwiftUI's default tint (the user's system accent) — the design
    /// language's standing choice. A non-system value pins the app to one hue.
    var color: Color? {
        switch self {
        case .system: return nil
        case .blue: return .blue
        case .purple: return .purple
        case .pink: return .pink
        case .red: return .red
        case .orange: return .orange
        case .yellow: return .yellow
        case .green: return .green
        case .teal: return .teal
        case .graphite: return Color(nsColor: .systemGray)
        }
    }
}

extension UIDensity {
    var controlSize: ControlSize {
        switch self {
        case .comfortable: return .regular
        case .compact: return .small
        }
    }
}

extension AppSettings {
    /// The configured code font as a SwiftUI `Font`, for non-AppKit surfaces (the
    /// tunnel console). The raw editor resolves its own `NSFont` via `CodeEditor`.
    var editorFont: Font {
        let trimmed = editorFontName.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            return .system(size: editorFontSize, design: .monospaced)
        }
        return .custom(trimmed, size: editorFontSize)
    }

    /// Installed monospaced font family names, for the editor-font picker. We can't
    /// reliably ask the system "is this monospaced", so we offer a curated set of fonts
    /// that ship on macOS plus anything the user already picked.
    var availableEditorFonts: [String] {
        let candidates = [
            "SF Mono", "Menlo", "Monaco", "Courier New",
            "Andale Mono", "PT Mono", "Fira Code", "JetBrains Mono",
        ]
        let installed = Set(NSFontManager.shared.availableFontFamilies)
        var names = candidates.filter { installed.contains($0) }
        let current = editorFontName.trimmingCharacters(in: .whitespaces)
        if !current.isEmpty, !names.contains(current) { names.insert(current, at: 0) }
        return names
    }
}
