import AppKit
import SSHConfigCore
import SSHConfigEngine
import SSHConfigServices
import SwiftUI

func hostCheckOutcomeSymbol(_ outcome: String) -> String {
    switch outcome {
    case "verified": return "checkmark.shield.fill"
    case "changed": return "xmark.shield.fill"
    case "newKey": return "exclamationmark.shield.fill"
    default: return "wifi.slash"
    }
}

func hostCheckOutcomeColor(_ outcome: String) -> Color {
    switch outcome {
    case "verified": return .green
    case "changed": return .red
    case "newKey": return .orange
    default: return .secondary
    }
}

func hostCheckOutcomeName(_ outcome: String) -> String {
    switch outcome {
    case "verified": return "Verified"
    case "changed": return "Key changed"
    case "newKey": return "New key type"
    default: return "Unreachable"
    }
}
