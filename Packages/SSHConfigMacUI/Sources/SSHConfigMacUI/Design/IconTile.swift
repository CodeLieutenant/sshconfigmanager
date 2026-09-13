//
//  IconTile.swift
//  SSHConfigMacUI
//
//  A System-Settings-style rounded colour tile with a white SF Symbol — the single
//  visual idiom for "a thing's identity" across the redesign: sidebar destinations
//  (24pt), the detail-header app tile (40pt), and inline list rows (24pt). The colour
//  is decorative identity from `TilePalette`, never status, so it stays saturated and
//  adapts to dark mode. A subtle vertical gradient + soft shadow gives the lift that
//  the Liquid Glass direction calls for.
//

import SwiftUI

struct IconTile: View {
    let systemImage: String
    var color: Color = TilePalette.accent
    var size: CGFloat = 24
    /// Override the glyph colour (defaults to white, which reads on every tile hue).
    var glyphColor: Color = .white

    private var corner: CGFloat { size >= 36 ? Radius.control : Radius.tile }
    private var glyphSize: CGFloat { size * 0.58 }

    var body: some View {
        RoundedRectangle(cornerRadius: corner, style: .continuous)
            .fill(color.gradient)
            .frame(width: size, height: size)
            .overlay {
                Image(systemName: systemImage)
                    .font(.system(size: glyphSize, weight: .semibold))
                    .foregroundStyle(glyphColor)
            }
            .shadow(color: .black.opacity(0.2), radius: 1, y: 1)
    }
}
