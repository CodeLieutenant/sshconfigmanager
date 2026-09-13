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
    func grantedFileText(named name: String) -> String? {
        guard let dir = fileAccess.directoryURL else { return nil }
        let url = dir.appendingPathComponent(name)
        guard let text = try? fileAccess.readText(at: url), !text.isEmpty else { return nil }
        return text
    }

    @discardableResult
    func writeForwardDirectives(
        _ directives: [(keyword: String, value: String)],
        toHostAlias alias: String
    ) -> Bool {
        guard let block = allHostBlocks.first(where: { $0.patterns.first == alias }) else { return false }
        updateBlock(id: block.id, actionName: EditAction.addForwarding.name) { block in
            for (keyword, value) in directives {
                let already = block.directives(for: keyword).contains { $0.value == value }
                if !already { block.addDirective(keyword: keyword, value: value) }
            }
        }
        return true
    }

    func importForwardsFromConfig(into preset: TunnelPreset) -> [PortMapping]? {
        let keyword: String
        switch preset.mode {
        case .local: keyword = "localforward"
        case .remote: keyword = "remoteforward"
        case .dynamic: keyword = "dynamicforward"
        }
        let resolved = EffectiveConfigResolver.resolve(target: preset.hostAlias, in: configGraph)
        let imported = resolved.values(of: keyword).compactMap { PortMapping.parsing($0, mode: preset.mode) }
        guard !imported.isEmpty else { return nil }
        let existingSpecs = Set(preset.mappings.map { $0.forwardSpec(for: preset.mode) })
        let newMappings = imported.filter { !existingSpecs.contains($0.forwardSpec(for: preset.mode)) }
        guard !newMappings.isEmpty else { return nil }
        return preset.mappings + newMappings
    }
}
