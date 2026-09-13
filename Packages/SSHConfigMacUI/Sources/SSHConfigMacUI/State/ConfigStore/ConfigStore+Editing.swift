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
    func setJumpChain(id: HostBlock.ID, _ chain: JumpChain) {
        updateBlock(id: id, actionName: EditAction.editJumpChain.name) { block in
            if chain.isNone {
                block.setValue("none", for: "ProxyJump")
            } else if chain.hops.isEmpty {
                block.setValue(nil, for: "ProxyJump")
            } else {
                block.setValue(chain.render(), for: "ProxyJump")
            }
        }
    }

    var mainDocumentURL: URL? { documents.first?.sourceURL }

    func block(id: HostBlock.ID) -> HostBlock? {
        for document in documents {
            if let block = document.blocks.first(where: { $0.id == id }) { return block }
        }
        return nil
    }

    var selectedBlock: HostBlock? {
        guard let selectedBlockID else { return nil }
        return block(id: selectedBlockID)
    }

    func documentURL(for blockID: HostBlock.ID) -> URL? {
        for document in documents where document.blocks.contains(where: { $0.id == blockID }) {
            return document.sourceURL
        }
        return nil
    }

    func updateBlock(
        id: HostBlock.ID,
        actionName: String = "Edit",
        undoable: Bool = true,
        coalescing: Bool = false,
        coalesceTarget: String? = nil,
        _ transform: (inout HostBlock) -> Void
    ) {
        guard let location = locate(id) else { return }
        mutate(actionName, undoable: undoable, coalescing: coalescing, coalesceTarget: coalesceTarget) {
            transform(&documents[location.document].blocks[location.block])
            Self.abbreviateTouchedPaths(in: &documents[location.document].blocks[location.block])
        }
    }

    private static func abbreviateTouchedPaths(in block: inout HostBlock) {
        let home = SSHFileAccess.realHomeDirectory.path
        for index in block.body.indices {
            guard var directive = block.body[index].directive, directive.isDirty,
                KeywordRegistry.isPath(directive.keyword)
            else { continue }
            let unquoted = SSHValueQuoting.unquoted(directive.value)
            let abbreviated = HomePath.abbreviating(unquoted, home: home)
            guard abbreviated != unquoted else { continue }
            directive.value = SSHValueQuoting.quotedIfNeeded(abbreviated)
            block.body[index] = .directive(directive)
        }
    }

    @discardableResult
    func addHost(to documentURL: URL? = nil) -> HostBlock.ID? {
        let targetURL = documentURL ?? mainDocumentURL
        guard let targetURL,
            let index = documents.firstIndex(where: { $0.sourceURL == targetURL })
        else { return nil }
        let header = Directive(keyword: "Host", value: uniqueHostName(), isDirty: true)
        let block = HostBlock(kind: .host, header: header, body: defaultHostBody(), sourceURL: targetURL)
        mutate(EditAction.newHost.name) {
            documents[index].appendBlocks([block])
        }
        selectedBlockID = block.id
        return block.id
    }

    var globalDefaultsBlock: HostBlock? {
        documents.flatMap(\.blocks).first { $0.isWildcard }
    }

    @discardableResult
    func ensureGlobalDefaultsBlock() -> HostBlock.ID? {
        if let existing = globalDefaultsBlock { return existing.id }
        guard let targetURL = mainDocumentURL,
            let index = documents.firstIndex(where: { $0.sourceURL == targetURL })
        else { return nil }
        let header = Directive(keyword: "Host", value: "*", isDirty: true)
        let block = HostBlock(kind: .host, header: header, sourceURL: targetURL)
        mutate(EditAction.addGlobalDefaults.name) {
            documents[index].appendBlocks([block])
        }
        selectedBlockID = block.id
        return block.id
    }

    private func defaultHostBody() -> [ConfigLine] {
        let settings = AppSettings.shared
        var body: [ConfigLine] = []
        let user = settings.defaultHostUser.trimmingCharacters(in: .whitespaces)
        if !user.isEmpty {
            body.append(.directive(Directive(leadingIndent: "    ", keyword: "User", value: user, isDirty: true)))
        }
        if settings.defaultHostPort > 0 {
            body.append(
                .directive(
                    Directive(
                        leadingIndent: "    ", keyword: "Port",
                        value: String(settings.defaultHostPort), isDirty: true)))
        }
        return body
    }

    @discardableResult
    func duplicateBlock(id: HostBlock.ID) -> HostBlock.ID? {
        guard let location = locate(id) else { return nil }
        let original = documents[location.document].blocks[location.block]
        var copy = original.deepCopyWithFreshIDs()
        if original.kind == .host {
            let existing = Set(documents.flatMap { $0.blocks.flatMap(\.patterns) })
            let base = original.primaryAlias ?? original.patterns.first ?? "host"
            let newAlias = HostNaming.duplicateName(for: base, existing: existing)
            copy.header.value = HostNaming.renamingFirstAlias(in: original.header.value, to: newAlias)
            copy.header.isDirty = true
        }
        mutate(EditAction.duplicateHost.name) {
            let ending = documents[location.document].lineEnding
            documents[location.document].blocks[location.block].body.append(.blank(ending))
            documents[location.document].blocks.insert(
                copy.adoptingLineEnding(ending), at: location.block + 1)
        }
        selectedBlockID = copy.id
        return copy.id
    }

    func rawText(for blockID: HostBlock.ID) -> String {
        guard let block = block(id: blockID) else { return "" }
        var lines = block.leading.map(\.rendered)
        lines.append(block.header.rendered)
        lines.append(contentsOf: block.body.map(\.rendered))
        return lines.joined(separator: "\n")
    }

    @discardableResult
    func replaceBlockFromRaw(id: HostBlock.ID, rawText: String) -> Bool {
        guard let location = locate(id) else { return false }
        let url = documents[location.document].sourceURL
        let parsed = SSHConfigParser.parse(rawText, sourceURL: url)
        guard parsed.blocks.count == 1, parsed.preamble.allSatisfy({ $0.directive == nil }) else {
            return false
        }
        let new = parsed.blocks[0]
        mutate(EditAction.editRaw.name) {
            documents[location.document].blocks[location.block] = HostBlock(
                id: id,
                kind: new.kind,
                leading: parsed.preamble + new.leading,
                header: new.header,
                body: new.body,
                sourceURL: url
            )
        }
        return true
    }

    func deleteBlock(id: HostBlock.ID) {
        guard let location = locate(id) else { return }
        mutate(EditAction.deleteHost.name) {
            documents[location.document].blocks.remove(at: location.block)
        }
        if selectedBlockID == id { selectedBlockID = nil }
    }

    func moveBlocks(in documentURL: URL, fromOffsets: IndexSet, toOffset: Int) {
        guard let index = documents.firstIndex(where: { $0.sourceURL == documentURL }) else { return }
        mutate(EditAction.reorderHosts.name) {
            documents[index].blocks.move(fromOffsets: fromOffsets, toOffset: toOffset)
        }
    }

    func moveBlockToDocument(id: HostBlock.ID, targetDocumentURL: URL) {
        guard documents.contains(where: { $0.sourceURL == targetDocumentURL }),
            let location = locate(id), documents[location.document].sourceURL != targetDocumentURL
        else { return }
        mutate(EditAction.moveToFile.name) {
            performMoveBlockToDocument(id: id, targetURL: targetDocumentURL)
        }
    }

    @discardableResult
    func moveBlockToNewFile(id: HostBlock.ID, fileName: String, in directory: URL? = nil) -> URL? {
        guard let fileURL = prepareGroupFile(fileName: fileName, in: directory) else { return nil }
        mutate(EditAction.moveToNewFile.name) {
            documents.append(SSHConfigDocument(sourceURL: fileURL))
            insertIncludeDirective(for: fileURL)
            performMoveBlockToDocument(id: id, targetURL: fileURL)
        }
        return fileURL
    }

    func performMoveBlockToDocument(id: HostBlock.ID, targetURL: URL) {
        guard let targetIndex = documents.firstIndex(where: { $0.sourceURL == targetURL }),
            let location = locate(id), documents[location.document].sourceURL != targetURL
        else { return }
        var block = documents[location.document].blocks[location.block]
        documents[location.document].blocks.remove(at: location.block)
        block.sourceURL = targetURL
        documents[targetIndex].appendBlocks([block])
    }

    var allHostBlocks: [HostBlock] {
        documents.flatMap(\.blocks).filter { $0.kind == .host }
    }

    @discardableResult
    func addHost(template: HostTemplate) -> HostBlock.ID? {
        guard let targetURL = mainDocumentURL,
            let index = documents.firstIndex(where: { $0.sourceURL == targetURL })
        else { return nil }
        let header = Directive(keyword: "Host", value: uniqueAlias(base: template.alias), isDirty: true)
        let body = template.directives.map {
            ConfigLine.directive(Directive(leadingIndent: "    ", keyword: $0.0, value: $0.1, isDirty: true))
        }
        let block = HostBlock(kind: .host, header: header, body: body, sourceURL: targetURL)
        mutate(EditAction.newFromTemplate(template.name).name) {
            documents[index].appendBlocks([block])
        }
        selectedBlockID = block.id
        return block.id
    }

    @discardableResult
    func importHosts(fromText text: String) -> Int {
        guard let targetURL = mainDocumentURL,
            let index = documents.firstIndex(where: { $0.sourceURL == targetURL })
        else { return 0 }
        let parsed = SSHConfigParser.parse(text, sourceURL: targetURL)
        guard !parsed.blocks.isEmpty else { return 0 }
        let imported = parsed.blocks.map {
            HostBlock(
                kind: $0.kind, leading: $0.leading, header: $0.header,
                body: $0.body, sourceURL: targetURL)
        }
        mutate(EditAction.importHosts(imported.count).name) {
            documents[index].appendBlocks(imported)
        }
        selectedBlockID = imported.first?.id
        return imported.count
    }

    private func uniqueAlias(base: String) -> String {
        let existing = Set(documents.flatMap { $0.blocks.flatMap(\.patterns) })
        guard existing.contains(base) else { return base }
        var index = 2
        while existing.contains("\(base)-\(index)") { index += 1 }
        return "\(base)-\(index)"
    }

    func locate(_ id: HostBlock.ID) -> (document: Int, block: Int)? {
        for (documentIndex, document) in documents.enumerated() {
            if let blockIndex = document.blocks.firstIndex(where: { $0.id == id }) {
                return (documentIndex, blockIndex)
            }
        }
        return nil
    }

    private func uniqueHostName() -> String {
        let existing = Set(documents.flatMap { $0.blocks.flatMap(\.patterns) })
        var index = 1
        while existing.contains("new-host\(index)") { index += 1 }
        return "new-host\(index)"
    }
}
