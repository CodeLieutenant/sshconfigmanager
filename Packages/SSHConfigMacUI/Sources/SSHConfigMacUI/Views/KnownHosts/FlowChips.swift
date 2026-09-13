import AppKit
import SSHConfigCore
import SSHConfigEngine
import SSHConfigServices
import SwiftUI

struct FlowChips: View {
    let items: [String]
    var onTap: ((_ item: String) -> Void)? = nil

    var body: some View {
        FlowLayout(spacing: 6, lineSpacing: 6) {
            ForEach(items, id: \.self) { item in
                if let onTap {
                    Button {
                        onTap(item)
                    } label: {
                        chipLabel(item, tappable: true)
                    }
                    .buttonStyle(.plain)
                } else {
                    chipLabel(item, tappable: false)
                        .textSelection(.enabled)
                }
            }
        }
    }

    private func chipLabel(_ text: String, tappable: Bool) -> some View {
        Text(text)
            .font(.system(size: 11.5).monospaced())
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(
                tappable ? Color.accentColor.opacity(0.08) : .controlWash,
                in: Capsule()
            )
            .overlay(
                Capsule().strokeBorder(
                    tappable ? Color.accentColor.opacity(0.25) : Color.cardBorder,
                    lineWidth: 1
                )
            )
    }
}
