//
//  DetailHeader.swift
//  sshconfigmanager
//
//  The one detail-pane header for the app. Keys, Agent, Tunnels, Host detail, and
//  Version History each hand-rolled an icon + title + subtitle + primary button +
//  overflow menu that were *almost* the same — which read as sloppy. This unifies them
//  (§5.2): leading icon, title + subtitle, an optional status badge, exactly one primary
//  action, and an overflow menu for everything else.
//

import SwiftUI

struct DetailHeader<Primary: View, Overflow: View>: View {
    let systemImage: String
    let title: String
    var subtitle: String?
    /// Optional status pill (e.g. tunnel "Active · 2m", agent "Loaded").
    var status: (kind: StatusKind, text: String)?
    @ViewBuilder var primary: () -> Primary
    @ViewBuilder var overflow: () -> Overflow

    var body: some View {
        HStack(spacing: Spacing.lg) {
            Image(systemName: systemImage)
                .font(.system(size: 22))
                .foregroundStyle(.secondary)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text(title).font(.title3).fontWeight(.semibold)
                if let subtitle {
                    Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: Spacing.lg)

            if let status {
                StatusBadge(kind: status.kind, text: status.text)
            }
            primary()
            overflow()
        }
        .padding(.horizontal, Spacing.xxxl)
        .padding(.vertical, Spacing.xl)
    }
}

// MARK: - Convenience initialisers

extension DetailHeader where Overflow == EmptyView {
    init(
        systemImage: String,
        title: String,
        subtitle: String? = nil,
        status: (kind: StatusKind, text: String)? = nil,
        @ViewBuilder primary: @escaping () -> Primary
    ) {
        self.init(
            systemImage: systemImage, title: title, subtitle: subtitle,
            status: status, primary: primary, overflow: { EmptyView() })
    }
}

extension DetailHeader where Primary == EmptyView {
    init(
        systemImage: String,
        title: String,
        subtitle: String? = nil,
        status: (kind: StatusKind, text: String)? = nil,
        @ViewBuilder overflow: @escaping () -> Overflow
    ) {
        self.init(
            systemImage: systemImage, title: title, subtitle: subtitle,
            status: status, primary: { EmptyView() }, overflow: overflow)
    }
}

extension DetailHeader where Primary == EmptyView, Overflow == EmptyView {
    init(
        systemImage: String,
        title: String,
        subtitle: String? = nil,
        status: (kind: StatusKind, text: String)? = nil
    ) {
        self.init(
            systemImage: systemImage, title: title, subtitle: subtitle,
            status: status, primary: { EmptyView() }, overflow: { EmptyView() })
    }
}
