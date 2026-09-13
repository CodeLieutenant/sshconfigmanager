import AppKit
import Foundation
import Observation
import SSHConfigCore
import SSHConfigCrypto
import SSHConfigEngine
import SSHConfigServices
import Security
import SwiftUI
@preconcurrency import UserNotifications

extension ConfigStore {
    func mutate(
        _ actionName: String,
        undoable: Bool = true,
        coalescing: Bool = false,
        coalesceTarget: String? = nil,
        _ body: () -> Void
    ) {
        let beforeDocuments = documents
        let before = EditorSnapshot(documents: beforeDocuments, groups: groups, tagsByAlias: tagsByAlias)
        body()
        Log.config.info(
            "edit: \(actionName, privacy: .public) (coalescing: \(coalescing, privacy: .public))")
        markChanged(from: beforeDocuments)
        if coalescing {
            if coalescingFieldEdit == nil {
                coalescingFieldEdit = (before, actionName)
            }
        } else if undoable {
            commitFieldEdit()
            registerUndo(actionName: actionName, snapshot: before, coalesceTarget: coalesceTarget)
        }
        scheduleAutosave()
    }

    func commitFieldEdit() {
        guard let pending = coalescingFieldEdit else { return }
        coalescingFieldEdit = nil
        guard
            documents != pending.snapshot.documents || groups != pending.snapshot.groups
                || tagsByAlias != pending.snapshot.tagsByAlias
        else { return }
        registerUndo(actionName: pending.actionName, snapshot: pending.snapshot)
    }

    private func markChanged(from before: [SSHConfigDocument]) {
        let previous = Dictionary(before.map { ($0.sourceURL, $0) }, uniquingKeysWith: { first, _ in first })
        let currentURLs = Set(documents.map(\.sourceURL))
        for document in documents {
            if previous[document.sourceURL] != document {
                dirtyURLs.insert(document.sourceURL)
            }
            pendingDeleteURLs.remove(document.sourceURL)
        }
        for document in before where !currentURLs.contains(document.sourceURL) {
            pendingDeleteURLs.insert(document.sourceURL)
            dirtyURLs.remove(document.sourceURL)
        }
    }

    private func registerUndo(
        actionName: String,
        snapshot: EditorSnapshot,
        coalesceTarget: String? = nil
    ) {
        guard let undoManager else { return }
        if let coalesceTarget {
            let now = clock()
            if let last = lastDiscreteUndo,
                last.target == coalesceTarget,
                now.timeIntervalSince(last.at) <= discreteCoalesceWindow
            {
                lastDiscreteUndo = (coalesceTarget, now)
                return
            }
            lastDiscreteUndo = (coalesceTarget, now)
        } else {
            lastDiscreteUndo = nil
        }
        #if DEBUG
            undoStepsRegistered += 1
        #endif
        undoManager.registerUndo(withTarget: self) { store in
            store.restoreSnapshot(snapshot, actionName: actionName)
        }
        undoManager.setActionName(actionName)
    }

    private func restoreSnapshot(_ snapshot: EditorSnapshot, actionName: String) {
        let currentDocuments = documents
        let current = EditorSnapshot(documents: currentDocuments, groups: groups, tagsByAlias: tagsByAlias)
        documents = snapshot.documents
        groups = snapshot.groups
        if tagsByAlias != snapshot.tagsByAlias {
            tagsByAlias = snapshot.tagsByAlias
            persistHostMetadata()
        }
        markChanged(from: currentDocuments)
        if groups != current.groups { persistGroups() }
        lastDiscreteUndo = nil
        if let undoManager {
            undoManager.registerUndo(withTarget: self) { store in
                store.restoreSnapshot(current, actionName: actionName)
            }
            undoManager.setActionName(actionName)
        }
        let currentIDs = Set(currentDocuments.flatMap { $0.blocks.map(\.id) })
        if let restored = snapshot.documents.flatMap({ $0.blocks }).first(where: { !currentIDs.contains($0.id) }) {
            selectedBlockID = restored.id
        } else if let selectedBlockID, block(id: selectedBlockID) == nil {
            self.selectedBlockID = nil
        }
        scheduleAutosave()
    }
}
