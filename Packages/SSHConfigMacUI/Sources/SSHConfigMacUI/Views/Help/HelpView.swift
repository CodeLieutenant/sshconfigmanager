//
//  HelpView.swift
//  SSHConfigMacUI
//
//  The app's in-app help book. A self-contained, offline SwiftUI window reachable
//  from Help ▸ "SSH Config Manager Help" (and ⌘?). The App Store requires a
//  shippable app to document how its features work; this is that documentation,
//  bundled in the binary so it needs no network and no separate .help bundle to
//  keep in sync.
//
//  Structure: a `NavigationSplitView` with a topic list on the left and a rendered
//  article on the right. Content lives as plain data (`HelpTopic`/`HelpBlock` in
//  `HelpContent.swift`) so editing the docs never touches view code.
//

import AppKit
import SwiftUI

/// The help window: a topic sidebar + the selected article. Hosted by `RootScene`
/// as a dedicated `Window` (id `"help"`), opened via `openWindow(id:)`.
struct HelpView: View {
    @State private var selection: HelpTopic.ID? = HelpContent.topics.first?.id

    var body: some View {
        NavigationSplitView {
            List(HelpContent.topics, selection: $selection) { topic in
                Label(topic.title, systemImage: topic.systemImage)
                    .tag(topic.id)
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 280)
            .navigationTitle("Help")
        } detail: {
            if let topic = HelpContent.topics.first(where: { $0.id == selection }) {
                HelpArticleView(topic: topic)
            } else {
                ContentUnavailableView("Select a topic", systemImage: "questionmark.circle")
            }
        }
        .frame(minWidth: 720, minHeight: 480)
        .accessibilityIdentifier("help-root")
    }
}

/// Renders a single help topic as a scrolling article of typed blocks.
private struct HelpArticleView: View {
    let topic: HelpTopic

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 10) {
                    Image(systemName: topic.systemImage)
                        .font(.title)
                        .foregroundStyle(Color.accentColor)
                    Text(topic.title)
                        .font(.largeTitle.weight(.bold))
                }
                .padding(.bottom, 2)

                ForEach(Array(topic.blocks.enumerated()), id: \.offset) { _, block in
                    HelpBlockView(block: block)
                }
            }
            .frame(maxWidth: 640, alignment: .leading)
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle(topic.title)
    }
}

/// Renders one block of help content with the right typography per kind.
private struct HelpBlockView: View {
    let block: HelpBlock

    var body: some View {
        switch block {
        case .paragraph(let text):
            Text(LocalizedStringKey(text))
                .font(.body)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)

        case .heading(let text):
            Text(text)
                .font(.title3.weight(.semibold))
                .padding(.top, 8)

        case .bullets(let items):
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("•").foregroundStyle(.secondary)
                        Text(LocalizedStringKey(item))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

        case .steps(let items):
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\(index + 1).")
                            .monospacedDigit()
                            .foregroundStyle(Color.accentColor)
                            .frame(width: 20, alignment: .trailing)
                        Text(LocalizedStringKey(item))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

        case .code(let text):
            Text(text)
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    Color(nsColor: .textBackgroundColor),
                    in: RoundedRectangle(cornerRadius: 6)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(Color.secondary.opacity(0.2))
                )

        case .note(let text):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "info.circle.fill")
                    .foregroundStyle(Color.accentColor)
                Text(LocalizedStringKey(text))
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                Color.accentColor.opacity(0.08),
                in: RoundedRectangle(cornerRadius: 6))
        }
    }
}

#Preview {
    HelpView()
}
