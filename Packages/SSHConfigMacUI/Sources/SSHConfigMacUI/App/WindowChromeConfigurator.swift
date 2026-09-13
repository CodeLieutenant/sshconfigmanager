//
//  WindowChromeConfigurator.swift
//  SSHConfigMacUI
//
//  Makes the hosting `NSWindow` use a transparent, full-size-content titlebar so the
//  Liquid Glass sidebar and detail header reach the very top of the window — behind the
//  traffic-light controls — rather than sitting under an opaque title bar. Attached once
//  as a background of the root content; `glassChrome()` does the matching work on the
//  SwiftUI side (its material bleeds past the safe area while content stays inset).
//

import AppKit
import SwiftUI

struct WindowChromeConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        // The window isn't attached yet when the view is created; defer to the next
        // run-loop tick so `view.window` is populated.
        DispatchQueue.main.async { [weak view] in Self.configure(view?.window) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { [weak nsView] in Self.configure(nsView?.window) }
    }

    private static func configure(_ window: NSWindow?) {
        guard let window else { return }
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.styleMask.insert(.fullSizeContentView)
    }
}
