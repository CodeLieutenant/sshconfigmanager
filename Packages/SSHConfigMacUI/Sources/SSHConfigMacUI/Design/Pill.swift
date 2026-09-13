//
//  Pill.swift
//  SSHConfigMacUI
//
//  The capsule chips shown next to a title: a coloured status pill (dot + text on a
//  tinted wash, reading its colour from `StatusKind`) and a neutral tag pill. Plus the
//  small rounded count badge the sidebar puts on a destination. These keep "what
//  reachable / loaded / a tag looks like" decided once.
//

import SwiftUI

/// A status capsule: a colour dot + label on a faint tint of the status colour.
struct StatusPill: View {
    let kind: StatusKind
    let text: String

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(kind.color).frame(width: 7, height: 7)
            Text(text).font(.system(size: 11.5, weight: .medium))
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 3)
        .background(kind.color.opacity(0.16), in: Capsule())
    }
}

/// A neutral metadata capsule (a host tag).
struct TagPill: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 9)
            .padding(.vertical, 3)
            .background(Color.controlWash, in: Capsule())
    }
}

/// A metadata capsule that marks which group a host belongs to (folder icon + name).
struct GroupPill: View {
    let name: String
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "folder.fill")
                .font(.system(size: 9, weight: .semibold))
            Text(name)
                .font(.system(size: 11.5, weight: .medium))
        }
        .foregroundStyle(Color.accentColor)
        .padding(.horizontal, 9)
        .padding(.vertical, 3)
        .background(Color.accentColor.opacity(0.12), in: Capsule())
    }
}

/// A metadata capsule showing which config file a host is defined in (doc icon + filename).
/// Only shown when multiple documents are loaded (main config + at least one include).
struct FilePill: View {
    let name: String
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "doc.text.fill")
                .font(.system(size: 9, weight: .semibold))
            Text(name)
                .font(.system(size: 11.5, weight: .medium))
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 9)
        .padding(.vertical, 3)
        .background(Color.controlWash, in: Capsule())
    }
}

/// Marks a tunnel forward as serving a browsable web UI (paired with the "Has a
/// web UI" toggle in the tunnel editor's Options section and the "Open in
/// Browser" action it unlocks).
struct WebUIPill: View {
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "safari.fill")
                .font(.system(size: 9, weight: .semibold))
            Text("Web UI")
                .font(.system(size: 11.5, weight: .medium))
        }
        .foregroundStyle(Color.accentColor)
        .padding(.horizontal, 9)
        .padding(.vertical, 3)
        .background(Color.accentColor.opacity(0.12), in: Capsule())
    }
}

/// The small rounded count badge a sidebar destination carries (keys: 12, hosts: 34).
struct CountBadge: View {
    let count: Int
    var body: some View {
        Text("\(count)")
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(Color.badgeWash, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}
