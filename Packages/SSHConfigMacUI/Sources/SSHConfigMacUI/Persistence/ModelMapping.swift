import Foundation
import SSHConfigCore
import SSHConfigServices

nonisolated extension TunnelPreset {
    init?(_ model: TunnelModel) {
        guard let mode = TunnelMode(rawValue: model.mode) else { return nil }
        self.init(
            id: model.tunnelID,
            name: model.name,
            hostAlias: model.hostAlias,
            mode: mode,
            mappings: model.mappings.sorted { $0.position < $1.position }.map(PortMapping.init),
            autostart: model.autostart)
    }
}

nonisolated extension PortMapping {
    init(_ model: PortMappingModel) {
        self.init(
            id: model.mappingID,
            bindAddress: model.bindAddress,
            listenPort: model.listenPort,
            targetHost: model.targetHost,
            targetPort: model.targetPort,
            hasWebUI: model.hasWebUI)
    }
}

nonisolated extension TunnelModel {
    convenience init(_ preset: TunnelPreset, position: Int) {
        self.init(
            tunnelID: preset.id, position: position, name: preset.name, hostAlias: preset.hostAlias,
            mode: preset.mode.rawValue, autostart: preset.autostart)
    }

    func update(from preset: TunnelPreset, position: Int) {
        self.position = position
        name = preset.name
        hostAlias = preset.hostAlias
        mode = preset.mode.rawValue
        autostart = preset.autostart
    }
}

nonisolated extension PortMappingModel {
    convenience init(_ mapping: PortMapping, position: Int) {
        self.init(
            mappingID: mapping.id, position: position, bindAddress: mapping.bindAddress,
            listenPort: mapping.listenPort, targetHost: mapping.targetHost, targetPort: mapping.targetPort,
            hasWebUI: mapping.hasWebUI)
    }
}

nonisolated extension PersistedGroup {
    init(_ model: HostGroupModel) {
        self.init(id: model.groupID, name: model.name, filePath: model.filePath, sortIndex: model.sortIndex)
    }
}

nonisolated extension HostGroupModel {
    convenience init(_ group: PersistedGroup) {
        self.init(groupID: group.id, name: group.name, filePath: group.filePath, sortIndex: group.sortIndex)
    }

    func update(from group: PersistedGroup) {
        name = group.name
        filePath = group.filePath
        sortIndex = group.sortIndex
    }
}

nonisolated extension ConfigVersion {
    init(_ model: ConfigVersionModel) {
        self.init(
            id: model.versionID,
            parentID: model.parentID,
            createdAt: model.createdAt,
            name: model.name,
            source: model.source,
            addedLines: model.addedLines,
            removedLines: model.removedLines,
            filesChanged: model.filesChanged)
    }
}

nonisolated extension ConfigVersionModel {
    convenience init(_ version: ConfigVersion) {
        self.init(
            versionID: version.id, parentID: version.parentID, createdAt: version.createdAt,
            name: version.name, source: version.source, addedLines: version.addedLines,
            removedLines: version.removedLines, filesChanged: version.filesChanged)
    }
}

nonisolated extension AppDatabase.HostKeyCheckRecord {
    init(_ model: HostKeyCheckModel) {
        self.init(
            groupID: model.groupID,
            hostTitle: model.hostTitle,
            displayName: model.displayName,
            hostToken: model.hostToken,
            keyType: model.keyType,
            fingerprint: model.fingerprint,
            serverOpenSSH: model.serverOpenSSH,
            outcome: model.outcome,
            checkedAt: model.checkedAt)
    }
}

nonisolated extension HostKeyCheckModel {
    convenience init(_ record: AppDatabase.HostKeyCheckRecord) {
        self.init(
            groupID: record.groupID, hostTitle: record.hostTitle, displayName: record.displayName,
            hostToken: record.hostToken, keyType: record.keyType, fingerprint: record.fingerprint,
            serverOpenSSH: record.serverOpenSSH, outcome: record.outcome, checkedAt: record.checkedAt)
    }
}
