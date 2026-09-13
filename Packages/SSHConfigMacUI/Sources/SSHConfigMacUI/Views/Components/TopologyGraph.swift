//
//  TopologyGraph.swift
//  sshconfigmanager
//
//  A horizontal chain diagram —  you → jump₁ → jump₂ → target — drawn with
//  Canvas so there are no third-party dependencies. Each node shows the resolved
//  user/host/port; alias nodes are visually distinct; cycle nodes render in error
//  colour.
//

import SSHConfigCore
import SwiftUI

struct TopologyGraph: View {
    /// The resolved hops (not including the target).
    let hops: [ResolvedHop]
    /// The target alias shown as the final node.
    let targetLabel: String
    /// Called when the user clicks an alias node to navigate to it.
    var onSelectAlias: ((String) -> Void)?

    private let nodeW: CGFloat = 120
    private let nodeH: CGFloat = 56
    private let arrowLen: CGFloat = 36

    private var nodeCount: Int { hops.count + 2 } // "you" + hops + target
    private var totalW: CGFloat { CGFloat(nodeCount) * nodeW + CGFloat(nodeCount - 1) * arrowLen }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Canvas { ctx, size in
                drawChain(ctx: ctx, size: size)
            }
            .frame(width: max(totalW, 300), height: nodeH + 28)
            .frame(maxWidth: .infinity, minHeight: nodeH + 28)
        }
        .overlay(nodeOverlay)
    }

    // MARK: - Canvas drawing (arrows)

    private func drawChain(ctx: GraphicsContext, size: CGSize) {
        let y = size.height / 2
        let arrowColor = Color.secondary.opacity(0.4)
        for i in 0..<(nodeCount - 1) {
            let startX = CGFloat(i) * (nodeW + arrowLen) + nodeW
            let endX = startX + arrowLen
            var path = Path()
            path.move(to: CGPoint(x: startX, y: y))
            path.addLine(to: CGPoint(x: endX - 8, y: y))
            ctx.stroke(path, with: .color(arrowColor), lineWidth: 1.5)
            // arrowhead
            var head = Path()
            head.move(to: CGPoint(x: endX - 8, y: y - 5))
            head.addLine(to: CGPoint(x: endX, y: y))
            head.addLine(to: CGPoint(x: endX - 8, y: y + 5))
            ctx.stroke(head, with: .color(arrowColor), lineWidth: 1.5)
        }
    }

    // MARK: - SwiftUI node overlay

    @ViewBuilder
    private var nodeOverlay: some View {
        HStack(spacing: arrowLen) {
            youNode
            ForEach(Array(hops.enumerated()), id: \.offset) { _, hop in
                hopNode(hop)
            }
            targetNode
        }
        .frame(maxWidth: .infinity)
    }

    private var youNode: some View {
        TopologyNode(
            primary: "you",
            secondary: nil,
            isAlias: false,
            isTarget: false,
            isCycle: false
        )
        .frame(width: nodeW, height: nodeH)
    }

    private func hopNode(_ hop: ResolvedHop) -> some View {
        let isCycle = hop.label.contains("(cycle")
        let secondary = hop.hostName ?? (hop.user.map { "\($0)@" } ?? "")
        return TopologyNode(
            primary: hop.label,
            secondary: secondary.isEmpty ? nil : secondary,
            isAlias: hop.isAlias,
            isTarget: false,
            isCycle: isCycle,
            hasNestedJump: !hop.nested.isEmpty
        )
        .frame(width: nodeW, height: nodeH)
        .onTapGesture {
            if hop.isAlias, let onSelectAlias {
                onSelectAlias(hop.label.components(separatedBy: "@").last ?? hop.label)
            }
        }
        .help(hop.isAlias ? "Click to select this host in the sidebar" : "")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            hop.isAlias
                ? "Jump host \(hop.label), defined as a host block. Tap to navigate."
                : "Jump host \(hop.label)")
    }

    private var targetNode: some View {
        TopologyNode(
            primary: targetLabel,
            secondary: nil,
            isAlias: false,
            isTarget: true,
            isCycle: false
        )
        .frame(width: nodeW, height: nodeH)
    }
}

// MARK: - Single node

private struct TopologyNode: View {
    let primary: String
    let secondary: String?
    let isAlias: Bool
    let isTarget: Bool
    let isCycle: Bool
    var hasNestedJump: Bool = false

    private var borderColor: Color {
        if isCycle { return .red }
        if isTarget { return .accentColor }
        if isAlias { return Color.secondary.opacity(0.4) }
        return Color.secondary.opacity(0.25)
    }

    private var fillColor: Color {
        if isTarget { return Color.accentColor.opacity(0.08) }
        if isAlias { return Color.primary.opacity(0.04) }
        return Color.clear
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            RoundedRectangle(cornerRadius: Radius.chip, style: .continuous)
                .fill(fillColor)
                .overlay(
                    RoundedRectangle(cornerRadius: Radius.chip, style: .continuous)
                        .strokeBorder(borderColor, lineWidth: isAlias || isTarget ? 1.5 : 1)
                )

            VStack(spacing: 2) {
                Text(primary)
                    .font(.system(size: 11, weight: .medium).monospaced())
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(isCycle ? Color.red : Color.primary)
                if let secondary {
                    Text(secondary)
                        .font(.system(size: 10))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 6)

            if hasNestedJump {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 8))
                    .foregroundStyle(Color.accentColor)
                    .padding(3)
            }
        }
    }
}
