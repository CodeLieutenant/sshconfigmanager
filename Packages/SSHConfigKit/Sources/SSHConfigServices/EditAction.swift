//
//  EditAction.swift
//  sshconfigmanager
//
//  Canonical names for every undoable edit. Centralizing them here (rather than
//  scattering string literals across ConfigStore / HostDetailView) gives the Edit
//  menu — and the ⌘Z / ⌘⇧Z titles AppKit derives from `NSUndoManager.setActionName`
//  — one consistent vocabulary, and a single place to localize later (see
//  docs/plans/ux/accessibility-and-localization.md). Pure value type, no I/O.
//

import Foundation

/// A semantic edit, used as the `NSUndoManager` action name. `name` is the
/// user-facing title shown in "Undo <name>" / "Redo <name>"; it's the seam to swap
/// in `String(localized:)` once the app grows a string catalog.
public enum EditAction: Equatable {
    case edit // generic fallback
    case newHost
    case addGlobalDefaults
    case newFromTemplate(String)
    case duplicateHost
    case deleteHost
    case reorderHosts
    case editRaw
    case importHosts(Int)
    case editPatterns
    case editField(String) // a known keyword's value (free-text)
    case toggleField(String) // a yes/no keyword
    case editDirective // a generic (unknown-keyword) directive
    case addSetting(String)
    case removeSetting(String)
    case addIdentityKey
    case removeIdentityKey
    case editIdentityKey
    case setIdentityFile
    case addForwarding
    case editJumpChain
    case moveToFile
    case moveToNewFile
    case createGroup(String)
    case renameGroup(String)
    case deleteGroup(String)
    case extractGroupToFile(String)
    case moveHostToGroup(String)

    public var name: String {
        switch self {
        case .edit: return "Edit"
        case .newHost: return "New Host"
        case .addGlobalDefaults: return "Add Global Defaults"
        case .newFromTemplate(let t): return "New \(t)"
        case .duplicateHost: return "Duplicate Host"
        case .deleteHost: return "Delete Host"
        case .reorderHosts: return "Reorder Hosts"
        case .editRaw: return "Edit Raw Text"
        case .importHosts(let n): return "Import \(n) Host\(n == 1 ? "" : "s")"
        case .editPatterns: return "Edit Patterns"
        case .editField(let k): return "Edit \(k)"
        case .toggleField(let k): return "Toggle \(k)"
        case .editDirective: return "Edit Directive"
        case .addSetting(let k): return "Add \(k)"
        case .removeSetting(let k): return "Remove \(k)"
        case .addIdentityKey: return "Add Identity Key"
        case .removeIdentityKey: return "Remove Identity Key"
        case .editIdentityKey: return "Edit Identity Key"
        case .setIdentityFile: return "Set Identity File"
        case .addForwarding: return "Add Forwarding"
        case .editJumpChain: return "Edit Jump Hosts"
        case .moveToFile: return "Move to File"
        case .moveToNewFile: return "Move to New File"
        case .createGroup(let n): return "New Group “\(n)”"
        case .renameGroup(let n): return "Rename Group to “\(n)”"
        case .deleteGroup(let n): return "Delete Group “\(n)”"
        case .extractGroupToFile(let n): return "Extract Group “\(n)” to File"
        case .moveHostToGroup(let n): return "Move to Group “\(n)”"
        }
    }
}
