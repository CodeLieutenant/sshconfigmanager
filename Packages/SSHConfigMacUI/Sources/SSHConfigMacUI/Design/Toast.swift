//
//  Toast.swift
//  SSHConfigMacUI
//
//  A transient confirmation banner ("Tunnel added") for actions that dismiss a sheet
//  before the user gets any other feedback that something happened. The call site owns
//  a `String?` and clears it after a delay via `withToast(_:)`; the view itself has no
//  timer of its own so it can't outlive the state that shows it.
//

import SwiftUI

/// A pill with a checkmark + message, meant to float over content via `.overlay`.
struct SuccessToast: View {
    let text: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
            Text(text)
                .font(.system(size: 12.5, weight: .medium))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.cardBorder, lineWidth: 1))
        .shadow(color: Color.primary.opacity(0.12), radius: 10, y: 4)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}

extension View {
    /// Floats a `SuccessToast` over the bottom of this view whenever `message` is
    /// non-nil, then clears it automatically after `duration` seconds.
    func toast(_ message: Binding<String?>, duration: Duration = .seconds(2)) -> some View {
        overlay(alignment: .bottom) {
            if let text = message.wrappedValue {
                SuccessToast(text: text)
                    .padding(.bottom, 20)
                    .task(id: text) {
                        try? await Task.sleep(for: duration)
                        withAnimation { message.wrappedValue = nil }
                    }
            }
        }
        .animation(.easeInOut(duration: 0.2), value: message.wrappedValue)
    }
}
